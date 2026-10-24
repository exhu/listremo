module orglistremo.cli.import_cmd;

import core.time : Duration, MonoTime;
import d2sqlite3 : Database;
import orglistremo.cli.args : ArgCursor;
import orglistremo.cli.context :
   backupIfRequested, BackupRequest, DbContext, requireWritable;
import orglistremo.cli.roots :
  MultiRootQuery, resolveRoots, RootLookupOptions;
import orglistremo.db.connection : readDbSchemaVersion;
import orglistremo.db.repo :
  EntryRepository, RootRepository, SyncSaveParams;
import orglistremo.db.transaction : withTransaction;
import orglistremo.model : Entry, Root;
import orglistremo.output.options : OutputFormat, OutputOptions;
import orglistremo.output.units : formatDuration;
import std.stdio : File, stderr, stdout, writefln, writeln;

package(orglistremo):

struct ImportArgs {
  string sourceDbPath;
  string[] rootPatterns;
  bool noBackup;
  bool noUpdate;
}

struct ImportSummary {
  string[] importedRoots;
  string[] updatedRoots;
  string[] skippedOlderSyncRoots;
  string[] skippedNoUpdateRoots;
  ulong addedFiles;
  ulong addedDirs;
  ulong updatedFiles;
  ulong updatedDirs;
  ulong removedEntries;
}

bool parseImportArgs(string[] args, out ImportArgs parsed) {
  ArgCursor cur = ArgCursor(args);
  while (!cur.empty()) {
    if (cur.matchFlag("--no-backup")) {
      parsed.noBackup = true;
    } else if (cur.matchFlag("--no-update")) {
      parsed.noUpdate = true;
    } else if (cur.isOption()) {
      stderr.writefln("Unknown flag '%s' for import.", cur.front());
      return false;
    } else if (parsed.sourceDbPath.length == 0) {
      parsed.sourceDbPath = cur.take();
    } else {
      parsed.rootPatterns ~= cur.take();
    }
  }

  if (parsed.sourceDbPath.length == 0) {
    stderr.writeln(
      "Usage: listremo import <db_file> [<root_pattern>...] " ~
      "[--no-backup] [--no-update]"
    );
    return false;
  }
  return true;
}

bool resolveImportSourceRoots(
  ref Database sourceDb,
  in ImportArgs importArgs,
  out Root[] matchedRoots
) {
  RootRepository srcRootRepo = RootRepository(sourceDb);
  const RootLookupOptions lookupOpts = RootLookupOptions(
    false, importArgs.sourceDbPath
  );
  const MultiRootQuery query = MultiRootQuery(
    importArgs.rootPatterns.dup, lookupOpts
  );
  return resolveRoots(srcRootRepo, query, matchedRoots);
}

struct ImportExecConfig {
  Root[] sourceRoots;
  bool noUpdate = false;
}

ImportSummary executeImportRoots(
  ref Database targetDb,
  ref Database sourceDb,
  in ImportExecConfig cfg
) {
  ImportSummary summary;
  if (cfg.sourceRoots.length == 0) {
    return summary;
  }

  withTransaction(targetDb, {
    ImportContext ctx = ImportContext(
      RootRepository(targetDb),
      EntryRepository(targetDb),
      EntryRepository(sourceDb),
      cfg.noUpdate
    );

    Root[] newRoots;
    ExistingRootPair[] existingPairs;

    foreach (ref const srcRoot; cfg.sourceRoots) {
      Root dstRoot;
      if (ctx.dstRootRepo.findByName(srcRoot.name, dstRoot)) {
        existingPairs ~= ExistingRootPair(srcRoot, dstRoot);
      } else {
        newRoots ~= srcRoot;
      }
    }

    foreach (ref const srcRoot; newRoots) {
      importNewRoot(ctx, srcRoot, summary);
    }

    foreach (ref const pair; existingPairs) {
      processExistingRoot(ctx, pair, summary);
    }
  });
  return summary;
}

