module orglistremo.app;

import d2sqlite3 : Database;
import orglistremo.config : resolveDbPath;
import orglistremo.db.backup :
  promptBackupPath, proposeBackupPath, writeDatabaseBackup;
import orglistremo.db.connection :
  DbOpenResult, migrateDatabase, openDatabase, openDatabaseChecked;
import orglistremo.db.repo :
  EntryRepository, HashQueryFilter, ListEntriesFilter, RootRepository;
import orglistremo.db.repo_locks :
  isPidAlive, SyncLockInfo, SyncLockRepository;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.importer : handleImportCommand;
import orglistremo.model :
  ColorMode, Entry, EntryType, hasGlobWildcard, hasPatternWildcard,
  OutputFormat, Root, RootSummary, SortField, TargetSpec;
import orglistremo.output.console :
  ConsoleProgressReporter, OutputOptions, shouldColorize, Styler;
import orglistremo.output.formatter :
  outputDuplicates, outputEntries, outputRoots, outputUnique;
import orglistremo.output.units : formatDuration, formatUnixTime;
import orglistremo.sync.scanner :
  syncRoot, SyncIssue, SyncOptions, SyncProgressCallback;
import std.datetime.systime : Clock;
import std.getopt : config, getopt;
import std.process : thisProcessID;
import std.socket : Socket;
import std.stdio : stderr, writefln, writeln;

version (unittest) {
  // main is excluded so the unit test runner provides its own entry point
} else {
  int main(string[] args) {
    CliGlobalOptions globals;
    if (!parseGlobalOptions(args, globals)) {
      return 1;
    }

    if (globals.showHelp || args.length <= 1 || args[1] == "help") {
      printUsage();
      return 0;
    }

    if (args[1].length > 0 && args[1][0] == '-') {
      stderr.writefln(
        "Unrecognized option '%s'. Run 'listremo help'.", args[1]
      );
      return 1;
    }

    OutputOptions opts;
    if (!buildOutputOptions(globals, opts)) {
      return 1;
    }

    const dbPath = resolveDbPath(globals.cliDb);
    DbOpenResult openRes;
    try {
      openRes = openDatabaseChecked(dbPath, globals.busyTimeoutMs);
    } catch (Exception e) {
      stderr.writefln("Failed to open database '%s': %s", dbPath, e.msg);
      return 1;
    }

    if (openRes.isReadOnly) {
      printSchemaMismatchWarning(openRes.dbSchemaVersion);
    }

    DbContext ctx = DbContext(
      openRes.db,
      dbPath,
      openRes.dbSchemaVersion,
      openRes.isReadOnly,
      globals.busyTimeoutMs
    );
    return dispatchCommand(ctx, args[1 .. $], opts);
  }
}

package(orglistremo):

struct DbContext {
  Database db;
  string dbPath;
  int dbSchemaVersion;
  bool isReadOnly;
  uint busyTimeoutMs = 60_000;
}

void printReadOnlyError(int dbSchemaVer) {
  stderr.writefln(
    "Error: Command is not available in read-only mode " ~
    "(database schema version %d, application schema version %d). " ~
    "Run 'listremo migrate' first.",
    dbSchemaVer,
    schemaVersion
  );
}

private:

struct CliGlobalOptions {
  string cliDb;
  string formatStr = "console";
  bool csvFlag;
  bool htmlFlag;
  string colorStr = "auto";
  bool fullHash;
  bool showHelp;
  uint busyTimeoutMs = 60_000;
}

struct SyncArgs {
  bool allFlag;
  bool forceFlag;
  bool forceHash;
  bool noProgress;
  bool breakLock;
  uint jobs = 1;
  uint progressIntervalMs = 1000;
  string targetRoot;
}

struct MigrateArgs {
  bool noBackup;
}

struct ListArgs {
  string[] targets;
  EntryType typeFilter = EntryType.all;
  SortField sortField = SortField.path;
  bool useGlob;
  string hashPattern;
  bool hasHash;
}

struct DuplicateOrUniqueArgs {
  string[] targets;
  EntryType typeFilter = EntryType.file;
  bool skipEmpty;
  bool useGlob;
}

void printSchemaMismatchWarning(int dbSchemaVer) {
  stderr.writefln(
    "Warning: Database schema version (%d) does not match " ~
    "application schema version (%d).",
    dbSchemaVer,
    schemaVersion
  );
  stderr.writeln(
    "Working in read-only mode. " ~
    "Run 'listremo migrate' to update the database."
  );
}

bool parseGlobalOptions(ref string[] args, out CliGlobalOptions globals) {
  try {
    getopt(
      args,
      config.passThrough,
      config.caseSensitive,
      "db", "Path to SQLite database", &globals.cliDb,
      "format", "Output format (console, csv, html)", &globals.formatStr,
      "csv", "Shortcut for --format csv", &globals.csvFlag,
      "html", "Shortcut for --format html", &globals.htmlFlag,
      "color", "Color mode (auto, always, never)", &globals.colorStr,
      "full-hash", "Display full 64-char SHA256 in console", &globals.fullHash,
      "busy-timeout", "SQLite busy timeout in ms (default 60000)",
      &globals.busyTimeoutMs,
      "help|h", "Display this help message", &globals.showHelp
    );
    return true;
  } catch (Exception e) {
    stderr.writefln("Error parsing global options: %s", e.msg);
    return false;
  }
}

bool buildOutputOptions(
  in CliGlobalOptions globals,
  out OutputOptions opts
) {
  if (globals.formatStr != "console" && globals.formatStr != "csv" &&
      globals.formatStr != "html") {
    stderr.writefln(
      "Invalid --format '%s'. Valid values: console, csv, html.",
      globals.formatStr
    );
    return false;
  }

  if (globals.csvFlag && globals.htmlFlag) {
    stderr.writeln("Error: Cannot specify both --csv and --html.");
    return false;
  }

  ColorMode colorMode;
  if (globals.colorStr == "auto") {
    colorMode = ColorMode.autoMode;
  } else if (globals.colorStr == "always") {
    colorMode = ColorMode.always;
  } else if (globals.colorStr == "never") {
    colorMode = ColorMode.never;
  } else {
    stderr.writefln(
      "Invalid --color '%s'. Valid values: auto, always, never.",
      globals.colorStr
    );
    return false;
  }

  if (globals.htmlFlag || globals.formatStr == "html") {
    opts.format = OutputFormat.html;
  } else if (globals.csvFlag || globals.formatStr == "csv") {
    opts.format = OutputFormat.csv;
  } else {
    opts.format = OutputFormat.console;
  }

  opts.styler.enabled = (opts.format == OutputFormat.console)
    && shouldColorize(colorMode);
  opts.fullHash = globals.fullHash;
  return true;
}

