module orglistremo.db.backup;

import d2sqlite3 : Database;
import orglistremo.config : ensureDbDirectory;
import std.stdio : stderr, stdout, writefln;

string proposeBackupPath(string dbPath) {
  import std.algorithm.searching : endsWith;
  import std.file : exists;
  import std.format : format;

  const prefix = dbPath.endsWith(".db")
    ? dbPath[0 .. $ - 3]
    : dbPath;
  ulong idx = 1;
  while (true) {
    const candidate = format("%s-backup-%d.db", prefix, idx);
    if (!exists(candidate)) {
      return candidate;
    }
    idx++;
  }
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

void writeDatabaseBackup(ref Database db, string backupPath) {
  import orglistremo.config : ensureDbDirectory;
  import std.file : exists, remove;

  ensureDbDirectory(backupPath);
  if (exists(backupPath)) {
    remove(backupPath);
  }

  const bool isQueryOnly =
    db.execute("PRAGMA query_only;").oneValue!int != 0;
  if (isQueryOnly) {
    db.execute("PRAGMA query_only = OFF;");
  }
  scope (exit) {
    if (isQueryOnly) {
      db.execute("PRAGMA query_only = ON;");
    }
  }

  db.execute("VACUUM INTO ?;", backupPath);
}

unittest {
  import orglistremo.internal.testutil : TempDir;
  import std.file : exists;

  TempDir tempDir = TempDir("backup");
  const testDb = tempDir.subPath("src.db");
  const testBkp = tempDir.subPath("dst.db");

  auto db = Database(testDb);
  db.execute("PRAGMA journal_mode = WAL;");
  db.execute("CREATE TABLE t (x INTEGER);");
  db.execute("INSERT INTO t VALUES (42);");

  // Backup active WAL database
  writeDatabaseBackup(db, testBkp);
  assert(exists(testBkp));

  // Overwrite existing backup
  writeDatabaseBackup(db, testBkp);
  assert(exists(testBkp));

  // Verify backup contains data
  auto bkpDb = Database(testBkp);
  assert(bkpDb.execute("SELECT x FROM t").oneValue!int == 42);
  bkpDb.close();

  // Test query_only connection backup and restoration
  db.execute("PRAGMA query_only = ON;");
  writeDatabaseBackup(db, testBkp);
  assert(db.execute("PRAGMA query_only;").oneValue!int != 0);
  db.close();
}