void printImportSummary(
  in ImportSummary summary,
  Duration elapsed,
  File outStream = stdout
) {
  outStream.writeln("Import summary:");
  outStream.writefln(
    "  New roots imported (%d): %s",
    summary.importedRoots.length,
    formatRootList(summary.importedRoots)
  );
  outStream.writefln(
    "  Roots updated (%d): %s",
    summary.updatedRoots.length,
    formatRootList(summary.updatedRoots)
  );
  outStream.writefln(
    "  Roots not updated (older/equal sync date) (%d): %s",
    summary.skippedOlderSyncRoots.length,
    formatRootList(summary.skippedOlderSyncRoots)
  );
  outStream.writefln(
    "  Roots skipped (--no-update) (%d): %s",
    summary.skippedNoUpdateRoots.length,
    formatRootList(summary.skippedNoUpdateRoots)
  );
  outStream.writefln(
    "  New entries added: %d files, %d dirs",
    summary.addedFiles,
    summary.addedDirs
  );
  if (summary.updatedRoots.length > 0) {
    outStream.writefln(
      "  Updated entries: %d files, %d dirs (%d removed)",
      summary.updatedFiles,
      summary.updatedDirs,
      summary.removedEntries
    );
  }
  outStream.writefln("  Total time: %s", formatDuration(elapsed));
}

int handleImportCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (!requireWritable(ctx)) {
    return 1;
  }

  ImportArgs importArgs;
  if (!parseImportArgs(args, importArgs)) {
    return 1;
  }

  if (!validateSourceDbPath(ctx.dbPath, importArgs.sourceDbPath)) {
    return 1;
  }

  Database sourceDb;
  if (!openSourceDatabase(ctx, importArgs.sourceDbPath, sourceDb)) {
    return 1;
  }
  scope (exit) {
    sourceDb.close();
  }

  Root[] matchedRoots;
  if (!resolveImportSourceRoots(sourceDb, importArgs, matchedRoots)) {
    return 1;
  }

  const BackupRequest bkpReq = BackupRequest(
    ctx.dbPath, importArgs.noBackup, opts, "Import"
  );
  if (!backupIfRequested(ctx, bkpReq)) {
    return 1;
  }

  ImportExecConfig execCfg = ImportExecConfig(
    matchedRoots, importArgs.noUpdate
  );
  return runImportExecution(ctx.db, sourceDb, ImportExecRequest(execCfg, opts));
}

private:

enum size_t importBatchSize = 1000;

struct ImportExecRequest {
  ImportExecConfig execCfg;
  OutputOptions opts;
}

struct ImportContext {
  RootRepository dstRootRepo;
  EntryRepository dstEntryRepo;
  EntryRepository srcEntryRepo;
  bool noUpdate;
}

struct ExistingRootPair {
  Root srcRoot;
  Root dstRoot;
}

int runImportExecution(
  ref Database targetDb,
  ref Database sourceDb,
  in ImportExecRequest req
) {
  try {
    const MonoTime startMono = MonoTime.currTime;
    const ImportSummary summary = executeImportRoots(
      targetDb, sourceDb, req.execCfg
    );
    const Duration elapsed = MonoTime.currTime - startMono;
    if (req.opts.format == OutputFormat.console) {
      printImportSummary(summary, elapsed);
    }
    return 0;
  } catch (Exception e) {
    stderr.writefln("Error importing database: %s", e.msg);
    return 1;
  }
}

string formatRootList(in string[] names) {
  if (names.length == 0) {
    return "none";
  }
  import std.array : join;
  return names.join(", ");
}

bool validateSourceDbPath(string targetDbPath, string sourceDbPath) {
  import std.file : exists, isFile;
  import std.path : absolutePath;

  if (!exists(sourceDbPath) || !isFile(sourceDbPath)) {
    stderr.writefln(
      "Error: Database file '%s' does not exist.", sourceDbPath
    );
    return false;
  }

  if (targetDbPath != ":memory:" &&
      absolutePath(sourceDbPath) == absolutePath(targetDbPath)) {
    stderr.writeln(
      "Error: Source and target database paths must be different."
    );
    return false;
  }
  return true;
}

