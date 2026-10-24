module orglistremo.cli.context;

import d2sqlite3 : Database;
import orglistremo.db.backup : proposeBackupPath, writeDatabaseBackup;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.output.options : info, OutputOptions;
import std.stdio : stderr, stdout, writefln;

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

bool requireWritable(in DbContext ctx) {
  if (ctx.isReadOnly) {
    printReadOnlyError(ctx.dbSchemaVersion);
    return false;
  }
  return true;
}

bool promptBackupPath(
  string dbPath,
  out string chosenPath,
  string actionName = "Migration"
) {
  import std.file : exists;
  import std.stdio : readln, writef;
  import std.string : strip;

  while (true) {
    const proposed = proposeBackupPath(dbPath);
    writef(
      "Backup file path [%s] (Enter to accept, Ctrl-C to abort): ",
      proposed
    );
    stdout.flush();

    const line = readln();
    if (line is null) {
      stderr.writefln("\n%s aborted.", actionName);
      return false;
    }

    const trimmed = line.strip();
    const candidate = trimmed.length > 0 ? trimmed : proposed;
    if (exists(candidate)) {
      stderr.writefln(
        "File '%s' already exists and will not be overwritten.",
        candidate
      );
      continue;
    }

    chosenPath = candidate;
    return true;
  }
}

struct BackupRequest {
  string dbPath;
  bool noBackup;
  OutputOptions opts;
  string actionName = "Migration";
}

bool backupIfRequested(
  ref Database db,
  in BackupRequest req
) {
  if (req.noBackup || req.dbPath == ":memory:") {
    return true;
  }

  string backupPath;
  if (!promptBackupPath(req.dbPath, backupPath, req.actionName)) {
    return false;
  }

  try {
    writeDatabaseBackup(db, backupPath);
    import std.format : format;
    info(req.opts, format("Saved database backup to '%s'.", backupPath));
    return true;
  } catch (Exception e) {
    stderr.writefln(
      "Error: Failed to write backup file '%s': %s",
      backupPath,
      e.msg
    );
    return false;
  }
}

bool backupIfRequested(
  ref DbContext ctx,
  in BackupRequest req
) {
  return backupIfRequested(ctx.db, req);
}

bool backupIfRequested(
  ref DbContext ctx,
  bool noBackup,
  in OutputOptions opts
) {
  return backupIfRequested(
    ctx.db, BackupRequest(ctx.dbPath, noBackup, opts, "Migration")
  );
}

unittest {
  DbContext rwCtx = DbContext(Database.init, ":memory:", schemaVersion, false);
  assert(requireWritable(rwCtx));

  OutputOptions opts;
  assert(backupIfRequested(rwCtx, true, opts));
  assert(backupIfRequested(rwCtx, false, opts));
}
