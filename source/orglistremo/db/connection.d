module orglistremo.db.connection;

import d2sqlite3 : Database, ResultRange, Statement;
import orglistremo.app_version : appVersion;
import orglistremo.config : ensureDbDirectory;
import orglistremo.db.internal.schema : tableExists;
import orglistremo.db.migration :
  addFreeSpaceColumn, applyWritePragmas, createCoreTablesV1,
  createRootIgnoresTable, createSyncLocksTable, insertVersionRow, VersionRow;
import orglistremo.db.schema_version : schemaVersion;
import std.datetime.systime : Clock;

package(orglistremo):

struct DbOpenResult {
  Database db;
  int dbSchemaVersion;
  bool isReadOnly;
}

Database openDatabase(string dbPath, uint busyTimeoutMs = 60_000) {
  return openDatabaseChecked(dbPath, busyTimeoutMs).db;
}

Database openWorkerDatabase(string dbPath, uint busyTimeoutMs = 60_000) {
  import std.format : format;

  assert(dbPath.length > 0, "dbPath cannot be empty");
  Database db = Database(dbPath);
  db.execute("PRAGMA foreign_keys = ON;");
  db.execute(format("PRAGMA busy_timeout = %d;", busyTimeoutMs));
  return db;
}

DbOpenResult openDatabaseChecked(
  string dbPath,
  uint busyTimeoutMs = 60_000
) {
  assert(dbPath.length > 0, "dbPath cannot be empty");
  ensureDbDirectory(dbPath);

  Database db = Database(dbPath);
  db.execute("PRAGMA foreign_keys = ON;");
  import std.format : format;
  db.execute(format("PRAGMA busy_timeout = %d;", busyTimeoutMs));

  if (!hasExistingTables(db)) {
    applyWritePragmas(db);
    initSchema(db);
    return DbOpenResult(db, schemaVersion, false);
  }

  const dbVer = readDbSchemaVersion(db);
  if (dbVer != schemaVersion) {
    db.execute("PRAGMA query_only = ON;");
    return DbOpenResult(db, dbVer, true);
  }

  applyWritePragmas(db);
  return DbOpenResult(db, dbVer, false);
}

int readDbSchemaVersion(ref Database db) {
  if (!tableExists(db, "version")) {
    return 0;
  }

  Statement verStmt = db.prepare(`
    SELECT schema_version FROM version
    ORDER BY id DESC
    LIMIT 1;
  `);
  ResultRange results = verStmt.execute();
  if (results.empty) {
    return 0;
  }
  return results.front.peek!int(0);
}

private:

bool hasExistingTables(ref Database db) {
  Statement stmt = db.prepare(`
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    LIMIT 1;
  `);
  ResultRange results = stmt.execute();
  return !results.empty;
}

void initSchema(ref Database db) {
  createCoreTables(db);
  if (readDbSchemaVersion(db) == 0) {
    const now = Clock.currTime.toUnixTime();
    insertCurrentVersionRow(db, now, now);
  }
}

void createCoreTables(ref Database db) {
  createCoreTablesV1(db);
  createSyncLocksTable(db);
  addFreeSpaceColumn(db);
  createRootIgnoresTable(db);
}

void insertCurrentVersionRow(
  ref Database db,
  long creationDate,
  long modificationDate
) {
  insertVersionRow(
    db, VersionRow(schemaVersion, creationDate, modificationDate)
  );
}