bool openSourceDatabase(
  in DbContext ctx,
  string sourceDbPath,
  out Database sourceDb
) {
  import std.format : format;

  try {
    sourceDb = Database(sourceDbPath);
    sourceDb.execute(format("PRAGMA busy_timeout = %d;", ctx.busyTimeoutMs));
    sourceDb.execute("PRAGMA query_only = ON;");
  } catch (Exception e) {
    stderr.writefln(
      "Failed to open source database '%s': %s", sourceDbPath, e.msg
    );
    return false;
  }

  int srcSchemaVer = 0;
  try {
    srcSchemaVer = readDbSchemaVersion(sourceDb);
  } catch (Exception e) {
    sourceDb.close();
    stderr.writefln(
      "Failed to read schema version from '%s': %s", sourceDbPath, e.msg
    );
    return false;
  }

  if (srcSchemaVer != ctx.dbSchemaVersion) {
    sourceDb.close();
    stderr.writefln(
      "Error: Cannot import '%s': schema version (%d) does not match " ~
      "current database schema version (%d).",
      sourceDbPath,
      srcSchemaVer,
      ctx.dbSchemaVersion
    );
    return false;
  }
  return true;
}

void copyRootEntriesBatched(
  ref EntryRepository dstEntryRepo,
  long dstRootId,
  in Entry[] srcEntries
) {
  dstEntryRepo.clearRootEntries(dstRootId);
  for (size_t i = 0; i < srcEntries.length; i += importBatchSize) {
    const size_t end = (i + importBatchSize < srcEntries.length)
      ? (i + importBatchSize)
      : srcEntries.length;
    dstEntryRepo.upsertEntriesBatch(dstRootId, srcEntries[i .. end]);
  }
}

void countNewEntries(
  in Entry[] entries,
  in bool[string] existingPaths,
  ref ImportSummary summary
) {
  size_t seenExisting = 0;
  foreach (ref const e; entries) {
    if (e.relPath == ".") {
      continue;
    }
    if (e.relPath in existingPaths) {
      seenExisting++;
      if (e.isDir) {
        summary.updatedDirs++;
      } else {
        summary.updatedFiles++;
      }
      continue;
    }
    if (e.isDir) {
      summary.addedDirs++;
    } else {
      summary.addedFiles++;
    }
  }
  if (existingPaths.length > seenExisting) {
    summary.removedEntries += (existingPaths.length - seenExisting);
  }
}

void importNewRoot(
  ref ImportContext ctx,
  in Root srcRoot,
  ref ImportSummary summary
) {
  const long newRootId = ctx.dstRootRepo.insertImportedRoot(srcRoot);
  const Entry[] srcEntries = ctx.srcEntryRepo.listEntriesByRootId(srcRoot.id);
  copyRootEntriesBatched(ctx.dstEntryRepo, newRootId, srcEntries);

  bool[string] emptyExisting;
  countNewEntries(srcEntries, emptyExisting, summary);
  summary.importedRoots ~= srcRoot.name;
}

void processExistingRoot(
  ref ImportContext ctx,
  in ExistingRootPair pair,
  ref ImportSummary summary
) {
  if (ctx.noUpdate) {
    summary.skippedNoUpdateRoots ~= pair.srcRoot.name;
    return;
  }

  const bool isMoreRecent = pair.srcRoot.hasLastSync && (
    !pair.dstRoot.hasLastSync ||
    pair.srcRoot.lastSync > pair.dstRoot.lastSync
  );
  if (!isMoreRecent) {
    summary.skippedOlderSyncRoots ~= pair.srcRoot.name;
    return;
  }

  const existingPaths = ctx.dstEntryRepo.getEntryPathsSet(pair.dstRoot.id);
  const Entry[] srcEntries = ctx.srcEntryRepo.listEntriesByRootId(
    pair.srcRoot.id
  );

  countNewEntries(srcEntries, existingPaths, summary);
  ctx.dstRootRepo.updateImportedRoot(pair.dstRoot.id, pair.srcRoot);
  copyRootEntriesBatched(ctx.dstEntryRepo, pair.dstRoot.id, srcEntries);
  summary.updatedRoots ~= pair.srcRoot.name;
}

