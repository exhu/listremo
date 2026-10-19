module orglistremo.db.connection;

import d2sqlite3 : Database, SqliteType;
import orglistremo.app_version : appVersion;
import orglistremo.config : ensureDbDirectory;
import orglistremo.db.schema_version : schemaVersion;
import std.datetime.systime : Clock;

struct DbOpenResult {
  Database db;
  int dbSchemaVersion;
  bool isReadOnly;
}

Database openDatabase(string dbPath) {
  return openDatabaseChecked(dbPath).db;
}

DbOpenResult openDatabaseChecked(string dbPath) {
  assert(dbPath.length > 0, "dbPath cannot be empty");
  ensureDbDirectory(dbPath);

  auto db = Database(dbPath);
  db.execute("PRAGMA foreign_keys = ON;");

  if (!hasExistingTables(db)) {
    applyWritePragmas(db, dbPath);
    initSchema(db);
    return DbOpenResult(db, schemaVersion, false);
  }

  const dbVer = readDbSchemaVersion(db);
  if (dbVer != schemaVersion) {
    db.execute("PRAGMA query_only = ON;");
    return DbOpenResult(db, dbVer, true);
  }

  applyWritePragmas(db, dbPath);
  return DbOpenResult(db, dbVer, false);
}

int readDbSchemaVersion(ref Database db) {
  auto tableStmt = db.prepare(`
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name = 'version'
    LIMIT 1;
  `);
  if (tableStmt.execute().empty) {
    return 0;
  }

  auto verStmt = db.prepare(`
    SELECT schema_version FROM version
    ORDER BY id DESC
    LIMIT 1;
  `);
  auto results = verStmt.execute();
  if (results.empty) {
    return 0;
  }
  return results.front.peek!int(0);
}

void migrateDatabase(ref Database db, int fromVersion) {
  if (fromVersion < 0 || fromVersion >= schemaVersion) {
    import std.format : format;
    throw new Exception(
      format(
        "Unsupported schema migration from version %d to %d",
        fromVersion,
        schemaVersion
      )
    );
  }

  db.execute("PRAGMA query_only = OFF;");
  db.execute("BEGIN IMMEDIATE;");
  scope (failure) {
    db.execute("ROLLBACK;");
  }

  const now = Clock.currTime.toUnixTime();
  const creationDate = resolveDbCreationDate(db, now);

  // Migration 0 -> 1: ensure core tables and version table exist
  createCoreTables(db);
  insertCurrentVersionRow(db, creationDate, now);

  db.execute("COMMIT;");
}

private:

void applyWritePragmas(ref Database db, string dbPath) {
  if (dbPath != ":memory:") {
    db.execute("PRAGMA journal_mode = WAL;");
    db.execute("PRAGMA synchronous = NORMAL;");
  }
}

bool hasExistingTables(ref Database db) {
  auto stmt = db.prepare(`
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
    LIMIT 1;
  `);
  return !stmt.execute().empty;
}

void initSchema(ref Database db) {
  createCoreTables(db);
  if (readDbSchemaVersion(db) == 0) {
    const now = Clock.currTime.toUnixTime();
    insertCurrentVersionRow(db, now, now);
  }
}

void createCoreTables(ref Database db) {
  db.execute(`
    CREATE TABLE IF NOT EXISTS version (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      schema_version    INTEGER NOT NULL,
      app_version       TEXT NOT NULL,
      creation_date     INTEGER NOT NULL,
      modification_date INTEGER NOT NULL
    );
  `);

  db.execute(`
    CREATE TABLE IF NOT EXISTS roots (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      path        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      last_sync   INTEGER
    );
  `);

  db.execute(`
    CREATE TABLE IF NOT EXISTS entries (
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

  createCoreIndexes(db);
}

void createCoreIndexes(ref Database db) {
  db.execute(`
    CREATE INDEX IF NOT EXISTS idx_entries_root_id
    ON entries(root_id);
  `);
  db.execute(`
    CREATE INDEX IF NOT EXISTS idx_entries_sha256
    ON entries(sha256);
  `);
  db.execute(`
    CREATE INDEX IF NOT EXISTS idx_entries_root_sha256
    ON entries(root_id, sha256);
  `);
  db.execute(`
    CREATE INDEX IF NOT EXISTS idx_entries_is_dir_sha256
    ON entries(is_dir, sha256);
  `);
}

long resolveDbCreationDate(ref Database db, long fallbackNow) {
  if (readDbSchemaVersion(db) > 0) {
    auto verStmt = db.prepare(`
      SELECT creation_date FROM version
      ORDER BY id ASC
      LIMIT 1;
    `);
    auto verRes = verStmt.execute();
    if (!verRes.empty) {
      return verRes.front.peek!long(0);
    }
  }

  auto rootTableStmt = db.prepare(`
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name = 'roots'
    LIMIT 1;
  `);
  if (!rootTableStmt.execute().empty) {
    auto minStmt = db.prepare("SELECT MIN(created_at) FROM roots;");
    auto minRes = minStmt.execute();
    if (!minRes.empty && minRes.front[0].type != SqliteType.NULL) {
      return minRes.front[0].as!long;
    }
  }

  return fallbackNow;
}

void insertCurrentVersionRow(
  ref Database db,
  long creationDate,
  long modificationDate
) {
  auto stmt = db.prepare(`
    INSERT INTO version (
      schema_version, app_version, creation_date, modification_date
    ) VALUES (?, ?, ?, ?);
  `);
  stmt.bind(1, schemaVersion);
  stmt.bind(2, appVersion);
  stmt.bind(3, creationDate);
  stmt.bind(4, modificationDate);
  stmt.execute();
}

unittest {
  DbOpenResult openRes = openDatabaseChecked(":memory:");
  assert(!openRes.isReadOnly);
  assert(openRes.dbSchemaVersion == schemaVersion);

  Database db = openRes.db;
  assert(readDbSchemaVersion(db) == schemaVersion);

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

  // Verify entry exists
  long rowCount = db.execute("SELECT COUNT(*) FROM entries").oneValue!long;
  assert(rowCount == 1);

  // Verify cascade deletion
  db.execute("DELETE FROM roots WHERE id = ?", rootId);
  rowCount = db.execute("SELECT COUNT(*) FROM entries").oneValue!long;
  assert(rowCount == 0);
}

unittest {
  import std.file : exists, remove, tempDir;
  import std.path : buildPath;

  const tmpDbPath = buildPath(tempDir(), "listremo_v0_migration_test.db");
  if (exists(tmpDbPath)) {
    remove(tmpDbPath);
  }
  scope (exit) {
    if (exists(tmpDbPath)) {
      remove(tmpDbPath);
    }
  }

  // Create a legacy v0 database (roots and entries without version table)
  {
    auto rawDb = Database(tmpDbPath);
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
      INSERT INTO roots (name, path, created_at)
      VALUES ('legacy_root', '/mnt/legacy', 1600000000);
    `);
    rawDb.close();
  }

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