void printUsage() {
  import orglistremo.app_version : appVersion;
  writefln("listremo version %s", appVersion);
  writeln("Usage: listremo [global options] <command> [arguments...]\n");
  writeln("Commands:");
  writeln("  root add <name> <path>       Register a new storage root");
  writeln("  root remove <name>           Remove a root and entries");
  writeln("  root set-path <name> <path>  Update mount path of a root");
  writeln("  root list [pattern]          List registered storage roots");
  writeln("  sync <name|pattern> [opts]   Synchronize a storage root");
  writeln("  sync --all [pattern] [opts]  Synchronize matching storage roots");
  writeln("  list [<target>...] [opts]    List files & dirs (alias: files)");
  writeln("  duplicates [<target>...]     Find duplicate files/dirs");
  writeln("  unique [<target>...]         Find unique files/dirs");
  writeln("  import <db> [<pattern>...]   Import roots from another database");
  writeln("  migrate [--no-backup]        Migrate database schema\n");
  writeln("List Options & Target Syntax:");
  writeln(
    "  <target>...                  One or more target roots / paths:"
  );
  writeln(
    "                                 <root>         e.g. backup"
  );
  writeln(
    "                                 <root>:/<path> e.g. backup:/photos"
  );
  writeln(
    "                                 :/<path>       across all roots"
  );
  writeln(
    "                               Wildcards: % (LIKE) or * (with --glob)."
  );
  writeln(
    "                               Target is optional before --hash."
  );
  writeln(
    "  --glob                       Match target with SQLite GLOB (*, ?, " ~
    "[...])"
  );
  writeln(
    "  --hash <pattern>             Filter entries by SHA-256 via SQLite " ~
    "LIKE"
  );
  writeln(
    "  --type <all|file|dir>        Filter entry type (default: all)"
  );
  writeln(
    "  --sort <path|size|mtime>     Sort entries (default: path)\n"
  );
  writeln("Duplicates & Unique Options:");
  writeln(
    "  --glob                       Match target with SQLite GLOB (*, ?, " ~
    "[...])"
  );
  writeln(
    "  --type <all|file|dir>        Filter entry type (default: file)"
  );
  writeln(
    "  --skip-empty                 Skip empty files and directories\n"
  );
  writeln("Sync Options:");
  writeln(
    "  --force                      Sync when root path is empty but " ~
    "database is not"
  );
  writeln("  --force-hash                 Recompute SHA-256 for all files");
  writeln("  --no-progress                Disable in-place progress display");
  writeln("  --break-lock                 Break active sync lock if present");
  writeln(
    "  -j, --jobs <N>               Parallel sync jobs for --all (def: 1)"
  );
  writeln(
    "  --progress-interval <ms>     Progress refresh interval " ~
    "(ms, def: 1000)\n"
  );
  writeln("Import Options:");
  writeln("  --no-backup                  Skip saving a database backup");
  writeln(
    "  --no-update                  Only import new roots; skip updates\n"
  );
  writeln("Migrate Options:");
  writeln("  --no-backup                  Skip saving a database backup\n");
  writeln("Global Options:");
  writeln("  --db <path>                  SQLite database path");
  writeln("  --format <console|csv|html>  Output format (default: console)");
  writeln("  --csv                        Shorthand for --format csv");
  writeln("  --html                       Shorthand for --format html");
  writeln("  --color <auto|always|never>  Control ANSI colors");
  writeln("  --full-hash                  Show full 64-char hashes");
  writeln(
    "  --busy-timeout <ms>          SQLite busy timeout in ms (def: 60000)"
  );
}

int dispatchCommand(
  ref DbContext ctx,
  string[] subArgs,
  in OutputOptions opts
) {
  const subcmd = subArgs[0];
  switch (subcmd) {
    case "root":
      return handleRootCommand(ctx, subArgs, opts);
    case "sync":
      return handleSyncCommand(ctx, subArgs, opts);
    case "import":
      return handleImportCommand(ctx, subArgs, opts);
    case "migrate":
      return handleMigrateCommand(ctx, subArgs, opts);
    case "list":
    case "files":
      return handleListCommand(ctx.db, subArgs, opts);
    case "duplicates":
      return handleDuplicatesCommand(ctx.db, subArgs, opts);
    case "unique":
      return handleUniqueCommand(ctx.db, subArgs, opts);
    case "help":
      printUsage();
      return 0;
    default:
      stderr.writefln(
        "Unknown subcommand '%s'. Run 'listremo help'.", subcmd
      );
      return 1;
  }
}

int handleRootCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 2) {
    stderr.writeln("Usage: listremo root <add|remove|set-path|list>");
    return 1;
  }
  RootRepository rootRepo = RootRepository(ctx.db);
  const action = args[1];

  switch (action) {
    case "add":
      if (ctx.isReadOnly) {
        printReadOnlyError(ctx.dbSchemaVersion);
        return 1;
      }
      return handleRootAdd(rootRepo, args, opts);
    case "remove":
      if (ctx.isReadOnly) {
        printReadOnlyError(ctx.dbSchemaVersion);
        return 1;
      }
      return handleRootRemove(rootRepo, args, opts);
    case "set-path":
      if (ctx.isReadOnly) {
        printReadOnlyError(ctx.dbSchemaVersion);
        return 1;
      }
      return handleRootSetPath(rootRepo, args, opts);
    case "list":
      if (args.length > 3) {
        stderr.writeln("Usage: listremo root list [pattern]");
        return 1;
      }
      const pattern = args.length == 3 ? args[2] : null;
      const summaries = rootRepo.listRoots(pattern);
      outputRoots(summaries, opts);
      return 0;
    default:
      stderr.writefln("Unknown root action '%s'.", action);
      return 1;
  }
}

int handleRootAdd(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 4) {
    stderr.writeln("Usage: listremo root add <name> <path>");
    return 1;
  }
  try {
    rootRepo.addRoot(args[2], args[3]);
    if (opts.format == OutputFormat.console) {
      writefln("Registered root '%s' -> '%s'", args[2], args[3]);
    }
    return 0;
  } catch (Exception e) {
    stderr.writefln("Error: %s", e.msg);
    return 1;
  }
}

int handleRootRemove(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 3) {
    stderr.writeln("Usage: listremo root remove <name>");
    return 1;
  }
  if (rootRepo.removeRoot(args[2])) {
    if (opts.format == OutputFormat.console) {
      writefln("Removed root '%s' and cataloged entries.", args[2]);
    }
    return 0;
  }
  stderr.writefln("Error: Root '%s' not found.", args[2]);
  return 1;
}

int handleRootSetPath(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 4) {
    stderr.writeln("Usage: listremo root set-path <name> <new_path>");
    return 1;
  }
  if (rootRepo.setPath(args[2], args[3])) {
    if (opts.format == OutputFormat.console) {
      writefln("Updated path for '%s' -> '%s'", args[2], args[3]);
    }
    return 0;
  }
  stderr.writefln("Error: Root '%s' not found.", args[2]);
  return 1;
}