unittest {
  DbOpenResult openRes = openDatabaseChecked(":memory:");
  assert(!openRes.isReadOnly);
  assert(openRes.dbSchemaVersion == schemaVersion);
  assert(schemaVersion == 4);

  Database db = openRes.db;
  assert(readDbSchemaVersion(db) == schemaVersion);

  const timeoutVal = db.execute("PRAGMA busy_timeout;").oneValue!int;
  assert(timeoutVal == 60_000);

  const verCount = db.execute("SELECT COUNT(*) FROM version").oneValue!long;
  assert(verCount == 1);
  const storedAppVer = db.execute(
    "SELECT app_version FROM version ORDER BY id DESC LIMIT 1"
  ).oneValue!string;
  assert(storedAppVer == appVersion);

  // Verify foreign key enforcement
  db.execute(`
    INSERT INTO roots (name, path, created_at)
    VALUES ('test_root', '/mnt/test', 1700000000);
  `);
  const rootId = db.lastInsertRowid;

  db.execute(`
    INSERT INTO entries (
      root_id, rel_path, parent_path, name, is_dir, size, mtime, sha256
    ) VALUES (
      ?, 'file.txt', '.', 'file.txt', 0, 100, 1700000000, 'abc123'
    );
  `, rootId);

  // Verify sync_locks and root_ignores tables exist
  db.execute(`
    INSERT INTO sync_locks (root_id, pid, started_at, hostname)
    VALUES (?, 1234, 1700000000, 'myhost');
  `, rootId);
  db.execute(`
    INSERT INTO root_ignores (root_id, pattern)
    VALUES (?, '*~');
  `, rootId);

  // Verify entry, lock, and ignore pattern exist
  assert(db.execute("SELECT COUNT(*) FROM entries").oneValue!long == 1);
  assert(db.execute("SELECT COUNT(*) FROM sync_locks").oneValue!long == 1);
  assert(db.execute("SELECT COUNT(*) FROM root_ignores").oneValue!long == 1);

  // Verify cascade deletion
  db.execute("DELETE FROM roots WHERE id = ?", rootId);
  assert(db.execute("SELECT COUNT(*) FROM entries").oneValue!long == 0);
  assert(db.execute("SELECT COUNT(*) FROM sync_locks").oneValue!long == 0);
  assert(db.execute("SELECT COUNT(*) FROM root_ignores").oneValue!long == 0);
}

unittest {
  import orglistremo.db.migration : migrateDatabase;
  import orglistremo.internal.testutil : createLegacyV0Db, TempDir;

  TempDir tempDir = TempDir("conn_v0");
  const tmpDbPath = tempDir.subPath("v0.db");
  createLegacyV0Db(tmpDbPath);

  // Opening legacy v0 database sets read-only mode and reports version 0
  DbOpenResult v0Res = openDatabaseChecked(tmpDbPath);
  assert(v0Res.isReadOnly);
  assert(v0Res.dbSchemaVersion == 0);

  // Verify SQLite query_only prevents writes while in read-only mode
  bool writeFailed = false;
  try {
    v0Res.db.execute(`
      INSERT INTO roots (name, path, created_at)
      VALUES ('blocked', '/mnt/blocked', 1600000001);
    `);
  } catch (Exception) {
    writeFailed = true;
  }
  assert(writeFailed);

  // Migrate database from 0 to current schemaVersion
  migrateDatabase(v0Res.db, v0Res.dbSchemaVersion);
  assert(readDbSchemaVersion(v0Res.db) == schemaVersion);

  const createdDate = v0Res.db.execute(
    "SELECT creation_date FROM version ORDER BY id DESC LIMIT 1"
  ).oneValue!long;
  assert(createdDate == 1600000000);
  v0Res.db.close();

  // Re-opening after migration succeeds in read-write mode
  DbOpenResult v1Res = openDatabaseChecked(tmpDbPath);
  assert(!v1Res.isReadOnly);
  assert(v1Res.dbSchemaVersion == schemaVersion);
  const rootCount = v1Res.db.execute(
    "SELECT COUNT(*) FROM roots WHERE name = 'legacy_root'"
  ).oneValue!long;
  assert(rootCount == 1);
  v1Res.db.close();
}

unittest {
  Database workerDb = openWorkerDatabase(":memory:", 5000);
  assert(workerDb.execute("PRAGMA foreign_keys;").oneValue!int == 1);
  assert(workerDb.execute("PRAGMA busy_timeout;").oneValue!int == 5000);
}
