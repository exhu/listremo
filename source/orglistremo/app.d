module orglistremo.app;

import d2sqlite3 : Database;
import orglistremo.cli;
import orglistremo.cli.context : DbContext;
import orglistremo.cli.ignore_cmd :
  handleIgnoreCommand, handleIgnoreDeleteCommand;
import orglistremo.cli.import_cmd : handleImportCommand;
import orglistremo.cli.migrate_cmd : handleMigrateCommand;
import orglistremo.cli.query_cmd :
  handleDuplicatesCommand, handleListCommand, handleUniqueCommand;
import orglistremo.cli.root_cmd : handleRootCommand;
import orglistremo.cli.sync_cmd : handleSyncCommand;
import orglistremo.cli.usage : printUsage;
import orglistremo.config : resolveDbPath;
import orglistremo.db.connection : DbOpenResult, openDatabaseChecked;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.output.console : shouldColorize;
import orglistremo.output.options : ColorMode, OutputFormat, OutputOptions;
import std.getopt : config, getopt;
import std.stdio : stderr, writefln, writeln;

version (unittest) {
  import orglistremo.app_version;
  import orglistremo.db;
  import orglistremo.internal.assets;
  import orglistremo.internal.os;
  import orglistremo.internal.testutil;
  import orglistremo.model;
  import orglistremo.output;
  import orglistremo.pattern;
  import orglistremo.sync;
} else {
  int main(string[] args) {
    return runApp(args);
  }
}

package(orglistremo):

int runApp(string[] args) {
  CliGlobalOptions globals;
  if (!parseGlobalOptions(args, globals)) {
    return 1;
  }

  if (globals.showHelp || args.length <= 1 || args[1] == "help") {
    printUsage();
    return 0;
  }

  if (args[1].length > 0 && args[1][0] == '-') {
    stderr.writefln("Unrecognized option '%s'. Run 'listremo help'.", args[1]);
    return 1;
  }

  OutputOptions opts;
  if (!buildOutputOptions(globals, opts)) {
    return 1;
  }

  DbContext ctx;
  if (!openAppDatabase(globals, ctx)) {
    return 1;
  }
  scope (exit) {
    ctx.db.close();
  }

  return dispatchCommand(ctx, args[1 .. $], opts);
}