unittest {
  import core.time : dur;
  import orglistremo.db.connection : openDatabase;

  // Test parseImportArgs
  ImportArgs args1;
  assert(parseImportArgs(["import", "other.db"], args1));
  assert(args1.sourceDbPath == "other.db");
  assert(args1.rootPatterns.length == 0);
  assert(!args1.noBackup);
  assert(!args1.noUpdate);

  ImportArgs args2;
  assert(
    parseImportArgs(
      ["import", "other.db", "r1", "backup%", "--no-backup", "--no-update"],
      args2
    )
  );
  assert(args2.sourceDbPath == "other.db");
  assert(args2.rootPatterns == ["r1", "backup%"]);
  assert(args2.noBackup);
  assert(args2.noUpdate);

  ImportArgs argsMissingDb;
  assert(!parseImportArgs(["import"], argsMissingDb));
  assert(!parseImportArgs(["import", "--no-backup"], argsMissingDb));

  ImportArgs argsBadFlag;
  assert(!parseImportArgs(["import", "other.db", "--unknown"], argsBadFlag));

  // Test executeImportRoots: new roots, updated roots, older sync, --no-update
  Database dstDb = openDatabase(":memory:");
  Database srcDb = openDatabase(":memory:");

  RootRepository dstRoots = RootRepository(dstDb);
  EntryRepository dstEntries = EntryRepository(dstDb);
  RootRepository srcRoots = RootRepository(srcDb);
  EntryRepository srcEntries = EntryRepository(srcDb);

  const dstKeepId = dstRoots.addRoot("root_keep", "/dst/keep");
  dstEntries.saveSyncEntries(
    SyncSaveParams(dstKeepId, 5000, 1024, true),
    [
      Entry(0, dstKeepId, "root_keep", ".", null, ".", true, 10, 1000, "h_k"),
      Entry(
        0, dstKeepId, "root_keep", "k.txt", ".", "k.txt", false, 10, 1000, "hk"
      )
    ]
  );

  const dstUpdId = dstRoots.addRoot("root_update", "/dst/old_path");
  dstEntries.saveSyncEntries(
    SyncSaveParams(dstUpdId, 2000, 2048, true),
    [
      Entry(0, dstUpdId, "root_update", ".", null, ".", true, 20, 1000, "h_u0"),
      Entry(
        0, dstUpdId, "root_update", "existing.txt", ".", "existing.txt",
        false, 20, 1000, "he0"
      )
    ]
  );

  const srcKeepId = srcRoots.addRoot("root_keep", "/src/keep");
  srcEntries.saveSyncEntries(
    srcKeepId,
    [
      Entry(0, srcKeepId, "root_keep", ".", null, ".", true, 99, 1000, "h_ks"),
      Entry(
        0, srcKeepId, "root_keep", "s.txt", ".", "s.txt", false, 99, 1000, "hks"
      )
    ],
    3000
  );

  const srcUpdId = srcRoots.addRoot("root_update", "/src/new_path");
  srcEntries.saveSyncEntries(
    SyncSaveParams(srcUpdId, 6000, 9999, true),
    [
      Entry(0, srcUpdId, "root_update", ".", null, ".", true, 50, 1500, "h_u1"),
      Entry(
        0, srcUpdId, "root_update", "existing.txt", ".", "existing.txt",
        false, 25, 1500, "he1"
      ),
      Entry(
        0, srcUpdId, "root_update", "sub", ".", "sub",
        true, 25, 1500, "hsub"
      ),
      Entry(
        0, srcUpdId, "root_update", "sub/added.txt", "sub", "added.txt",
        false, 25, 1500, "hadd"
      )
    ]
  );

  const srcNewId = srcRoots.addRoot("root_new", "/src/new_root");
  srcEntries.saveSyncEntries(
    SyncSaveParams(srcNewId, 4000, 4096, true),
    [
      Entry(0, srcNewId, "root_new", ".", null, ".", true, 70, 1200, "h_n"),
      Entry(
        0, srcNewId, "root_new", "docs", ".", "docs", true, 70, 1200, "hdocs"
      ),
      Entry(
        0, srcNewId, "root_new", "docs/a.txt", "docs", "a.txt",
        false, 30, 1200, "ha"
      ),
      Entry(
        0, srcNewId, "root_new", "b.txt", ".", "b.txt",
        false, 40, 1200, "hb"
      )
    ]
  );

  Root[] matched;
  ImportArgs resolveArgs;
  resolveArgs.sourceDbPath = ":memory:";
  assert(resolveImportSourceRoots(srcDb, resolveArgs, matched));
  assert(matched.length == 3);

  {
    Database dstNoUpd = openDatabase(":memory:");
    RootRepository rRepo = RootRepository(dstNoUpd);
    const id1 = rRepo.addRoot("root_update", "/dst/old");
    rRepo.updateLastSync(id1, 1000);

    const sumNoUpd = executeImportRoots(
      dstNoUpd, srcDb, ImportExecConfig(matched, true)
    );
    assert(sumNoUpd.importedRoots == ["root_keep", "root_new"]);
    assert(sumNoUpd.updatedRoots.length == 0);
    assert(sumNoUpd.skippedOlderSyncRoots.length == 0);
    assert(sumNoUpd.skippedNoUpdateRoots == ["root_update"]);
    assert(sumNoUpd.addedFiles == 3);
    assert(sumNoUpd.addedDirs == 1);
  }

  const summary = executeImportRoots(
    dstDb, srcDb, ImportExecConfig(matched, false)
  );
  assert(summary.importedRoots == ["root_new"]);
  assert(summary.updatedRoots == ["root_update"]);
  assert(summary.skippedOlderSyncRoots == ["root_keep"]);
  assert(summary.skippedNoUpdateRoots.length == 0);
  assert(summary.addedFiles == 3);
  assert(summary.addedDirs == 2);
  assert(summary.updatedFiles == 1);
  assert(summary.updatedDirs == 0);
  assert(summary.removedEntries == 0);

  Root dstNew;
  assert(dstRoots.findByName("root_new", dstNew));
  assert(dstNew.path == "/src/new_root");
  assert(dstNew.hasLastSync && dstNew.lastSync == 4000);
  assert(dstNew.hasFreeSpace && dstNew.freeSpace == 4096);
  const newEntriesList = dstEntries.listEntriesByRootId(dstNew.id);
  assert(newEntriesList.length == 4);

  Root dstUpdAfter;
  assert(dstRoots.findByName("root_update", dstUpdAfter));
  assert(dstUpdAfter.id == dstUpdId);
  assert(dstUpdAfter.path == "/src/new_path");
  assert(dstUpdAfter.lastSync == 6000);
  assert(dstUpdAfter.freeSpace == 9999);
  const updEntriesList = dstEntries.listEntriesByRootId(dstUpdId);
  assert(updEntriesList.length == 4);

  Root dstKeepAfter;
  assert(dstRoots.findByName("root_keep", dstKeepAfter));
  assert(dstKeepAfter.path == "/dst/keep");
  assert(dstKeepAfter.lastSync == 5000);
  assert(dstEntries.listEntriesByRootId(dstKeepId).length == 2);

  import orglistremo.internal.testutil : captureOutput;

  const summaryText = captureOutput((File f) {
    printImportSummary(summary, dur!"msecs"(120), f);
  });
  import std.algorithm.searching : canFind;
  assert(canFind(summaryText, "New roots imported (1): root_new"));
  assert(canFind(summaryText, "Roots updated (1): root_update"));
  assert(
    canFind(
      summaryText,
      "Roots not updated (older/equal sync date) (1): root_keep"
    )
  );
  assert(canFind(summaryText, "Roots skipped (--no-update) (0): none"));
  assert(canFind(summaryText, "New entries added: 3 files, 2 dirs"));
  assert(canFind(summaryText, "Updated entries: 1 files, 0 dirs (0 removed)"));
  assert(canFind(summaryText, "Total time: 120 ms"));
}

