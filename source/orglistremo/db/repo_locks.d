module orglistremo.db.repo_locks;

import d2sqlite3 : Database, ResultRange, Row, Statement;
import orglistremo.db.transaction : withTransaction;
import orglistremo.internal.os : isPidAlive;
import std.process : thisProcessID;

package(orglistremo):

struct SyncLockInfo {
  long rootId;
  int pid;
  long startedAt;
  string hostname;
}

struct LockRequest {
  long rootId;
  int pid;
  string hostname;
  long startedAt;
}

struct SyncLockRepository {
  this(Database db) {
    this.db = db;
  }

  bool acquireLock(in LockRequest req, out SyncLockInfo existing) {
    bool acquired = false;
    SyncLockInfo found;
    withTransaction(db, {
      if (getLock(req.rootId, found)) {
        return;
      }
      Statement insertStmt = db.prepare(`
        INSERT INTO sync_locks (root_id, pid, started_at, hostname)
        VALUES (?, ?, ?, ?);
      `);
      insertStmt.bind(1, req.rootId);
      insertStmt.bind(2, req.pid);
      insertStmt.bind(3, req.startedAt);
      insertStmt.bind(4, req.hostname);
      insertStmt.execute();
      acquired = true;
    });
    if (!acquired) {
      existing = found;
    }
    return acquired;
  }

  bool releaseLock(long rootId, int pid, string hostname) {
    bool changed = false;
    withTransaction(db, {
      Statement stmt = db.prepare(`
        DELETE FROM sync_locks
        WHERE root_id = ? AND pid = ? AND hostname = ?;
      `);
      stmt.bind(1, rootId);
      stmt.bind(2, pid);
      stmt.bind(3, hostname);
      stmt.execute();
      changed = db.changes > 0;
    });
    return changed;
  }

  bool breakLock(long rootId) {
    bool changed = false;
    withTransaction(db, {
      Statement stmt = db.prepare(
        "DELETE FROM sync_locks WHERE root_id = ?;"
      );
      stmt.bind(1, rootId);
      stmt.execute();
      changed = db.changes > 0;
    });
    return changed;
  }

  bool getLock(long rootId, out SyncLockInfo info) {
    Statement stmt = db.prepare(`
      SELECT pid, started_at, hostname
      FROM sync_locks
      WHERE root_id = ?;
    `);
    stmt.bind(1, rootId);
    ResultRange results = stmt.execute();
    if (results.empty) {
      return false;
    }
    Row row = results.front;
    info = readLockRow(rootId, row);
    return true;
  }

private:
  static SyncLockInfo readLockRow(long rootId, Row row) {
    return SyncLockInfo(
      rootId,
      row.peek!int(0),
      row.peek!long(1),
      row.peek!string(2)
    );
  }

  Database db;
}

unittest {
  import orglistremo.db.migration :
    createCoreTablesV1, createSyncLocksTable;

  Database db = Database(":memory:");
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
  assert(
    repo.acquireLock(
      LockRequest(rootId, myPid, "myhost", 1700000010), existing
    )
  );

  // Second acquire fails and reports existing info
  SyncLockInfo conflict;
  assert(
    !repo.acquireLock(
      LockRequest(rootId, 99999, "otherhost", 1700000020), conflict
    )
  );
  assert(conflict.rootId == rootId);
  assert(conflict.pid == myPid);
  assert(conflict.hostname == "myhost");
  assert(conflict.startedAt == 1700000010);

  // Get lock
  SyncLockInfo queried;
  assert(repo.getLock(rootId, queried));
  assert(queried.pid == myPid);

  // Release lock with mismatched PID or hostname fails
  assert(!repo.releaseLock(rootId, 99999, "myhost"));
  assert(!repo.releaseLock(rootId, myPid, "wronghost"));
  assert(repo.getLock(rootId, queried));

  // Release lock with matching credentials succeeds
  assert(repo.releaseLock(rootId, myPid, "myhost"));
  assert(!repo.getLock(rootId, queried));

  // Re-acquire works
  assert(
    repo.acquireLock(
      LockRequest(rootId, myPid, "myhost", 1700000030), existing
    )
  );

  // Break lock works unconditionally
  assert(repo.breakLock(rootId));
  assert(!repo.getLock(rootId, queried));

  // Re-acquire after break works
  assert(
    repo.acquireLock(
      LockRequest(rootId, myPid, "myhost", 1700000040), existing
    )
  );

  // Cascade delete on root removal
  db.execute("DELETE FROM roots WHERE id = ?;", rootId);
  assert(!repo.getLock(rootId, queried));

  // Dead PID check (PID 99999999 is extraordinarily unlikely to exist)
  version (Posix) {
    assert(!isPidAlive(99_999_999));
    assert(!isPidAlive(-1));
  }
}