int dispatchCommand(
  ref DbContext ctx,
  string[] subArgs,
  in OutputOptions opts
) {
  const string subcmd = subArgs[0];
  switch (subcmd) {
    case "root":
      return handleRootCommand(ctx, subArgs, opts);
    case "ignore":
      return handleIgnoreCommand(ctx, subArgs, opts);
    case "ignore-delete":
      return handleIgnoreDeleteCommand(ctx, subArgs, opts);
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

bool openAppDatabase(in CliGlobalOptions globals, out DbContext ctx) {
  const string dbPath = resolveDbPath(globals.cliDb);
  DbOpenResult openRes;
  try {
    openRes = openDatabaseChecked(dbPath, globals.busyTimeoutMs);
  } catch (Exception e) {
    stderr.writefln("Failed to open database '%s': %s", dbPath, e.msg);
    return false;
  }

  if (openRes.isReadOnly) {
    printSchemaMismatchWarning(openRes.dbSchemaVersion);
  }

  ctx = DbContext(
    openRes.db,
    dbPath,
    openRes.dbSchemaVersion,
    openRes.isReadOnly,
    globals.busyTimeoutMs
  );
  return true;
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

bool parseColorMode(string colorStr, out ColorMode colorMode) {
  if (colorStr == "auto") {
    colorMode = ColorMode.autoMode;
    return true;
  }
  if (colorStr == "always") {
    colorMode = ColorMode.always;
    return true;
  }
  if (colorStr == "never") {
    colorMode = ColorMode.never;
    return true;
  }
  stderr.writefln(
    "Invalid --color '%s'. Valid values: auto, always, never.",
    colorStr
  );
  return false;
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
  if (!parseColorMode(globals.colorStr, colorMode)) {
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

unittest {
  import orglistremo.db.backup : proposeBackupPath, writeDatabaseBackup;
  import orglistremo.db.connection : openDatabase, readDbSchemaVersion;
  import orglistremo.db.repo : EntryRepository, RootRepository;
  import orglistremo.db.repo_locks :
    LockRequest, SyncLockInfo, SyncLockRepository;
  import orglistremo.internal.os : getLocalHostName;
  import orglistremo.internal.testutil :
    createLegacyV0Db, LegacyV0Options, TempDir;
  import orglistremo.model : Entry, Root;
  import std.exception : assertThrown;
  import std.file : mkdirRecurse, write;
  import std.path : buildPath;
  import std.process : execute, thisProcessID;

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

  // Test command execution on memory db
  Database db = openDatabase(":memory:");
  DbContext ctx = DbContext(db, ":memory:", schemaVersion, false);
  OutputOptions testOpts;
  testOpts.styler.enabled = false;

  TempDir syncTempDir = TempDir("app_sync");

  assert(
    handleRootCommand(
      ctx, ["root", "add", "r_temp", syncTempDir.path], testOpts
    ) == 0
  );
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
  write(syncTempDir.subPath("ok.txt"), "good content");
  write(syncTempDir.subPath("bad.txt"), "secret content");
  execute(["chmod", "000", syncTempDir.subPath("bad.txt")]);
  scope (exit) {
    execute(["chmod", "644", syncTempDir.subPath("bad.txt")]);
  }

  assert(
    handleSyncCommand(
      ctx, ["sync", "r_temp", "--no-progress"], testOpts
    ) == 1
  );
  const rEntries = entryRepo.listEntriesByRootId(rTemp.id);
  bool foundOk = false;
  foreach (ref e; rEntries) {
    if (e.relPath == "ok.txt") {
      foundOk = true;
    }
  }
  assert(foundOk);

  // Test backup path proposal and read-only / migration workflow
  TempDir migDir = TempDir("app_migrate");
  const dbFile = migDir.subPath("catalog.db");
  const backup1 = migDir.subPath("catalog-backup-1.db");
  const backup2 = migDir.subPath("catalog-backup-2.db");

  assert(proposeBackupPath(dbFile) == backup1);
  write(backup1, "existing backup");
  assert(proposeBackupPath(dbFile) == backup2);

  createLegacyV0Db(
    dbFile, LegacyV0Options("old_root", "/mnt/old", 1650000000)
  );

  DbOpenResult openRes = openDatabaseChecked(dbFile);
  assert(openRes.isReadOnly);
  assert(openRes.dbSchemaVersion == 0);

  DbContext roCtx = DbContext(
    openRes.db, dbFile, openRes.dbSchemaVersion, openRes.isReadOnly
  );

  // Read-only commands succeed
  assert(dispatchCommand(roCtx, ["root", "list"], testOpts) == 0);
  assert(dispatchCommand(roCtx, ["list", "old_root"], testOpts) == 0);
  assert(dispatchCommand(roCtx, ["duplicates"], testOpts) == 0);
  assert(dispatchCommand(roCtx, ["unique"], testOpts) == 0);

  // Editing commands are blocked in read-only mode
  assert(
    dispatchCommand(roCtx, ["root", "add", "r2", "/mnt/r2"], testOpts) == 1
  );
  assert(
    dispatchCommand(roCtx, ["root", "remove", "old_root"], testOpts) == 1
  );
  assert(
    dispatchCommand(
      roCtx, ["root", "set-path", "old_root", "/mnt/new"], testOpts
    ) == 1
  );
  assert(dispatchCommand(roCtx, ["sync", "old_root"], testOpts) == 1);

  const roBackupDir = buildPath(migDir, "unwritable_dir");
  mkdirRecurse(roBackupDir);
  execute(["chmod", "500", roBackupDir]);
  const badBackupPath = buildPath(roBackupDir, "backup.db");
  assertThrown!Exception(writeDatabaseBackup(roCtx.db, badBackupPath));
  assert(readDbSchemaVersion(roCtx.db) == 0);

  // Migrate with --no-backup upgrades schema and unlocks write commands
  assert(dispatchCommand(roCtx, ["migrate", "--no-backup"], testOpts) == 0);
  assert(!roCtx.isReadOnly);
  assert(roCtx.dbSchemaVersion == schemaVersion);
  assert(readDbSchemaVersion(roCtx.db) == schemaVersion);

  // Calling migrate again when already up to date succeeds as no-op
  assert(dispatchCommand(roCtx, ["migrate", "--no-backup"], testOpts) == 0);

  // Editing command now works
  assert(
    dispatchCommand(roCtx, ["root", "add", "r2", "/mnt/r2"], testOpts) == 0
  );

  // Test root sync lock, stale lock auto-break, and --break-lock
  const testRootPath = buildPath(migDir, "sync_lock_test_dir");
  mkdirRecurse(testRootPath);
  assert(
    dispatchCommand(
      roCtx, ["root", "add", "lock_root", testRootPath], testOpts
    ) == 0
  );

  Root lockRoot;
  assert(RootRepository(roCtx.db).findByName("lock_root", lockRoot));

  SyncLockRepository lockRepo = SyncLockRepository(roCtx.db);
  SyncLockInfo existing;

  assert(
    lockRepo.acquireLock(
      LockRequest(lockRoot.id, thisProcessID, getLocalHostName(), 1700000000),
      existing
    )
  );
  assert(
    dispatchCommand(
      roCtx, ["sync", "lock_root", "--no-backup"], testOpts
    ) == 1
  );
  assert(
    dispatchCommand(
      roCtx, ["sync", "lock_root", "--break-lock", "--no-backup"], testOpts
    ) == 0
  );

  version (Posix) {
    assert(
      lockRepo.acquireLock(
        LockRequest(lockRoot.id, 99_999_999, getLocalHostName(), 1700000000),
        existing
      )
    );
    assert(
      dispatchCommand(
        roCtx, ["sync", "lock_root", "--no-backup"], testOpts
      ) == 0
    );
  }

  roCtx.db.close();
}

unittest {
  import orglistremo.db.connection : openDatabase;
  import orglistremo.internal.testutil : TempDir;
  import std.file : mkdirRecurse;

  TempDir appTestDir = TempDir("app_pattern");
  const d1 = appTestDir.subPath("d1");
  const d2 = appTestDir.subPath("d2");
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
  assert(dispatchCommand(ctx, ["sync", "alpha%", "--no-progress"], opts) == 1);
  assert(
    dispatchCommand(
      ctx, ["sync", "--all", "alpha%", "--no-progress"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["sync", "beta", "--no-progress"], opts) == 0);
  assert(dispatchCommand(ctx, ["sync", "b%", "--no-progress"], opts) == 0);
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
  assert(dispatchCommand(ctx, ["list", "%"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", ":"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "alpha%"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "alpha_1:%"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "nonexistent%"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "nonexistent"], opts) == 1);

  // 4. Test list with --glob and --hash
  assert(dispatchCommand(ctx, ["list"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "--glob"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "--hash"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "alpha_1", "--hash"], opts) == 1);
  assert(
    dispatchCommand(ctx, ["list", "--hash", "0", "alpha_1"], opts) == 1
  );
  assert(dispatchCommand(ctx, ["list", "alpha%", "beta"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "alpha%", "nonexistent"], opts) == 1);
  assert(dispatchCommand(ctx, ["list", "--hash", "0"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "--hash", "e3b0%"], opts) == 0);
  assert(
    dispatchCommand(ctx, ["list", "alpha_1", "--hash", "0"], opts) == 0
  );
  assert(
    dispatchCommand(
      ctx, ["list", "alpha_1:/", "beta", "--hash", "0"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["list", "alpha*", "--glob"], opts) == 0);
  assert(
    dispatchCommand(
      ctx, ["list", "alpha_[12]", "beta", "--glob"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["list", "alpha_1:*", "--glob"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", ":*", "--glob"], opts) == 0);
  assert(dispatchCommand(ctx, ["list", "ALPHA*", "--glob"], opts) == 1);
  assert(
    dispatchCommand(
      ctx, ["list", "alpha*", "--glob", "--hash", "0"], opts
    ) == 0
  );
  assert(
    dispatchCommand(ctx, ["list", "--glob", "--hash", "0"], opts) == 0
  );
  assert(dispatchCommand(ctx, ["files", "--hash", "0"], opts) == 0);

  // 5. Test duplicates with pattern(s) and --glob
  assert(dispatchCommand(ctx, ["duplicates", "alpha%"], opts) == 0);
  assert(dispatchCommand(ctx, ["duplicates", "alpha%", "beta"], opts) == 0);
  assert(dispatchCommand(ctx, ["duplicates", "alpha*", "--glob"], opts) == 0);
  assert(
    dispatchCommand(
      ctx, ["duplicates", "alpha_[12]", "beta", "--glob"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["duplicates", "alpha_1:/"], opts) == 0);
  assert(dispatchCommand(ctx, ["duplicates", ":/", "--glob"], opts) == 0);
  assert(dispatchCommand(ctx, ["duplicates", "ALPHA*", "--glob"], opts) == 1);
  assert(dispatchCommand(ctx, ["duplicates", "nonexistent%"], opts) == 1);
  assert(dispatchCommand(ctx, ["duplicates", "nonexistent"], opts) == 1);
  assert(
    dispatchCommand(ctx, ["duplicates", "alpha%", "nonexistent"], opts) == 1
  );

  // 6. Test unique with pattern(s) and --glob
  assert(dispatchCommand(ctx, ["unique", "alpha%"], opts) == 0);
  assert(dispatchCommand(ctx, ["unique", "alpha%", "beta"], opts) == 0);
  assert(dispatchCommand(ctx, ["unique", "alpha*", "--glob"], opts) == 0);
  assert(
    dispatchCommand(
      ctx, ["unique", "alpha_[12]", "beta", "--glob"], opts
    ) == 0
  );
  assert(dispatchCommand(ctx, ["unique", "alpha_1:/"], opts) == 0);
  assert(dispatchCommand(ctx, ["unique", ":/", "--glob"], opts) == 0);
  assert(dispatchCommand(ctx, ["unique", "ALPHA*", "--glob"], opts) == 1);
  assert(dispatchCommand(ctx, ["unique", "nonexistent%"], opts) == 1);
  assert(dispatchCommand(ctx, ["unique", "nonexistent"], opts) == 1);
  assert(
    dispatchCommand(ctx, ["unique", "alpha%", "nonexistent"], opts) == 1
  );

  // 7. Test ignore and ignore-delete commands
  assert(dispatchCommand(ctx, ["ignore", "alpha%"], opts) == 0);
  assert(dispatchCommand(ctx, ["ignore-delete", "alpha%"], opts) == 0);
}
