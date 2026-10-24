module orglistremo.importer;

import core.time : Duration, MonoTime;
import d2sqlite3 : Database;
import orglistremo.app : DbContext, printReadOnlyError;
import orglistremo.db.backup : promptBackupPath, writeDatabaseBackup;
import orglistremo.db.connection : readDbSchemaVersion;
import orglistremo.db.repo : EntryRepository, RootRepository;
import orglistremo.model :
  Entry, hasPatternWildcard, OutputFormat, Root;
import orglistremo.output.console : OutputOptions;
import orglistremo.output.units : formatDuration;
import std.stdio : File, stderr, stdout, writeln;

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
}

bool parseImportArgs(string[] args, out ImportArgs parsed) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--no-backup") {
      parsed.noBackup = true;
    } else if (arg == "--no-update") {
      parsed.noUpdate = true;
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for import.", arg);
      return false;
    } else if (parsed.sourceDbPath.length == 0) {
      parsed.sourceDbPath = arg;
    } else {
      parsed.rootPatterns ~= arg;
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
  string sourceDbLabel,
  in string[] rootPatterns,
  out Root[] matchedRoots
) {
  RootRepository srcRootRepo = RootRepository(sourceDb);
  if (rootPatterns.length == 0) {
    matchedRoots = srcRootRepo.findByPattern("%");
    return true;
  }

  bool[long] seenIds;
  foreach (pattern; rootPatterns) {
    const found = srcRootRepo.findByPattern(pattern);
    if (found.length == 0) {
      if (hasPatternWildcard(pattern)) {
        stderr.writefln(
          "Error: No roots match pattern '%s' in '%s'.",
          pattern,
          sourceDbLabel
        );
      } else {
        stderr.writefln(
          "Error: Root '%s' not found in '%s'.",
          pattern,
          sourceDbLabel
        );
      }
      return false;
    }
    foreach (ref r; found) {
      if (r.id !in seenIds) {
        seenIds[r.id] = true;
        matchedRoots ~= r;
      }
    }
  }
  return true;
}

ImportSummary executeImportRoots(
  ref Database targetDb,
  ref Database sourceDb,
  in Root[] sourceRoots,
  bool noUpdate = false
) {
  ImportSummary summary;
  if (sourceRoots.length == 0) {
    return summary;
  }

  RootRepository dstRootRepo = RootRepository(targetDb);
  EntryRepository dstEntryRepo = EntryRepository(targetDb);
  EntryRepository srcEntryRepo = EntryRepository(sourceDb);

  Root[] newRoots;
  ExistingRootPair[] existingPairs;

  foreach (ref srcRoot; sourceRoots) {
    Root dstRoot;
    if (dstRootRepo.findByName(srcRoot.name, dstRoot)) {
      existingPairs ~= ExistingRootPair(srcRoot, dstRoot);
    } else {
      newRoots ~= srcRoot;
    }
  }

  targetDb.execute("BEGIN IMMEDIATE;");
  scope (failure) {
    targetDb.execute("ROLLBACK;");
  }

  // 1. Import new roots and their entries
  foreach (ref srcRoot; newRoots) {
    importNewRoot(
      dstRootRepo, dstEntryRepo, srcEntryRepo, srcRoot, summary
    );
  }

  // 2. Update existing roots if allowed and more recent
  foreach (ref pair; existingPairs) {
    processExistingRoot(
      dstRootRepo, dstEntryRepo, srcEntryRepo, pair, noUpdate, summary
    );
  }

  targetDb.execute("COMMIT;");
  return summary;
}

void printImportSummary(
  in ImportSummary summary,
  Duration elapsed,
  in OutputOptions opts,
  File outStream = stdout
) {
  if (opts.format != OutputFormat.console) {
    return;
  }

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
  outStream.writefln("  Total time: %s", formatDuration(elapsed));
}

int handleImportCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (ctx.isReadOnly) {
    printReadOnlyError(ctx.dbSchemaVersion);
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
  if (!openSourceDatabase(
    importArgs.sourceDbPath,
    ctx.dbSchemaVersion,
    ctx.busyTimeoutMs,
    sourceDb
  )) {
    return 1;
  }
  scope (exit) {
    sourceDb.close();
  }

  Root[] matchedRoots;
  if (!resolveImportSourceRoots(
    sourceDb,
    importArgs.sourceDbPath,
    importArgs.rootPatterns,
    matchedRoots
  )) {
    return 1;
  }

  if (!importArgs.noBackup && ctx.dbPath != ":memory:") {
    string backupPath;
    if (!promptBackupPath(ctx.dbPath, backupPath, "Import")) {
      return 1;
    }
    if (!writeDatabaseBackup(ctx.dbPath, backupPath, opts)) {
      return 1;
    }
  }

  try {
    const startMono = MonoTime.currTime;
    const summary = executeImportRoots(
      ctx.db, sourceDb, matchedRoots, importArgs.noUpdate
    );
    const elapsed = MonoTime.currTime - startMono;
    printImportSummary(summary, elapsed, opts);
    return 0;
  } catch (Exception e) {
    stderr.writefln("Error importing database: %s", e.msg);
    return 1;
  }
}

