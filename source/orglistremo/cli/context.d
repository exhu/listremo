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
  Database* db;
  string dbPath;
  bool noBackup;
  OutputOptions opts;
  string actionName = "Migration";
}

struct BackupRequestBuilder {
  this(ref DbContext ctx) {
    this.db = &ctx.db;
    this.dbPath = ctx.dbPath;
  }

  ref BackupRequestBuilder withNoBackup(bool val) return {
    this.noBackup = val;
    return this;
  }

  ref BackupRequestBuilder withOptions(in OutputOptions val) return {
    this.opts = val;
    return this;
  }

  ref BackupRequestBuilder withActionName(string val) return {
    this.actionName = val;
    return this;
  }

  BackupRequest build() {
    return BackupRequest(
      db, dbPath, noBackup, opts, actionName
    );
  }

private:
  Database* db;
  string dbPath;
  bool noBackup;
  OutputOptions opts;
  string actionName = "Migration";
}

bool backupIfRequested(in BackupRequest req) {
  if (req.noBackup || req.dbPath == ":memory:") {
    return true;
  }
  assert(req.db !is null, "Database pointer must not be null");

  string backupPath;
  if (!promptBackupPath(req.dbPath, backupPath, req.actionName)) {
    return false;
  }

  try {
    writeDatabaseBackup(*cast(Database*) req.db, backupPath);
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

unittest {
  DbContext rwCtx = DbContext(Database.init, ":memory:", schemaVersion, false);
  assert(requireWritable(rwCtx));

  OutputOptions opts;
  const BackupRequest req1 = BackupRequestBuilder(rwCtx)
    .withNoBackup(true)
    .withOptions(opts)
    .build();
  assert(backupIfRequested(req1));

  const BackupRequest req2 = BackupRequestBuilder(rwCtx)
    .withNoBackup(false)
    .withOptions(opts)
    .build();
  assert(backupIfRequested(req2));
}
