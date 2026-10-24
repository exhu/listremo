module orglistremo.db.migration;

import d2sqlite3 : Database, ResultRange, SqliteType, Statement;
import orglistremo.app_version : appVersion;
import orglistremo.db.internal.schema : tableExists;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.db.transaction : withTransaction;
import std.datetime.systime : Clock;

package(orglistremo):

struct VersionRow {
  int targetVersion;
  long creationDate;
  long modificationDate;
}

void applyWritePragmas(ref Database db) {
  db.execute("PRAGMA journal_mode = WAL;");
  db.execute("PRAGMA synchronous = NORMAL;");
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

  const bool wasQueryOnly =
    db.execute("PRAGMA query_only;").oneValue!int != 0;
  if (wasQueryOnly) {
    db.execute("PRAGMA query_only = OFF;");
  }
  scope (failure) {
    if (wasQueryOnly) {
      db.execute("PRAGMA query_only = ON;");
    }
  }

  withTransaction(db, {
    runMigrationSteps(db, fromVersion);
  });
  applyWritePragmas(db);
}

void migrateFrom0to1(ref Database db, long creationDate, long now) {
  createCoreTablesV1(db);
  insertVersionRow(db, VersionRow(1, creationDate, now));
}

void migrateFrom1to2(ref Database db, long now) {
  createSyncLocksTable(db);
  const creationDate = resolveDbCreationDate(db, now);
  insertVersionRow(db, VersionRow(2, creationDate, now));
}

void migrateFrom2to3(ref Database db, long now) {
  addFreeSpaceColumn(db);
  const creationDate = resolveDbCreationDate(db, now);
  insertVersionRow(db, VersionRow(3, creationDate, now));
}

void addFreeSpaceColumn(ref Database db) {
  db.execute("ALTER TABLE roots ADD COLUMN free_space INTEGER;");
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

  createEntryIndexes(db);
}

long resolveDbCreationDate(ref Database db, long fallbackNow) {
  if (tableExists(db, "version")) {
    Statement verStmt = db.prepare(`
      SELECT creation_date FROM version
      ORDER BY id ASC
      LIMIT 1;
    `);
    ResultRange verRes = verStmt.execute();
    if (!verRes.empty) {
      return verRes.front.peek!long(0);
    }
  }

  if (tableExists(db, "roots")) {
    Statement minStmt = db.prepare("SELECT MIN(created_at) FROM roots;");
    ResultRange minRes = minStmt.execute();
    if (!minRes.empty && minRes.front[0].type != SqliteType.NULL) {
      return minRes.front[0].as!long;
    }
  }

  return fallbackNow;
}

void insertVersionRow(ref Database db, in VersionRow row) {
  Statement stmt = db.prepare(`
    INSERT INTO version (
      schema_version, app_version, creation_date, modification_date
    ) VALUES (?, ?, ?, ?);
  `);
  stmt.bind(1, row.targetVersion);
  stmt.bind(2, appVersion);
  stmt.bind(3, row.creationDate);
  stmt.bind(4, row.modificationDate);
  stmt.execute();
}

private:

void runMigrationSteps(ref Database db, int fromVersion) {
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
      case 2:
        migrateFrom2to3(db, now);
        break;
      default:
        import std.format : format;
        throw new Exception(
          format("Unhandled migration step from version %d", v)
        );
    }
  }
}

void createEntryIndexes(ref Database db) {
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

unittest {
  import orglistremo.internal.testutil : createLegacyV0Db, LegacyV0Options;

  Database db = Database(":memory:");
  createLegacyV0Db(db, LegacyV0Options("r1", "/path/1", 1700000000));

  // Migrate from 0 to 3
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
  Database db = Database(":memory:");
  // Create v1 database
  createCoreTablesV1(db);
  insertVersionRow(db, VersionRow(1, 1600000000, 1600000000));

  // Migrate from 1 to 3
  migrateDatabase(db, 1);

  const ver = db.execute(
    "SELECT schema_version FROM version ORDER BY id DESC LIMIT 1"
  ).oneValue!int;
  assert(ver == schemaVersion);

  const versionCount = db.execute(
    "SELECT COUNT(*) FROM version"
  ).oneValue!long;
  assert(versionCount == 3);
}

unittest {
  Database db = Database(":memory:");
  // Create v2 database
  createCoreTablesV1(db);
  createSyncLocksTable(db);
  insertVersionRow(db, VersionRow(2, 1600000000, 1600000000));

  db.execute(`
    INSERT INTO roots (name, path, created_at)
    VALUES ('r_v2', '/mnt/v2', 1600000000);
  `);

  // Migrate from 2 to 3
  migrateDatabase(db, 2);

  const ver = db.execute(
    "SELECT schema_version FROM version ORDER BY id DESC LIMIT 1"
  ).oneValue!int;
  assert(ver == 3);

  // Verify free_space column is present and usable
  db.execute("UPDATE roots SET free_space = 5000000000 WHERE name = 'r_v2';");
  const freeVal = db.execute(
    "SELECT free_space FROM roots WHERE name = 'r_v2';"
  ).oneValue!long;
  assert(freeVal == 5000000000);
}

unittest {
  Database db = Database(":memory:");
  applyWritePragmas(db);
  assert(db.execute("PRAGMA synchronous;").oneValue!int == 1);

  db.execute("PRAGMA query_only = ON;");
  import std.exception : assertThrown;
  assertThrown!Exception(migrateDatabase(db, -1));
  assert(db.execute("PRAGMA query_only;").oneValue!int != 0);
}