private:

struct ExistingRootPair {
  Root srcRoot;
  Root dstRoot;
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
  string sourceDbPath,
  int targetSchemaVer,
  uint busyTimeoutMs,
  out Database sourceDb
) {
  import std.format : format;

  try {
    sourceDb = Database(sourceDbPath);
    sourceDb.execute(format("PRAGMA busy_timeout = %d;", busyTimeoutMs));
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

  if (srcSchemaVer != targetSchemaVer) {
    sourceDb.close();
    stderr.writefln(
      "Error: Cannot import '%s': schema version (%d) does not match " ~
      "current database schema version (%d).",
      sourceDbPath,
      srcSchemaVer,
      targetSchemaVer
    );
    return false;
  }
  return true;
}

void importNewRoot(
  ref RootRepository dstRootRepo,
  ref EntryRepository dstEntryRepo,
  ref EntryRepository srcEntryRepo,
  in Root srcRoot,
  ref ImportSummary summary
) {
  const newRootId = dstRootRepo.insertImportedRoot(srcRoot);
  const srcEntries = srcEntryRepo.listEntries(srcRoot.id);
  dstEntryRepo.replaceRootEntries(newRootId, srcEntries);

  foreach (ref e; srcEntries) {
    if (e.relPath == ".") {
      continue;
    }
    if (e.isDir) {
      summary.addedDirs++;
    } else {
      summary.addedFiles++;
    }
  }
  summary.importedRoots ~= srcRoot.name;
}

void processExistingRoot(
  ref RootRepository dstRootRepo,
  ref EntryRepository dstEntryRepo,
  ref EntryRepository srcEntryRepo,
  in ExistingRootPair pair,
  bool noUpdate,
  ref ImportSummary summary
) {
  if (noUpdate) {
    summary.skippedNoUpdateRoots ~= pair.srcRoot.name;
    return;
  }

  const isMoreRecent = pair.srcRoot.hasLastSync && (
    !pair.dstRoot.hasLastSync ||
    pair.srcRoot.lastSync > pair.dstRoot.lastSync
  );
  if (!isMoreRecent) {
    summary.skippedOlderSyncRoots ~= pair.srcRoot.name;
    return;
  }

  const existingPaths = dstEntryRepo.getEntryPathsSet(pair.dstRoot.id);
  const srcEntries = srcEntryRepo.listEntries(pair.srcRoot.id);

  foreach (ref e; srcEntries) {
    if (e.relPath == "." || (e.relPath in existingPaths)) {
      continue;
    }
    if (e.isDir) {
      summary.addedDirs++;
    } else {
      summary.addedFiles++;
    }
  }

  dstRootRepo.updateImportedRoot(pair.dstRoot.id, pair.srcRoot);
  dstEntryRepo.replaceRootEntries(pair.dstRoot.id, srcEntries);
  summary.updatedRoots ~= pair.srcRoot.name;
}

unittest {
  import core.time : dur;
  import orglistremo.db.connection : openDatabase;
  import orglistremo.db.schema_version : schemaVersion;

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

  // Setup destination DB:
  // - root_keep: synced at 5000 (newer than source)
  // - root_update: synced at 2000 (older than source)
  const dstKeepId = dstRoots.addRoot("root_keep", "/dst/keep");
  dstEntries.saveSyncEntries(
    dstKeepId,
    [
      Entry(0, dstKeepId, "root_keep", ".", null, ".", true, 10, 1000, "h_k"),
      Entry(
        0, dstKeepId, "root_keep", "k.txt", ".", "k.txt", false, 10, 1000, "hk"
      )
    ],
    5000,
    1024,
    true
  );

  const dstUpdId = dstRoots.addRoot("root_update", "/dst/old_path");
  dstEntries.saveSyncEntries(
    dstUpdId,
    [
      Entry(0, dstUpdId, "root_update", ".", null, ".", true, 20, 1000, "h_u0"),
      Entry(
        0, dstUpdId, "root_update", "existing.txt", ".", "existing.txt",
        false, 20, 1000, "he0"
      )
    ],
    2000,
    2048,
    true
  );

  // Setup source DB:
  // - root_keep: synced at 3000 (older than dst 5000 -> skipped)
  // - root_update: synced at 6000 (newer than dst 2000 -> updated)
  // - root_new: synced at 4000 (not in dst -> imported)
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
    srcUpdId,
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
    ],
    6000,
    9999,
    true
  );

  const srcNewId = srcRoots.addRoot("root_new", "/src/new_root");
  srcEntries.saveSyncEntries(
    srcNewId,
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
    ],
    4000,
    4096,
    true
  );

  Root[] matched;
  assert(resolveImportSourceRoots(srcDb, ":memory:", [], matched));
  assert(matched.length == 3);

  // 1. Test with noUpdate = true first on a separate target DB
  {
    Database dstNoUpd = openDatabase(":memory:");
    RootRepository rRepo = RootRepository(dstNoUpd);
    const id1 = rRepo.addRoot("root_update", "/dst/old");
    rRepo.updateLastSync(id1, 1000);

    const sumNoUpd = executeImportRoots(dstNoUpd, srcDb, matched, true);
    assert(sumNoUpd.importedRoots == ["root_keep", "root_new"]);
    assert(sumNoUpd.updatedRoots.length == 0);
    assert(sumNoUpd.skippedOlderSyncRoots.length == 0);
    assert(sumNoUpd.skippedNoUpdateRoots == ["root_update"]);
    // root_keep (1 file, 0 dirs) + root_new (2 files, 1 dir) = 3 files, 1 dir
    assert(sumNoUpd.addedFiles == 3);
    assert(sumNoUpd.addedDirs == 1);
  }

  // 2. Test full import with updates enabled on dstDb
  const summary = executeImportRoots(dstDb, srcDb, matched, false);
  assert(summary.importedRoots == ["root_new"]);
  assert(summary.updatedRoots == ["root_update"]);
  assert(summary.skippedOlderSyncRoots == ["root_keep"]);
  assert(summary.skippedNoUpdateRoots.length == 0);
  // root_new added 2 files + 1 dir; root_update added 1 new file + 1 new dir
  assert(summary.addedFiles == 3);
  assert(summary.addedDirs == 2);

  // Verify root_new in dstDb has a new ID and all entries mapped properly
  Root dstNew;
  assert(dstRoots.findByName("root_new", dstNew));
  assert(dstNew.path == "/src/new_root");
  assert(dstNew.hasLastSync && dstNew.lastSync == 4000);
  assert(dstNew.hasFreeSpace && dstNew.freeSpace == 4096);
  const newEntriesList = dstEntries.listEntries(dstNew.id);
  assert(newEntriesList.length == 4);

  // Verify root_update was updated in dstDb
  Root dstUpdAfter;
  assert(dstRoots.findByName("root_update", dstUpdAfter));
  assert(dstUpdAfter.id == dstUpdId);
  assert(dstUpdAfter.path == "/src/new_path");
  assert(dstUpdAfter.lastSync == 6000);
  assert(dstUpdAfter.freeSpace == 9999);
  const updEntriesList = dstEntries.listEntries(dstUpdId);
  assert(updEntriesList.length == 4);

  // Verify root_keep was untouched
  Root dstKeepAfter;
  assert(dstRoots.findByName("root_keep", dstKeepAfter));
  assert(dstKeepAfter.path == "/dst/keep");
  assert(dstKeepAfter.lastSync == 5000);
  assert(dstEntries.listEntries(dstKeepId).length == 2);

  // Test printImportSummary output
  OutputOptions outOpts;
  outOpts.format = OutputFormat.console;
  File tmpSummary = File.tmpfile();
  printImportSummary(summary, dur!"msecs"(120), outOpts, tmpSummary);
  tmpSummary.rewind();
  string summaryText;
  foreach (line; tmpSummary.byLineCopy()) {
    summaryText ~= line ~ "\n";
  }
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
  assert(canFind(summaryText, "Total time: 120 ms"));
}