bool parseSyncArgs(string[] args, out SyncArgs parsed) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--all") {
      parsed.allFlag = true;
    } else if (arg == "--force") {
      parsed.forceFlag = true;
    } else if (arg == "--force-hash") {
      parsed.forceHash = true;
    } else if (arg == "--no-progress") {
      parsed.noProgress = true;
    } else if (arg == "--break-lock") {
      parsed.breakLock = true;
    } else if (arg == "--jobs" || arg == "-j") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --jobs option.");
        return false;
      }
      const valStr = args[++i];
      try {
        import std.conv : to;
        parsed.jobs = to!uint(valStr);
      } catch (Exception) {
        stderr.writefln(
          "Invalid --jobs value '%s'. Expected non-negative integer.",
          valStr
        );
        return false;
      }
    } else if (arg == "--progress-interval") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --progress-interval option.");
        return false;
      }
      const valStr = args[++i];
      try {
        import std.conv : to;
        parsed.progressIntervalMs = to!uint(valStr);
      } catch (Exception) {
        stderr.writefln(
          "Invalid --progress-interval value '%s'. Expected positive integer.",
          valStr
        );
        return false;
      }
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for sync.", arg);
      return false;
    } else {
      if (parsed.targetRoot.length > 0) {
        stderr.writefln("Unexpected argument '%s'.", arg);
        return false;
      }
      parsed.targetRoot = arg;
    }
  }

  if (!parsed.allFlag && parsed.targetRoot.length == 0) {
    stderr.writeln(
      "Usage: listremo sync <name|pattern> [options] OR --all [pattern]"
    );
    return false;
  }
  return true;
}

struct SyncRunContext {
  SyncArgs syncArgs;
  OutputOptions opts;
  ConsoleProgressReporter reporter;
  bool syncStarted = false;
}

int handleSyncCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (ctx.isReadOnly) {
    printReadOnlyError(ctx.dbSchemaVersion);
    return 1;
  }

  SyncArgs syncArgs;
  if (!parseSyncArgs(args, syncArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(ctx.db);
  Root[] toSync;
  if (syncArgs.allFlag) {
    if (syncArgs.targetRoot.length > 0) {
      toSync = rootRepo.findByPattern(syncArgs.targetRoot);
      if (toSync.length == 0) {
        stderr.writefln(
          "Error: No roots match pattern '%s'.", syncArgs.targetRoot
        );
        return 1;
      }
    } else {
      const summaries = rootRepo.listRoots();
      foreach (ref s; summaries) {
        toSync ~= s.root;
      }
    }
  } else {
    const matched = rootRepo.findByPattern(syncArgs.targetRoot);
    if (matched.length == 0) {
      if (hasPatternWildcard(syncArgs.targetRoot)) {
        stderr.writefln(
          "Error: No roots match pattern '%s'.", syncArgs.targetRoot
        );
      } else {
        stderr.writefln(
          "Error: Root '%s' not registered.", syncArgs.targetRoot
        );
      }
      return 1;
    }
    if (matched.length > 1) {
      import std.algorithm.iteration : map;
      import std.array : join;

      const names = matched.map!(r => r.name).join(", ");
      stderr.writefln(
        "Error: Pattern '%s' matches multiple roots (%s). " ~
        "Use --all to sync all matching roots.",
        syncArgs.targetRoot,
        names
      );
      return 1;
    }
    toSync ~= matched[0];
  }

  import core.time : MonoTime;

  const startMono = MonoTime.currTime;
  bool hadError = false;
  bool syncStarted = false;

  if (syncArgs.allFlag && syncArgs.jobs != 1 && toSync.length > 1) {
    hadError = runParallelSync(ctx, toSync, syncArgs, opts, syncStarted);
  } else {
    hadError = runSequentialSync(ctx, toSync, syncArgs, opts, syncStarted);
  }

  if (syncStarted && opts.format == OutputFormat.console) {
    const elapsed = MonoTime.currTime - startMono;
    writefln("Total time: %s", formatDuration(elapsed));
  }

  return hadError ? 1 : 0;
}

bool runParallelSync(
  ref DbContext ctx,
  in Root[] toSync,
  in SyncArgs syncArgs,
  in OutputOptions opts,
  out bool syncStarted
) {
  import core.sync.mutex : Mutex;
  import std.parallelism : TaskPool, totalCPUs;

  const numWorkers = (syncArgs.jobs == 0)
    ? totalCPUs
    : syncArgs.jobs;
  auto pool = new TaskPool(numWorkers);
  scope (exit) {
    pool.finish(true);
  }

  auto mtx = new Mutex();
  bool hadError = false;
  bool anyStarted = false;

  foreach (root; pool.parallel(toSync)) {
    auto threadDb = openDatabaseChecked(
      ctx.dbPath, ctx.busyTimeoutMs
    ).db;
    scope (exit) {
      threadDb.close();
    }

    SyncRunContext threadCtx = SyncRunContext(syncArgs, opts, null);
    if (!syncSingleRoot(threadDb, root, threadCtx)) {
      synchronized (mtx) {
        hadError = true;
      }
    }
    if (threadCtx.syncStarted) {
      synchronized (mtx) {
        anyStarted = true;
      }
    }
  }

  syncStarted = anyStarted;
  return hadError;
}

bool runSequentialSync(
  ref DbContext ctx,
  ref Root[] toSync,
  in SyncArgs syncArgs,
  in OutputOptions opts,
  out bool syncStarted
) {
  ConsoleProgressReporter reporter = null;
  if (opts.format == OutputFormat.console && !syncArgs.noProgress) {
    reporter = new ConsoleProgressReporter(
      opts, syncArgs.progressIntervalMs
    );
  }

  SyncRunContext runCtx = SyncRunContext(syncArgs, opts, reporter);
  bool hadError = false;
  foreach (ref root; toSync) {
    if (!syncSingleRoot(ctx.db, root, runCtx)) {
      hadError = true;
    }
  }

  syncStarted = runCtx.syncStarted;
  return hadError;
}

bool syncSingleRoot(
  ref Database db,
  const ref Root root,
  ref SyncRunContext runCtx
) {
  SyncLockRepository lockRepo = SyncLockRepository(db);
  const myPid = thisProcessID;
  const myHost = Socket.hostName;
  const now = Clock.currTime.toUnixTime();
  SyncLockInfo existingLock;

  bool acquired = lockRepo.acquireLock(
    root.id, myPid, myHost, now, existingLock
  );
  if (!acquired) {
    if (runCtx.syncArgs.breakLock) {
      lockRepo.breakLock(root.id);
      acquired = lockRepo.acquireLock(
        root.id, myPid, myHost, now, existingLock
      );
    } else if (existingLock.hostname == myHost
               && !isPidAlive(existingLock.pid)) {
      stderr.writefln(
        "Warning: Clearing stale sync lock on root '%s' " ~
        "(PID %d on %s is no longer active).",
        root.name,
        existingLock.pid,
        existingLock.hostname
      );
      lockRepo.breakLock(root.id);
      acquired = lockRepo.acquireLock(
        root.id, myPid, myHost, now, existingLock
      );
    }
  }

  if (!acquired) {
    stderr.writefln(
      "Error: Root '%s' is currently being synced by PID %d on host '%s' " ~
      "(started %s).",
      root.name,
      existingLock.pid,
      existingLock.hostname,
      formatUnixTime(existingLock.startedAt)
    );
    stderr.writeln(
      "Use 'listremo sync <name> --break-lock' if the process was terminated."
    );
    return false;
  }

  scope (exit) {
    lockRepo.releaseLock(root.id);
  }

  runCtx.syncStarted = true;

  if (runCtx.opts.format == OutputFormat.console) {
    writefln("Syncing root '%s' (%s)...", root.name, root.path);
  }
  try {
    SyncOptions syncOpts;
    syncOpts.force = runCtx.syncArgs.forceFlag;
    syncOpts.forceHash = runCtx.syncArgs.forceHash;
    if (runCtx.reporter !is null) {
      syncOpts.onProgress = &runCtx.reporter.onProgress;
    }
    syncOpts.onIssue = (const ref SyncIssue issue) {
      if (runCtx.reporter !is null) {
        runCtx.reporter.clear();
      }
      stderr.writefln(
        "Warning: Failed to %s '%s': %s",
        issue.isDir ? "access directory" : "read file",
        issue.path,
        issue.message
      );
    };

    const stats = syncRoot(db, root, syncOpts);
    if (runCtx.reporter !is null) {
      runCtx.reporter.clear();
    }
    if (runCtx.opts.format == OutputFormat.console) {
      writefln(
        "  Done: %d files, %d dirs, %d reused hashes.",
        stats.fileCount,
        stats.dirCount,
        stats.reusedHashes
      );
    }
    if (stats.errors.length > 0) {
      stderr.writefln("  Completed with %d error(s):", stats.errors.length);
      foreach (ref err; stats.errors) {
        stderr.writefln(
          "    - Failed to %s '%s': %s",
          err.isDir ? "access directory" : "read file",
          err.path,
          err.message
        );
      }
      return false;
    }
    return true;
  } catch (Exception e) {
    if (runCtx.reporter !is null) {
      runCtx.reporter.clear();
    }
    stderr.writefln("Error syncing root '%s': %s", root.name, e.msg);
    return false;
  }
}

bool parseMigrateArgs(string[] args, out MigrateArgs parsed) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--no-backup") {
      parsed.noBackup = true;
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for migrate.", arg);
      return false;
    } else {
      stderr.writefln("Unexpected argument '%s' for migrate.", arg);
      return false;
    }
  }
  return true;
}

int handleMigrateCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  MigrateArgs migrateArgs;
  if (!parseMigrateArgs(args, migrateArgs)) {
    return 1;
  }

  if (ctx.dbSchemaVersion == schemaVersion) {
    if (opts.format == OutputFormat.console) {
      writefln(
        "Database schema is already up to date (version %d).",
        schemaVersion
      );
    }
    return 0;
  }

  if (ctx.dbSchemaVersion < 0 || ctx.dbSchemaVersion > schemaVersion) {
    stderr.writefln(
      "Error: Cannot migrate database from schema version %d to %d.",
      ctx.dbSchemaVersion,
      schemaVersion
    );
    return 1;
  }

  if (!migrateArgs.noBackup && ctx.dbPath != ":memory:") {
    string backupPath;
    if (!promptBackupPath(ctx.dbPath, backupPath)) {
      return 1;
    }
    if (!writeDatabaseBackup(ctx.dbPath, backupPath, opts)) {
      return 1;
    }
  }

  try {
    const prevVersion = ctx.dbSchemaVersion;
    migrateDatabase(ctx.db, prevVersion);
    ctx.dbSchemaVersion = schemaVersion;
    ctx.isReadOnly = false;
    if (opts.format == OutputFormat.console) {
      writefln(
        "Migrated database schema from version %d to %d.",
        prevVersion,
        schemaVersion
      );
    }
    return 0;
  } catch (Exception e) {
    stderr.writefln("Error migrating database: %s", e.msg);
    return 1;
  }
}

bool parseTypeFilter(string val, out EntryType filter) {
  if (val == "all") {
    filter = EntryType.all;
    return true;
  }
  if (val == "file") {
    filter = EntryType.file;
    return true;
  }
  if (val == "dir") {
    filter = EntryType.dir;
    return true;
  }
  stderr.writefln(
    "Invalid --type '%s'. Valid values: all, file, dir.", val
  );
  return false;
}

bool parseSortField(string val, out SortField field) {
  if (val == "path") {
    field = SortField.path;
    return true;
  }
  if (val == "size") {
    field = SortField.size;
    return true;
  }
  if (val == "mtime") {
    field = SortField.mtime;
    return true;
  }
  stderr.writefln(
    "Invalid --sort '%s'. Valid values: path, size, mtime.", val
  );
  return false;
}

bool parseListArgs(string[] args, out ListArgs parsed) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--type") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --type option.");
        return false;
      }
      if (!parseTypeFilter(args[++i], parsed.typeFilter)) {
        return false;
      }
    } else if (arg == "--sort") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --sort option.");
        return false;
      }
      if (!parseSortField(args[++i], parsed.sortField)) {
        return false;
      }
    } else if (arg == "--glob") {
      parsed.useGlob = true;
    } else if (arg == "--hash") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --hash option.");
        return false;
      }
      parsed.hasHash = true;
      parsed.hashPattern = args[++i];
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for list.", arg);
      return false;
    } else {
      if (parsed.hasHash) {
        stderr.writefln(
          "Unexpected argument '%s'. Target path must be passed before --hash.",
          arg
        );
        return false;
      }
      parsed.targets ~= arg;
    }
  }

  if (parsed.targets.length == 0 && !parsed.hasHash) {
    stderr.writeln(
      "Usage: listremo list [<target>...] [--hash <pattern>] [--glob] " ~
      "[--type all|file|dir] [--sort path|size|mtime]"
    );
    return false;
  }
  return true;
}

bool validateTargetRoot(
  ref RootRepository rootRepo,
  string rootName,
  bool useGlob
) {
  const matched = useGlob
    ? rootRepo.findByGlob(rootName)
    : rootRepo.findByPattern(rootName);
  if (matched.length > 0) {
    return true;
  }
  const isWildcard = useGlob
    ? hasGlobWildcard(rootName)
    : hasPatternWildcard(rootName);
  if (isWildcard) {
    stderr.writefln("Error: No roots match pattern '%s'.", rootName);
  } else {
    stderr.writefln("Error: Root '%s' not found.", rootName);
  }
  return false;
}

int handleListCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  ListArgs listArgs;
  if (!parseListArgs(args, listArgs)) {
    return 1;
  }

  const rawTargets = listArgs.targets.length > 0
    ? listArgs.targets
    : [""];

  RootRepository rootRepo = RootRepository(db);
  TargetSpec[] specs;
  foreach (t; rawTargets) {
    const spec = TargetSpec.parse(t, listArgs.useGlob);
    if (!validateTargetRoot(rootRepo, spec.rootName, listArgs.useGlob)) {
      return 1;
    }
    specs ~= spec;
  }

  EntryRepository entryRepo = EntryRepository(db);
  Entry[] allEntries;
  bool[long] seenIds;

  foreach (ref spec; specs) {
    ListEntriesFilter filter;
    filter.subpath = spec.hasSubpath ? spec.subpath : null;
    filter.typeFilter = listArgs.typeFilter;
    filter.sort = listArgs.sortField;
    filter.useGlob = listArgs.useGlob;
    filter.hashPattern = listArgs.hasHash ? listArgs.hashPattern : null;

    const batch = entryRepo.listEntries(spec.rootName, filter);
    foreach (ref e; batch) {
      if (e.id !in seenIds) {
        seenIds[e.id] = true;
        allEntries ~= e;
      }
    }
  }

  outputEntries(allEntries, opts);
  return 0;
}

bool parseDuplicateOrUniqueArgs(
  string cmdName,
  string[] args,
  out DuplicateOrUniqueArgs parsed
) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--type") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --type option.");
        return false;
      }
      if (!parseTypeFilter(args[++i], parsed.typeFilter)) {
        return false;
      }
    } else if (arg == "--glob") {
      parsed.useGlob = true;
    } else if (arg == "--skip-empty") {
      parsed.skipEmpty = true;
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for %s.", arg, cmdName);
      return false;
    } else {
      parsed.targets ~= arg;
    }
  }
  return true;
}

bool resolveHashQueryFilter(
  ref RootRepository rootRepo,
  in DuplicateOrUniqueArgs args,
  out HashQueryFilter filter
) {
  filter.typeFilter = args.typeFilter;
  filter.skipEmpty = args.skipEmpty;
  filter.useGlob = args.useGlob;
  filter.hasRoot = false;
  filter.rootPattern = null;
  filter.subpath = null;

  if (args.targets.length == 0) {
    return true;
  }

  foreach (t; args.targets) {
    const spec = TargetSpec.parse(t, args.useGlob);
    if (!validateTargetRoot(rootRepo, spec.rootName, args.useGlob)) {
      return false;
    }
    filter.targets ~= spec;
  }
  return true;
}

int handleDuplicatesCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  DuplicateOrUniqueArgs parsedArgs;
  if (!parseDuplicateOrUniqueArgs("duplicates", args, parsedArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(db);
  HashQueryFilter filter;
  if (!resolveHashQueryFilter(rootRepo, parsedArgs, filter)) {
    return 1;
  }

  EntryRepository entryRepo = EntryRepository(db);
  const rawEntries = entryRepo.listDuplicates(filter);
  const groups = entryRepo.groupDuplicates(rawEntries);
  outputDuplicates(groups, opts);
  return 0;
}

int handleUniqueCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  DuplicateOrUniqueArgs parsedArgs;
  if (!parseDuplicateOrUniqueArgs("unique", args, parsedArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(db);
  HashQueryFilter filter;
  if (!resolveHashQueryFilter(rootRepo, parsedArgs, filter)) {
    return 1;
  }

  EntryRepository entryRepo = EntryRepository(db);
  const entries = entryRepo.listUnique(filter);
  outputUnique(entries, opts);
  return 0;
}

unittest {
  import orglistremo.db.connection : openDatabase;

  // Test global options parsing
  string[] validArgs = ["listremo", "--format", "csv", "--color", "never"];
  CliGlobalOptions globals;
  assert(parseGlobalOptions(validArgs, globals));
  assert(globals.formatStr == "csv");
  assert(globals.colorStr == "never");

  OutputOptions opts;
  assert(buildOutputOptions(globals, opts));
  assert(opts.format == OutputFormat.csv);
  assert(!opts.styler.enabled);

  // Test html format and flags
  string[] htmlArgs = ["listremo", "--format", "html"];
  CliGlobalOptions htmlGlobals;
  assert(parseGlobalOptions(htmlArgs, htmlGlobals));
  assert(htmlGlobals.formatStr == "html");
  OutputOptions htmlOpts;
  assert(buildOutputOptions(htmlGlobals, htmlOpts));
  assert(htmlOpts.format == OutputFormat.html);

  string[] htmlFlagArgs = ["listremo", "--html"];
  CliGlobalOptions htmlFlagGlobals;
  assert(parseGlobalOptions(htmlFlagArgs, htmlFlagGlobals));
  assert(htmlFlagGlobals.htmlFlag);
  OutputOptions htmlFlagOpts;
  assert(buildOutputOptions(htmlFlagGlobals, htmlFlagOpts));
  assert(htmlFlagOpts.format == OutputFormat.html);

  // Test conflicting csv and html flags
  string[] formatConflictArgs = ["listremo", "--csv", "--html"];
  CliGlobalOptions conflictGlobals;
  assert(parseGlobalOptions(formatConflictArgs, conflictGlobals));
  OutputOptions conflictOpts;
  assert(!buildOutputOptions(conflictGlobals, conflictOpts));

  // Test invalid global options
  globals.formatStr = "xml";
  assert(!buildOutputOptions(globals, opts));
  globals.formatStr = "console";
  globals.colorStr = "rainbow";
  assert(!buildOutputOptions(globals, opts));

  // Test sync args parsing & validation
  SyncArgs syncArgs;
  assert(parseSyncArgs(["sync", "myroot", "--force-hash"], syncArgs));
  assert(syncArgs.targetRoot == "myroot");
  assert(syncArgs.forceHash);
  assert(!syncArgs.forceFlag);
  assert(!syncArgs.allFlag);

  SyncArgs syncForce;
  assert(parseSyncArgs(["sync", "myroot", "--force"], syncForce));
  assert(syncForce.targetRoot == "myroot");
  assert(syncForce.forceFlag);
  assert(!syncForce.forceHash);

  SyncArgs syncAll;
  assert(
    parseSyncArgs(
      ["sync", "--all", "--force", "--force-hash"], syncAll
    )
  );
  assert(syncAll.allFlag);
  assert(syncAll.forceFlag);
  assert(syncAll.forceHash);

  // Sync --all with pattern is supported
  SyncArgs syncAllPattern;
  assert(parseSyncArgs(["sync", "myroot", "--all"], syncAllPattern));
  assert(syncAllPattern.allFlag);
  assert(syncAllPattern.targetRoot == "myroot");

  SyncArgs syncAllPrefix;
  assert(parseSyncArgs(["sync", "--all", "backup%"], syncAllPrefix));
  assert(syncAllPrefix.allFlag);
  assert(syncAllPrefix.targetRoot == "backup%");

  // Missing sync target without --all
  SyncArgs missingSyncTarget;
  assert(!parseSyncArgs(["sync"], missingSyncTarget));

  // Too many positional arguments
  SyncArgs tooManyArgs;
  assert(!parseSyncArgs(["sync", "r1", "r2"], tooManyArgs));

  // Unknown sync flag
  SyncArgs unknownFlagArgs;
  assert(!parseSyncArgs(["sync", "--bogus"], unknownFlagArgs));

  // Break-lock flag
  SyncArgs syncBreakLockArgs;
  assert(parseSyncArgs(["sync", "myroot", "--break-lock"], syncBreakLockArgs));
  assert(syncBreakLockArgs.breakLock);

  // Jobs flag
  SyncArgs syncJobsArgs;
  assert(parseSyncArgs(["sync", "--all", "-j", "4"], syncJobsArgs));
  assert(syncJobsArgs.jobs == 4);

  // Sync progress options
  SyncArgs syncProgArgs;
  assert(
    parseSyncArgs(
      ["sync", "myroot", "--no-progress", "--progress-interval", "500"],
      syncProgArgs
    )
  );
  assert(syncProgArgs.targetRoot == "myroot");
  assert(syncProgArgs.noProgress);
  assert(syncProgArgs.progressIntervalMs == 500);

  SyncArgs syncInvalidInterval;
  assert(
    !parseSyncArgs(
      ["sync", "myroot", "--progress-interval", "notanumber"],
      syncInvalidInterval
    )
  );

  SyncArgs syncMissingInterval;
  assert(
    !parseSyncArgs(
      ["sync", "myroot", "--progress-interval"],
      syncMissingInterval
    )
  );

  // Test list args parsing & validation
  ListArgs listArgs;
  assert(
    parseListArgs(
      ["list", "myroot", "other:/sub", "--type", "file", "--sort", "size"],
      listArgs
    )
  );
  assert(listArgs.targets == ["myroot", "other:/sub"]);
  assert(listArgs.typeFilter == EntryType.file);
  assert(listArgs.sortField == SortField.size);

  ListArgs invalidType;
  assert(!parseListArgs(["list", "myroot", "--type", "invalid"], invalidType));

  ListArgs missingTypeVal;
  assert(!parseListArgs(["list", "myroot", "--type"], missingTypeVal));

  // Test duplicate / unique args parsing & validation
  DuplicateOrUniqueArgs dupArgs;
  assert(
    parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "--type", "all", "--skip-empty"], dupArgs
    )
  );
  assert(dupArgs.typeFilter == EntryType.all);
  assert(dupArgs.skipEmpty);

  DuplicateOrUniqueArgs dupGlobArgs;
  assert(
    parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "r*", "b*:/sub", "--glob"], dupGlobArgs
    )
  );
  assert(dupGlobArgs.targets == ["r*", "b*:/sub"]);
  assert(dupGlobArgs.useGlob);

  DuplicateOrUniqueArgs dupUnknown;
  assert(
    !parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "--unknown"], dupUnknown
    )
  );

  // Test command execution on memory db
  Database db = openDatabase(":memory:");
  DbContext ctx = DbContext(db, ":memory:", schemaVersion, false);
  OutputOptions testOpts;
  testOpts.styler.enabled = false;

  // Root commands
  assert(
    handleRootCommand(ctx, ["root", "add", "r1", "/mnt/r1"], testOpts) == 0
  );
  assert(handleRootCommand(ctx, ["root", "list"], testOpts) == 0);
  assert(
    handleRootCommand(
      ctx, ["root", "set-path", "r1", "/mnt/new"], testOpts
    ) == 0
  );
  assert(handleRootCommand(ctx, ["root", "remove", "r1"], testOpts) == 0);

  // Sync commands with empty root and --force
  import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
  import std.path : buildPath;
  const syncTempDir = buildPath(tempDir(), "listremo_app_sync_test");
  if (exists(syncTempDir)) {
    rmdirRecurse(syncTempDir);
  }
  mkdirRecurse(syncTempDir);
  scope (exit) {
    if (exists(syncTempDir)) {
      rmdirRecurse(syncTempDir);
    }
  }

  assert(
    handleRootCommand(
      ctx, ["root", "add", "r_temp", syncTempDir], testOpts
    ) == 0
  );
  // Initially empty directory and empty DB -> returns 0
  assert(
    handleSyncCommand(
      ctx, ["sync", "r_temp", "--no-progress"], testOpts
    ) == 0
  );

  // Inject entry into DB
  RootRepository rootRepo = RootRepository(db);
  Root rTemp;
  assert(rootRepo.findByName("r_temp", rTemp));
  EntryRepository entryRepo = EntryRepository(db);
  Entry dummy;
  dummy.rootId = rTemp.id;
  dummy.rootName = rTemp.name;
  dummy.relPath = "f.txt";
  dummy.name = "f.txt";
  dummy.isDir = false;
  dummy.size = 5;
  dummy.mtime = 1000;
  dummy.sha256 = "abc";
  entryRepo.saveSyncEntries(rTemp.id, [dummy], 1000);
  assert(entryRepo.hasCatalogedEntries(rTemp.id));

  // Sync without --force -> fatal error, returns 1
  assert(
    handleSyncCommand(
      ctx, ["sync", "r_temp", "--no-progress"], testOpts
    ) == 1
  );
  assert(entryRepo.hasCatalogedEntries(rTemp.id));

  // Sync with --force -> succeeds, returns 0
  assert(
    handleSyncCommand(
      ctx, ["sync", "r_temp", "--force", "--no-progress"], testOpts
    ) == 0
  );
  assert(!entryRepo.hasCatalogedEntries(rTemp.id));

  // Test sync continues on unreadable file and returns 1
  import std.file : write;
  import std.process : execute;
  write(buildPath(syncTempDir, "ok.txt"), "good content");
  write(buildPath(syncTempDir, "bad.txt"), "secret content");
  execute(["chmod", "000", buildPath(syncTempDir, "bad.txt")]);
  scope (exit) {
    execute(["chmod", "644", buildPath(syncTempDir, "bad.txt")]);
  }

  // Returns 1 because errors occurred during sync
  assert(
    handleSyncCommand(
      ctx, ["sync", "r_temp", "--no-progress"], testOpts
    ) == 1
  );
  // Verify ok.txt was cataloged
  const rEntries = entryRepo.listEntries(rTemp.id);
  bool foundOk = false;
  foreach (ref e; rEntries) {
    if (e.relPath == "ok.txt") {
      foundOk = true;
    }
  }
  assert(foundOk);
}

