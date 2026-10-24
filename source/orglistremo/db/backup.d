module orglistremo.db.backup;

import d2sqlite3 : Database;
import orglistremo.config : ensureDbDirectory;

package(orglistremo):

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

void writeDatabaseBackup(ref Database db, string backupPath) {
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

  Database db = Database(testDb);
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
  Database bkpDb = Database(testBkp);
  assert(bkpDb.execute("SELECT x FROM t").oneValue!int == 42);
  bkpDb.close();

  // Test query_only connection backup and restoration
  db.execute("PRAGMA query_only = ON;");
  writeDatabaseBackup(db, testBkp);
  assert(db.execute("PRAGMA query_only;").oneValue!int != 0);
  db.close();
}
