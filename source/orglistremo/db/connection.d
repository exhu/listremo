module orglistremo.db.connection;

import d2sqlite3 : Database;
import orglistremo.config : ensureDbDirectory;

Database openDatabase(string dbPath) {
  assert(dbPath.length > 0, "dbPath cannot be empty");
  ensureDbDirectory(dbPath);

  auto db = Database(dbPath);

  // Apply SQLite configuration pragmas
  db.execute("PRAGMA foreign_keys = ON;");
  if (dbPath != ":memory:") {
    db.execute("PRAGMA journal_mode = WAL;");
    db.execute("PRAGMA synchronous = NORMAL;");
  }

  // Initialize schema
  initSchema(db);

  return db;
}

private:

void initSchema(ref Database db) {
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

unittest {
  Database db = openDatabase(":memory:");

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