unittest {
  import orglistremo.db.connection : openDatabaseChecked;
  import orglistremo.internal.testutil : createLegacyV0Db, TempDir;

  TempDir testDir = TempDir("importer");
  const dstPath = testDir.subPath("dst.db");
  const srcPath = testDir.subPath("src.db");
  const oldVerPath = testDir.subPath("old_ver.db");

  createLegacyV0Db(oldVerPath);

  {
    auto srcOpen = openDatabaseChecked(srcPath);
    scope (exit) {
      srcOpen.db.close();
    }
    RootRepository srcRoots = RootRepository(srcOpen.db);
    EntryRepository srcEntries = EntryRepository(srcOpen.db);

    const a1 = srcRoots.addRoot("alpha_1", "/src/a1");
    srcEntries.saveSyncEntries(
      a1,
      [
        Entry(0, a1, "alpha_1", ".", null, ".", true, 10, 1000, "ha1"),
        Entry(0, a1, "alpha_1", "f1.txt", ".", "f1.txt", false, 10, 1000, "hf1")
      ],
      3000
    );

    const a2 = srcRoots.addRoot("alpha_2", "/src/a2");
    srcEntries.saveSyncEntries(
      a2,
      [
        Entry(0, a2, "alpha_2", ".", null, ".", true, 20, 1000, "ha2"),
        Entry(0, a2, "alpha_2", "f2.txt", ".", "f2.txt", false, 20, 1000, "hf2")
      ],
      4000
    );

    const b1 = srcRoots.addRoot("beta", "/src/beta");
    srcEntries.saveSyncEntries(
      b1,
      [
        Entry(0, b1, "beta", ".", null, ".", true, 30, 1000, "hb1"),
        Entry(0, b1, "beta", "b.txt", ".", "b.txt", false, 30, 1000, "hfb")
      ],
      5000
    );
  }

  auto dstOpen = openDatabaseChecked(dstPath);
  scope (exit) {
    dstOpen.db.close();
  }
  DbContext ctx = DbContext(
    dstOpen.db, dstPath, dstOpen.dbSchemaVersion, dstOpen.isReadOnly
  );
  OutputOptions opts;
  opts.styler.enabled = false;

  DbContext roCtx = DbContext(dstOpen.db, dstPath, 0, true);
  assert(handleImportCommand(roCtx, ["import", srcPath], opts) == 1);

  assert(
    handleImportCommand(
      ctx, ["import", testDir.subPath("missing.db"), "--no-backup"], opts
    ) == 1
  );

  assert(
    handleImportCommand(ctx, ["import", dstPath, "--no-backup"], opts) == 1
  );

  assert(
    handleImportCommand(ctx, ["import", oldVerPath, "--no-backup"], opts) == 1
  );

  assert(
    handleImportCommand(
      ctx, ["import", srcPath, "nonexistent%", "--no-backup"], opts
    ) == 1
  );
  assert(
    handleImportCommand(
      ctx, ["import", srcPath, "nonexistent", "--no-backup"], opts
    ) == 1
  );

  assert(
    handleImportCommand(
      ctx, ["import", srcPath, "alpha%", "--no-backup"], opts
    ) == 0
  );
  RootRepository dstRoots = RootRepository(ctx.db);
  Root rCheck;
  assert(dstRoots.findByName("alpha_1", rCheck));
  assert(dstRoots.findByName("alpha_2", rCheck));
  assert(!dstRoots.findByName("beta", rCheck));

  assert(
    handleImportCommand(
      ctx, ["import", srcPath, "--no-backup", "--no-update"], opts
    ) == 0
  );
  assert(dstRoots.findByName("beta", rCheck));
}