unittest {
  import orglistremo.db.connection : readDbSchemaVersion;
  import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
  import std.path : buildPath;
  import std.process : execute;

  // Test migrate args parsing
  MigrateArgs migDefault;
  assert(parseMigrateArgs(["migrate"], migDefault));
  assert(!migDefault.noBackup);

  MigrateArgs migNoBackup;
  assert(parseMigrateArgs(["migrate", "--no-backup"], migNoBackup));
  assert(migNoBackup.noBackup);

  MigrateArgs migInvalidFlag;
  assert(!parseMigrateArgs(["migrate", "--unknown"], migInvalidFlag));

  MigrateArgs migInvalidPos;
  assert(!parseMigrateArgs(["migrate", "extra"], migInvalidPos));

  // Test backup path proposal and read-only / migration workflow
  const migDir = buildPath(tempDir(), "listremo_app_migrate_test");
  if (exists(migDir)) {
    execute(["chmod", "-R", "755", migDir]);
    rmdirRecurse(migDir);
  }
  mkdirRecurse(migDir);
  scope (exit) {
    if (exists(migDir)) {
      execute(["chmod", "-R", "755", migDir]);
      rmdirRecurse(migDir);
    }
  }

  const dbFile = buildPath(migDir, "catalog.db");
  const backup1 = buildPath(migDir, "catalog-backup-1.db");
  const backup2 = buildPath(migDir, "catalog-backup-2.db");

  assert(proposeBackupPath(dbFile) == backup1);
  write(backup1, "existing backup");
  assert(proposeBackupPath(dbFile) == backup2);

  // Create legacy v0 database with roots and entries
  {
    auto rawDb = Database(dbFile);
    rawDb.execute(`
      CREATE TABLE roots (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL UNIQUE,
        path        TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        last_sync   INTEGER
      );
    `);
    rawDb.execute(`
      CREATE TABLE entries (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        root_id     INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
        rel_path    TEXT NOT NULL,
        parent_path TEXT,
        name        TEXT NOT NULL,
        is_dir      INTEGER NOT NULL,
        size        INTEGER NOT NULL,
        mtime       INTEGER NOT NULL,
        sha256      TEXT NOT NULL,
        UNIQUE(root_id, rel_path)
      );
    `);
    rawDb.execute(`
      INSERT INTO roots (name, path, created_at)
      VALUES ('old_root', '/mnt/old', 1650000000);
    `);
    rawDb.close();
  }

  DbOpenResult openRes = openDatabaseChecked(dbFile);
  assert(openRes.isReadOnly);
  assert(openRes.dbSchemaVersion == 0);

  DbContext roCtx = DbContext(
    openRes.db, dbFile, openRes.dbSchemaVersion, openRes.isReadOnly
  );
  OutputOptions opts;
  opts.styler.enabled = false;

  // Read-only commands succeed
  assert(dispatchCommand(roCtx, ["root", "list"], opts) == 0);
  assert(dispatchCommand(roCtx, ["list", "old_root"], opts) == 0);
  assert(dispatchCommand(roCtx, ["duplicates"], opts) == 0);
  assert(dispatchCommand(roCtx, ["unique"], opts) == 0);

  // Editing commands are blocked in read-only mode
  assert(dispatchCommand(roCtx, ["root", "add", "r2", "/mnt/r2"], opts) == 1);
  assert(dispatchCommand(roCtx, ["root", "remove", "old_root"], opts) == 1);
  assert(
    dispatchCommand(
      roCtx, ["root", "set-path", "old_root", "/mnt/new"], opts
    ) == 1
  );
  assert(dispatchCommand(roCtx, ["sync", "old_root"], opts) == 1);

  // Test writeDatabaseBackup failure preserves original database intact
  const roBackupDir = buildPath(migDir, "unwritable_dir");
  mkdirRecurse(roBackupDir);
  execute(["chmod", "500", roBackupDir]);
  const badBackupPath = buildPath(roBackupDir, "backup.db");
  assert(!writeDatabaseBackup(dbFile, badBackupPath, opts));
  assert(readDbSchemaVersion(roCtx.db) == 0);

  // Migrate with --no-backup upgrades schema and unlocks write commands
  assert(dispatchCommand(roCtx, ["migrate", "--no-backup"], opts) == 0);
  assert(!roCtx.isReadOnly);
  assert(roCtx.dbSchemaVersion == schemaVersion);
  assert(readDbSchemaVersion(roCtx.db) == schemaVersion);

  // Calling migrate again when already up to date succeeds as no-op
  assert(dispatchCommand(roCtx, ["migrate", "--no-backup"], opts) == 0);

  // Editing command now works
  assert(dispatchCommand(roCtx, ["root", "add", "r2", "/mnt/r2"], opts) == 0);

  // Test root sync lock, stale lock auto-break, and --break-lock
  const testRootPath = buildPath(migDir, "sync_lock_test_dir");
  mkdirRecurse(testRootPath);
  assert(
    dispatchCommand(
      roCtx, ["root", "add", "lock_root", testRootPath], opts
    ) == 0
  );

  Root lockRoot;
  assert(RootRepository(roCtx.db).findByName("lock_root", lockRoot));

  SyncLockRepository lockRepo = SyncLockRepository(roCtx.db);
  SyncLockInfo existing;

  // 1. Artificially acquire lock by thisProcessID (active process)
  assert(
    lockRepo.acquireLock(
      lockRoot.id, thisProcessID, Socket.hostName, 1700000000, existing
    )
  );

  // Sync should fail because root is locked
  assert(dispatchCommand(roCtx, ["sync", "lock_root"], opts) == 1);

  // Sync with --break-lock should succeed
  assert(
    dispatchCommand(
      roCtx, ["sync", "lock_root", "--break-lock"], opts
    ) == 0
  );

  // 2. Artificially acquire lock with a dead PID (stale lock)
  version (Posix) {
    assert(
      lockRepo.acquireLock(
        lockRoot.id, 99_999_999, Socket.hostName, 1700000000, existing
      )
    );
    // Sync without --break-lock should auto-clear stale lock and succeed
    assert(dispatchCommand(roCtx, ["sync", "lock_root"], opts) == 0);
  }

  roCtx.db.close();
}

