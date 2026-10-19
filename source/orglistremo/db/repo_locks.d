module orglistremo.db.repo_locks;

import d2sqlite3 : Database, Row;
import std.process : thisProcessID;

version (Posix) {
  import core.stdc.errno : errno, ESRCH;
  import core.sys.posix.signal : kill;

  bool isPidAlive(int pid) {
    if (pid <= 0) {
      return false;
    }
    const res = kill(pid, 0);
    if (res == 0) {
      return true;
    }
    return errno != ESRCH;
  }
} else {
  bool isPidAlive(int pid) {
    return pid > 0;
  }
}

struct SyncLockInfo {
  long rootId;
  int pid;
  long startedAt;
  string hostname;
}

struct SyncLockRepository {
  this(Database db) {
    this.db = db;
  }

  bool acquireLock(
    long rootId,
    int pid,
    string hostname,
    long startedAt,
    out SyncLockInfo existing
  ) {
    db.execute("BEGIN IMMEDIATE;");
    scope (failure) {
      db.execute("ROLLBACK;");
    }

    auto checkStmt = db.prepare(`
      SELECT pid, started_at, hostname
      FROM sync_locks
      WHERE root_id = ?;
    `);
    checkStmt.bind(1, rootId);
    auto results = checkStmt.execute();
    if (!results.empty) {
      auto row = results.front;
      existing = SyncLockInfo(
        rootId,
        row.peek!int(0),
        row.peek!long(1),
        row.peek!string(2)
      );
      db.execute("ROLLBACK;");
      return false;
    }

    auto insertStmt = db.prepare(`
      INSERT INTO sync_locks (root_id, pid, started_at, hostname)
      VALUES (?, ?, ?, ?);
    `);
    insertStmt.bind(1, rootId);
    insertStmt.bind(2, pid);
    insertStmt.bind(3, startedAt);
    insertStmt.bind(4, hostname);
    insertStmt.execute();

    db.execute("COMMIT;");
    return true;
  }

  bool releaseLock(long rootId) {
    db.execute("BEGIN IMMEDIATE;");
    scope (failure) {
      db.execute("ROLLBACK;");
    }

    auto stmt = db.prepare("DELETE FROM sync_locks WHERE root_id = ?;");
    stmt.bind(1, rootId);
    stmt.execute();
    const changed = db.changes > 0;

    db.execute("COMMIT;");
    return changed;
  }

  bool breakLock(long rootId) {
    return releaseLock(rootId);
  }

  bool getLock(long rootId, out SyncLockInfo info) {
    auto stmt = db.prepare(`
      SELECT pid, started_at, hostname
      FROM sync_locks
      WHERE root_id = ?;
    `);
    stmt.bind(1, rootId);
    auto results = stmt.execute();
    if (results.empty) {
      return false;
    }
    auto row = results.front;
    info = SyncLockInfo(
      rootId,
      row.peek!int(0),
      row.peek!long(1),
      row.peek!string(2)
    );
    return true;
  }

private:
  Database db;
}

unittest {
  import orglistremo.db.repo_migration :
    createCoreTablesV1, createSyncLocksTable;

  auto db = Database(":memory:");
  db.execute("PRAGMA foreign_keys = ON;");
  createCoreTablesV1(db);
  createSyncLocksTable(db);

  db.execute(`
    INSERT INTO roots (name, path, created_at)
    VALUES ('test_root', '/mnt/test', 1700000000);
  `);
  const rootId = db.lastInsertRowid;

  SyncLockRepository repo = SyncLockRepository(db);
  SyncLockInfo existing;

  // Initial acquire succeeds
  const myPid = thisProcessID;
  assert(isPidAlive(myPid));
  assert(repo.acquireLock(rootId, myPid, "myhost", 1700000010, existing));

  // Second acquire fails and reports existing info
  SyncLockInfo conflict;
  assert(!repo.acquireLock(rootId, 99999, "otherhost", 1700000020, conflict));
  assert(conflict.rootId == rootId);
  assert(conflict.pid == myPid);
  assert(conflict.hostname == "myhost");
  assert(conflict.startedAt == 1700000010);

  // Get lock
  SyncLockInfo queried;
  assert(repo.getLock(rootId, queried));
  assert(queried.pid == myPid);

  // Release lock
  assert(repo.releaseLock(rootId));
  assert(!repo.getLock(rootId, queried));

  // Re-acquire works
  assert(repo.acquireLock(rootId, myPid, "myhost", 1700000030, existing));

  // Cascade delete on root removal
  db.execute("DELETE FROM roots WHERE id = ?;", rootId);
  assert(!repo.getLock(rootId, queried));

  // Dead PID check (PID 99999999 is extraordinarily unlikely to exist)
  version (Posix) {
    assert(!isPidAlive(99_999_999));
    assert(!isPidAlive(-1));
  }
}