unittest {
  import orglistremo.db.connection : openDatabaseChecked;
  import orglistremo.db.schema_version : schemaVersion;
  import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
  import std.path : buildPath;

  const testDir = buildPath(tempDir(), "listremo_importer_cmd_test");
  if (exists(testDir)) {
    rmdirRecurse(testDir);
  }
  mkdirRecurse(testDir);
  scope (exit) {
    if (exists(testDir)) {
      rmdirRecurse(testDir);
    }
  }

  const dstPath = buildPath(testDir, "dst.db");
  const srcPath = buildPath(testDir, "src.db");
  const oldVerPath = buildPath(testDir, "old_ver.db");

  // Create old schema v0 database
  {
    auto rawDb = Database(oldVerPath);
    rawDb.execute(`
      CREATE TABLE roots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_sync INTEGER
      );
    `);
    rawDb.close();
  }

  // Create source database (current schema version)
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

  // 1. Read-only target DB is rejected
  DbContext roCtx = DbContext(dstOpen.db, dstPath, 0, true);
  assert(handleImportCommand(roCtx, ["import", srcPath], opts) == 1);

  // 2. Nonexistent source DB is rejected
  assert(
    handleImportCommand(
      ctx, ["import", buildPath(testDir, "missing.db"), "--no-backup"], opts
    ) == 1
  );

  // 3. Importing from same DB path as target is rejected
  assert(
    handleImportCommand(ctx, ["import", dstPath, "--no-backup"], opts) == 1
  );

  // 4. Mismatched schema version source DB is rejected
  assert(
    handleImportCommand(ctx, ["import", oldVerPath, "--no-backup"], opts) == 1
  );

  // 5. Unmatched root pattern in source DB is rejected
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

  // 6. Selective import with pattern "alpha%" imports alpha_1 and alpha_2 only
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

  // 7. Re-running import of all roots with --no-update imports beta and skips
  //    alpha_1 and alpha_2
  assert(
    handleImportCommand(
      ctx, ["import", srcPath, "--no-backup", "--no-update"], opts
    ) == 0
  );
  assert(dstRoots.findByName("beta", rCheck));
}
