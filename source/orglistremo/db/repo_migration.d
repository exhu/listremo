module orglistremo.db.repo_migration;

import d2sqlite3 : Database, SqliteType;
import orglistremo.app_version : appVersion;
import orglistremo.db.schema_version : schemaVersion;
import std.datetime.systime : Clock;

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

  for (int v = fromVersion; v < schemaVersion; v++) {
    switch (v) {
      case 0:
        migrateFrom0to1(db, creationDate, now);
        break;
      case 1:
        migrateFrom1to2(db, now);
        break;
      default:
        import std.format : format;
        throw new Exception(
          format("Unhandled migration step from version %d", v)
        );
    }
  }

  db.execute("COMMIT;");
}

void migrateFrom0to1(ref Database db, long creationDate, long now) {
  createCoreTablesV1(db);
  insertVersionRow(db, 1, creationDate, now);
}

void migrateFrom1to2(ref Database db, long now) {
  createSyncLocksTable(db);
  const creationDate = resolveDbCreationDate(db, now);
  insertVersionRow(db, 2, creationDate, now);
}

void createSyncLocksTable(ref Database db) {
  db.execute(`
    CREATE TABLE IF NOT EXISTS sync_locks (
      root_id     INTEGER PRIMARY KEY REFERENCES roots(id) ON DELETE CASCADE,
      pid         INTEGER NOT NULL,
      started_at  INTEGER NOT NULL,
      hostname    TEXT NOT NULL
    );
  `);
}

void createCoreTablesV1(ref Database db) {
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
  auto verTableStmt = db.prepare(`
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name = 'version'
    LIMIT 1;
  `);
  if (!verTableStmt.execute().empty) {
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

void insertVersionRow(
  ref Database db,
  int targetVersion,
  long creationDate,
  long modificationDate
) {
  auto stmt = db.prepare(`
    INSERT INTO version (
      schema_version, app_version, creation_date, modification_date
    ) VALUES (?, ?, ?, ?);
  `);
  stmt.bind(1, targetVersion);
  stmt.bind(2, appVersion);
  stmt.bind(3, creationDate);
  stmt.bind(4, modificationDate);
  stmt.execute();
}

unittest {
  auto db = Database(":memory:");
  // Start with v0 schema (only roots table)
  db.execute(`
    CREATE TABLE roots (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      path        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      last_sync   INTEGER
    );
  `);
  db.execute(`
    INSERT INTO roots (name, path, created_at)
    VALUES ('r1', '/path/1', 1700000000);
  `);

  // Migrate from 0 to 2
  migrateDatabase(db, 0);

  const ver = db.execute(
    "SELECT schema_version FROM version ORDER BY id DESC LIMIT 1"
  ).oneValue!int;
  assert(ver == schemaVersion);

  const creationDate = db.execute(
    "SELECT creation_date FROM version ORDER BY id ASC LIMIT 1"
  ).oneValue!long;
  assert(creationDate == 1700000000);

  // Check sync_locks table exists
  db.execute(`
    INSERT INTO sync_locks (root_id, pid, started_at, hostname)
    VALUES (1, 1234, 1700000001, 'localhost');
  `);
  const lockCount = db.execute(
    "SELECT COUNT(*) FROM sync_locks WHERE root_id = 1;"
  ).oneValue!long;
  assert(lockCount == 1);
}

unittest {
  auto db = Database(":memory:");
  // Create v1 database
  createCoreTablesV1(db);
  insertVersionRow(db, 1, 1600000000, 1600000000);

  // Migrate from 1 to 2
  migrateDatabase(db, 1);

  const ver = db.execute(
    "SELECT schema_version FROM version ORDER BY id DESC LIMIT 1"
  ).oneValue!int;
  assert(ver == 2);

  const versionCount = db.execute(
    "SELECT COUNT(*) FROM version"
  ).oneValue!long;
  assert(versionCount == 2);
}