unittest {
  import orglistremo.db.connection : openDatabase;
  import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
  import std.path : buildPath;

  const appTestDir = buildPath(tempDir(), "listremo_pattern_test");
  if (exists(appTestDir)) {
    rmdirRecurse(appTestDir);
  }
  mkdirRecurse(appTestDir);
  scope (exit) {
    if (exists(appTestDir)) {
      rmdirRecurse(appTestDir);
    }
  }

  const d1 = buildPath(appTestDir, "d1");
  const d2 = buildPath(appTestDir, "d2");
  mkdirRecurse(d1);
  mkdirRecurse(d2);

  Database db = openDatabase(":memory:");
  DbContext ctx = DbContext(db, ":memory:", schemaVersion, false, 60_000);
  OutputOptions opts;
  opts.format = OutputFormat.console;

  // 1. Test root add and root list [pattern]
  assert(dispatchCommand(ctx, ["root", "add", "alpha_1", d1], opts) == 0);
  assert(dispatchCommand(ctx, ["root", "add", "alpha_2", d2], opts) == 0);
  assert(dispatchCommand(ctx, ["root", "add", "beta", d2], opts) == 0);

  assert(dispatchCommand(ctx, ["root", "list"], opts) == 0);
  assert(dispatchCommand(ctx, ["root", "list", "alpha%"], opts) == 0);
  assert(dispatchCommand(ctx, ["root", "list", "beta"], opts) == 0);
  assert(dispatchCommand(ctx, ["root", "list", "nonexistent%"], opts) == 0);
  assert(dispatchCommand(ctx, ["root", "list", "too", "many"], opts) == 1);

  // 2. Test sync with pattern
  // sync alpha% should fail because multiple roots match
  assert(dispatchCommand(ctx, ["sync", "alpha%", "--no-progress"], opts) == 1);

  // sync --all alpha% should succeed and sync both roots
  assert(
    dispatchCommand(
      ctx, ["sync", "--all", "alpha%", "--no-progress"], opts
    ) == 0
  );

  // sync beta (single match) should succeed
  assert(dispatchCommand(ctx, ["sync", "beta", "--no-progress"], opts) == 0);

  // sync b% (single match) should succeed
  assert(dispatchCommand(ctx, ["sync", "b%", "--no-progress"], opts) == 0);

  // sync nonexistent pattern should fail
  assert(
    dispatchCommand(
      ctx, ["sync", "nonexistent%", "--no-progress"], opts
    ) == 1
  );
  assert(
    dispatchCommand(
      ctx, ["sync", "--all", "nonexistent%", "--no-progress"], opts
    ) == 1
  );

  // 3. Test list with pattern
  // List across all roots
  assert(dispatchCommand(ctx, ["list", "%"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", ":"], opts) == 0);

  // List across multiple matching roots
  assert(dispatchCommand(ctx, ["list", "alpha%"], opts) == 0);

  // List specific root with pattern in path
  assert(dispatchCommand(ctx, ["list", "alpha_1:%"], opts) == 0);

  // List nonexistent root pattern
  assert(dispatchCommand(ctx, ["list", "nonexistent%"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "nonexistent"], opts) == 1);

  // 4. Test list with --glob and --hash
  // Missing target without --hash should fail
  assert(dispatchCommand(ctx, ["list"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "--glob"], opts) == 1);

  // Missing value for --hash
  assert(dispatchCommand(ctx, ["list", "--hash"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "alpha_1", "--hash"], opts) == 1);

  // Positional argument after --hash should fail
  assert(
    dispatchCommand(ctx, ["list", "--hash", "0", "alpha_1"], opts) == 1
  );

  // Multiple target patterns succeed; fail if any pattern matches no root
  assert(
    dispatchCommand(ctx, ["list", "alpha%", "beta"], opts) == 0
  );
  assert(
    dispatchCommand(ctx, ["list", "alpha%", "nonexistent"], opts) == 1
  );

  // --hash across all roots without target
  assert(dispatchCommand(ctx, ["list", "--hash", "0"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "--hash", "e3b0%"], opts) == 0);

  // --hash with target(s) preceding it
  assert(
    dispatchCommand(ctx, ["list", "alpha_1", "--hash", "0"], opts) == 0
  );
  assert(
    dispatchCommand(
      ctx, ["list", "alpha_1:/", "beta", "--hash", "0"], opts
    ) == 0
  );

  // --glob matching
  assert(dispatchCommand(ctx, ["list", "alpha*", "--glob"], opts) == 0);
  assert(
    dispatchCommand(
      ctx, ["list", "alpha_[12]", "beta", "--glob"], opts
    ) == 0
  );
  assert(
    dispatchCommand(ctx, ["list", "alpha_1:*", "--glob"], opts) == 0
  );
  assert(dispatchCommand(ctx, ["list", ":*", "--glob"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "ALPHA*", "--glob"], opts) == 1);

  // Combined --glob and --hash
  assert(
    dispatchCommand(
      ctx, ["list", "alpha*", "--glob", "--hash", "0"], opts
    ) == 0
  );
  assert(
    dispatchCommand(ctx, ["list", "--glob", "--hash", "0"], opts) == 0
  );

  // Alias 'files'
  assert(dispatchCommand(ctx, ["files", "--hash", "0"], opts) == 0);

  // 5. Test duplicates with pattern(s) and --glob
  assert(dispatchCommand(ctx, ["duplicates", "alpha%"], opts) == 0);
  assert(
    dispatchCommand(ctx, ["duplicates", "alpha%", "beta"], opts) == 0
  );
  assert(
    dispatchCommand(ctx, ["duplicates", "alpha*", "--glob"], opts) == 0
  );
  assert(
    dispatchCommand(
      ctx, ["duplicates", "alpha_[12]", "beta", "--glob"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["duplicates", "alpha_1:/"], opts) == 0);
  assert(dispatchCommand(ctx, ["duplicates", ":/", "--glob"], opts) == 0);
  assert(
    dispatchCommand(ctx, ["duplicates", "ALPHA*", "--glob"], opts) == 1
  );
  assert(dispatchCommand(ctx, ["duplicates", "nonexistent%"], opts) == 1);
  assert(dispatchCommand(ctx, ["duplicates", "nonexistent"], opts) == 1);
  assert(
    dispatchCommand(
      ctx, ["duplicates", "alpha%", "nonexistent"], opts
    ) == 1
  );

  // 6. Test unique with pattern(s) and --glob
  assert(dispatchCommand(ctx, ["unique", "alpha%"], opts) == 0);
  assert(
    dispatchCommand(ctx, ["unique", "alpha%", "beta"], opts) == 0
  );
  assert(
    dispatchCommand(ctx, ["unique", "alpha*", "--glob"], opts) == 0
  );
  assert(
    dispatchCommand(
      ctx, ["unique", "alpha_[12]", "beta", "--glob"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["unique", "alpha_1:/"], opts) == 0);
  assert(dispatchCommand(ctx, ["unique", ":/", "--glob"], opts) == 0);
  assert(
    dispatchCommand(ctx, ["unique", "ALPHA*", "--glob"], opts) == 1
  );
  assert(dispatchCommand(ctx, ["unique", "nonexistent%"], opts) == 1);
  assert(dispatchCommand(ctx, ["unique", "nonexistent"], opts) == 1);
  assert(
    dispatchCommand(
      ctx, ["unique", "alpha%", "nonexistent"], opts
    ) == 1
  );
}
