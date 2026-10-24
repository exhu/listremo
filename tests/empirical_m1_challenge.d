module orglistremo.empirical_m1_challenge;

import core.atomic : atomicOp, atomicLoad;
import core.sync.mutex : Mutex;
import core.thread : Thread, ThreadGroup;
import core.time : dur;
import d2sqlite3 : Database, ResultRange, Row, Statement;
import orglistremo.db.backup : writeDatabaseBackup;
import orglistremo.db.connection :
  DbOpenResult, openDatabaseChecked, openWorkerDatabase, readDbSchemaVersion;
import orglistremo.db.repo : EntryRepository, RootRepository;
import orglistremo.db.repo_locks : SyncLockInfo, SyncLockRepository;
import orglistremo.db.migration : migrateDatabase;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.model : Entry, Root;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath;
import std.stdio : stderr, writeln;

shared int g_failures = 0;

void recordAssertion(bool condition, string testName, string detail) {
  if (condition) {
    writeln("  [PASS] ", testName, ": ", detail);
  } else {
    atomicOp!"+="(g_failures, 1);
    stderr.writeln("  [FAIL] ", testName, ": ", detail);
  }
}

// ---------------------------------------------------------------------------
// Suite 1: BUG-01 WAL Backup under Concurrent Writes & High Load
// ---------------------------------------------------------------------------
void testWalBackupStress(string workDir) {
  writeln("\n=== SUITE 1: BUG-01 WAL Backup Stress Testing ===");

  const srcDbPath = buildPath(workDir, "wal_stress_src.db");
  const bkpDbPath = buildPath(workDir, "wal_stress_bkp.db");

  if (exists(srcDbPath)) {
    remove(srcDbPath);
  }
  if (exists(bkpDbPath)) {
    remove(bkpDbPath);
  }

  // 1. Initialize source DB in WAL mode with active autocheckpoint disabled
  {
    auto db = Database(srcDbPath);
    db.execute("PRAGMA journal_mode = WAL;");
    db.execute("PRAGMA wal_autocheckpoint = 0;");
    db.execute("CREATE TABLE stress_log (id INTEGER PRIMARY KEY, msg TEXT);");
    db.close();
  }

  // 2. Launch concurrent writer inserting 500 batches
  shared bool writerRunning = true;
  shared int writesCommitted = 0;

  auto writerThread = new Thread({
    auto writerDb = Database(srcDbPath);
    writerDb.execute("PRAGMA busy_timeout = 30000;");
    for (int i = 1; i <= 600; i++) {
      writerDb.execute("BEGIN IMMEDIATE;");
      writerDb.execute(
        "INSERT INTO stress_log (msg) VALUES (?);",
        format("payload-%d", i)
      );
      writerDb.execute("COMMIT;");
      atomicOp!"+="(writesCommitted, 1);
      Thread.sleep(dur!"usecs"(200));
    }
    writerDb.close();
  });
  writerThread.start();

  // Allow writer to establish active uncheckpointed WAL frames
  Thread.sleep(dur!"msecs"(30));

  // 3. Open another connection and perform WAL backup while writer is writing
  auto readerDb = Database(srcDbPath);
  readerDb.execute("PRAGMA busy_timeout = 30000;");

  writeDatabaseBackup(readerDb, bkpDbPath);
  writerThread.join();

  recordAssertion(
    exists(bkpDbPath),
    "BUG-01.1",
    "Backup file exists after concurrent WAL backup"
  );

  // 4. Validate backup database integrity and readability
  auto bkpDb = Database(bkpDbPath);
  const integrityResult =
    bkpDb.execute("PRAGMA integrity_check;").oneValue!string;
  recordAssertion(
    integrityResult == "ok",
    "BUG-01.2",
    format("Backup database PRAGMA integrity_check == '%s'", integrityResult)
  );

  const bkpCount =
    bkpDb.execute("SELECT COUNT(*) FROM stress_log;").oneValue!long;
  recordAssertion(
    bkpCount > 0 && bkpCount <= atomicLoad(writesCommitted),
    "BUG-01.3",
    format("Backup has consistent snapshot (%d rows)", bkpCount)
  );

  // 5. Test overwrite existing backup
  writeDatabaseBackup(readerDb, bkpDbPath);
  auto bkpDb2 = Database(bkpDbPath);
  const bkpCount2 =
    bkpDb2.execute("SELECT COUNT(*) FROM stress_log;").oneValue!long;
  recordAssertion(
    bkpCount2 == atomicLoad(writesCommitted),
    "BUG-01.4",
    format("Overwriting backup captured all %d rows", bkpCount2)
  );
  bkpDb2.close();

  // 6. Test backup with query_only = ON (verify pragma restoration)
  readerDb.execute("PRAGMA query_only = ON;");
  const nestedBkp = buildPath(workDir, "nested", "sub", "wal_nested_bkp.db");
  writeDatabaseBackup(readerDb, nestedBkp);
  const stillQueryOnly =
    readerDb.execute("PRAGMA query_only;").oneValue!int != 0;
  recordAssertion(
    stillQueryOnly,
    "BUG-01.5",
    "Source DB query_only = ON preserved after backup"
  );
  recordAssertion(
    exists(nestedBkp),
    "BUG-01.6",
    "Backup to nested directory succeeded"
  );

  // 7. Test in-memory DB snapshot to disk
  auto memDb = Database(":memory:");
  memDb.execute("CREATE TABLE m (k INT, v TEXT);");
  memDb.execute("INSERT INTO m VALUES (1, 'in-memory-val');");
  const memBkp = buildPath(workDir, "mem_backup.db");
  writeDatabaseBackup(memDb, memBkp);
  auto memBkpDb = Database(memBkp);
  const memVal =
    memBkpDb.execute("SELECT v FROM m WHERE k = 1;").oneValue!string;
  recordAssertion(
    memVal == "in-memory-val",
    "BUG-01.7",
    "In-memory database successfully snapshotted to file"
  );
  memBkpDb.close();
  memDb.close();

  readerDb.close();
  bkpDb.close();
}

// ---------------------------------------------------------------------------
// Suite 2: BUG-07 Lock Ownership Verification
// ---------------------------------------------------------------------------
void testLockOwnershipStress(string workDir) {
  writeln("\n=== SUITE 2: BUG-07 Lock Ownership Stress Testing ===");

  const dbPath = buildPath(workDir, "lock_stress.db");
  if (exists(dbPath)) {
    remove(dbPath);
  }

  auto db = Database(dbPath);
  db.execute("PRAGMA journal_mode = WAL;");
  db.execute("PRAGMA foreign_keys = ON;");
  db.execute(`
    CREATE TABLE roots (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      last_sync INTEGER,
      free_space INTEGER
    );
  `);
  db.execute(`
    CREATE TABLE sync_locks (
      root_id INTEGER PRIMARY KEY,
      pid INTEGER NOT NULL,
      started_at INTEGER NOT NULL,
      hostname TEXT NOT NULL,
      FOREIGN KEY(root_id) REFERENCES roots(id) ON DELETE CASCADE
    );
  `);
  db.execute(`
    INSERT INTO roots (name, path, created_at)
    VALUES ('r1', '/mnt/r1', 1700000000);
  `);
  const rootId = db.lastInsertRowid;

  SyncLockRepository repo = SyncLockRepository(db);
  SyncLockInfo existing;

  // 1. Process A acquires lock
  const bool acqA =
    repo.acquireLock(rootId, 1001, "host-alpha", 1700000010, existing);
  recordAssertion(acqA, "BUG-07.1", "Process A acquired lock");

  // 2. Mismatched PID / Hostname release attempts MUST FAIL
  const bool relWrongPid = repo.releaseLock(rootId, 1002, "host-alpha");
  recordAssertion(
    !relWrongPid,
    "BUG-07.2",
    "Release with mismatched PID returns false"
  );

  const bool relWrongHost = repo.releaseLock(rootId, 1001, "host-beta");
  recordAssertion(
    !relWrongHost,
    "BUG-07.3",
    "Release with mismatched hostname returns false"
  );

  const bool relBothWrong = repo.releaseLock(rootId, 9999, "unknown");
  recordAssertion(
    !relBothWrong,
    "BUG-07.4",
    "Release with both wrong credentials returns false"
  );

  // Verify lock is still intact for Process A
  SyncLockInfo info;
  recordAssertion(
    repo.getLock(rootId, info) && info.pid == 1001,
    "BUG-07.5",
    "Lock is still held by Process A (1001, host-alpha)"
  );

  // 3. Exact BUG-07 reproduction scenario:
  // Admin breaks lock for Process A, Process B acquires, Process A exits
  const bool broken = repo.breakLock(rootId);
  recordAssertion(broken, "BUG-07.6", "breakLock broke lock unconditionally");

  // Process B acquires lock
  const bool acqB =
    repo.acquireLock(rootId, 2002, "host-beta", 1700000020, existing);
  recordAssertion(acqB, "BUG-07.7", "Process B acquired lock after break");

  // Process A terminates and attempts to release its old lock
  const bool aReleased = repo.releaseLock(rootId, 1001, "host-alpha");
  recordAssertion(
    !aReleased,
    "BUG-07.8",
    "Process A cannot release lock now held by Process B"
  );

  // Verify Process B's lock is completely untouched!
  recordAssertion(
    repo.getLock(rootId, info)
      && info.pid == 2002
      && info.hostname == "host-beta",
    "BUG-07.9",
    "Process B's lock remains active and untouched"
  );

  // Process B releases properly
  const bool bReleased = repo.releaseLock(rootId, 2002, "host-beta");
  recordAssertion(
    bReleased,
    "BUG-07.10",
    "Process B released lock with valid credentials"
  );

  recordAssertion(
    !repo.getLock(rootId, info),
    "BUG-07.11",
    "Lock table is now empty"
  );

  // 4. Concurrent acquisition race: 10 threads attempt acquireLock on rootId
  // exactly 1 must win, 9 must cleanly fail
  const int acqContenders = 10;
  shared int acqWinners = 0;
  shared int acqLosers = 0;
  auto acqGroup = new ThreadGroup();

  for (int i = 0; i < acqContenders; i++) {
    const int threadPid = 5000 + i;
    const string threadHost = format("contender-host-%d", i);
    acqGroup.create({
      auto tDb = Database(dbPath);
      tDb.execute("PRAGMA busy_timeout = 10000;");
      auto tRepo = SyncLockRepository(tDb);
      SyncLockInfo tInfo;
      if (tRepo.acquireLock(rootId, threadPid, threadHost, 1700000000, tInfo)) {
        atomicOp!"+="(acqWinners, 1);
      } else {
        atomicOp!"+="(acqLosers, 1);
      }
      tDb.close();
    });
  }
  acqGroup.joinAll();

  recordAssertion(
    atomicLoad(acqWinners) == 1 && atomicLoad(acqLosers) == 9,
    "BUG-07.12",
    "Concurrent acquire race: exactly 1 winner, 9 losers"
  );

  // 5. Hostname with SQL injection payload and special chars
  repo.breakLock(rootId);
  const string evilHost = "'; DROP TABLE sync_locks; -- '\"\\";
  const bool evilAcq =
    repo.acquireLock(rootId, 7777, evilHost, 1700000000, existing);
  recordAssertion(
    evilAcq,
    "BUG-07.13",
    "Acquired lock with SQL injection payload in hostname"
  );

  const bool evilRelWrong = repo.releaseLock(rootId, 7777, "other");
  recordAssertion(
    !evilRelWrong,
    "BUG-07.14",
    "Cannot release evil lock with wrong hostname"
  );

  const bool evilRelRight = repo.releaseLock(rootId, 7777, evilHost);
  recordAssertion(
    evilRelRight,
    "BUG-07.15",
    "Cleanly released evil lock with matching hostname"
  );

  db.close();
}

// ---------------------------------------------------------------------------
// Suite 3: BUG-05 & PERF-03 Atomic Sync Staging, Rollback & Stale Deletion
// ---------------------------------------------------------------------------
void testAtomicSyncStagingAndRollback(string workDir) {
  writeln("\n=== SUITE 3: BUG-05 & PERF-03 Atomic Sync Staging & Rollback ===");

  const dbPath = buildPath(workDir, "sync_atomic.db");
  if (exists(dbPath)) {
    remove(dbPath);
  }

  DbOpenResult openRes = openDatabaseChecked(dbPath);
  Database db = openRes.db;
  RootRepository rootRepo = RootRepository(db);
  EntryRepository entryRepo = EntryRepository(db);

  const rootId = rootRepo.addRoot("atomic_root", "/mock/path");

  // 1. Pre-populate live entries table with 100 initial files
  Entry[] initialEntries;
  for (int i = 0; i < 100; i++) {
    Entry e;
    e.rootId = rootId;
    e.relPath = format("file_%03d.txt", i);
    e.name = format("file_%03d.txt", i);
    e.parentPath = ".";
    e.isDir = false;
    e.size = 1000 + i;
    e.mtime = 1700000000 + i;
    e.sha256 = format("sha_%03d", i);
    initialEntries ~= e;
  }
  entryRepo.saveSyncEntries(rootId, initialEntries, 1700000000);

  const initialCount =
    db.execute(
      "SELECT COUNT(*) FROM entries WHERE root_id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    initialCount == 100,
    "BUG-05.1",
    format("Initial live entries count is %d", initialCount)
  );

  // 2. Simulate Mid-Sync Abort: stage 50 new/updated entries in batches,
  // then abort
  Entry[] newStagedEntries;
  for (int i = 0; i < 50; i++) {
    Entry e;
    e.rootId = rootId;
    e.relPath = format("partial_file_%03d.txt", i);
    e.name = format("partial_file_%03d.txt", i);
    e.parentPath = ".";
    e.isDir = false;
    e.size = 5000 + i;
    e.mtime = 1700001000 + i;
    e.sha256 = format("newsha_%03d", i);
    newStagedEntries ~= e;
  }

  // Stage batch 1 (25 entries)
  entryRepo.stageEntriesBatch(rootId, newStagedEntries[0 .. 25]);
  // Stage batch 2 (25 entries)
  entryRepo.stageEntriesBatch(rootId, newStagedEntries[25 .. 50]);

  // Verify staged entries are currently in TEMP table
  const stagedCount =
    db.execute(
      "SELECT COUNT(*) FROM temp.sync_staged_entries WHERE root_id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    stagedCount == 50,
    "BUG-05.2",
    format("Staged 50 entries in temp table (invisible to live entries)")
  );

  // Check live entries table during staging
  const liveCountDuringStaging =
    db.execute(
      "SELECT COUNT(*) FROM entries WHERE root_id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    liveCountDuringStaging == 100,
    "BUG-05.3",
    "Live entries table untouched during staging"
  );

  // Abort mid-sync and clear staged entries
  entryRepo.clearStagedEntries(rootId);

  const liveCountAfterAbort =
    db.execute(
      "SELECT COUNT(*) FROM entries WHERE root_id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    liveCountAfterAbort == 100,
    "BUG-05.4",
    "Live entries table has ZERO partial entries after aborted sync"
  );

  const stagedCountAfterAbort =
    db.execute(
      "SELECT COUNT(*) FROM temp.sync_staged_entries WHERE root_id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    stagedCountAfterAbort == 0,
    "BUG-05.5",
    "Temp staged table completely cleaned after abort"
  );

  const long lastSyncUnchanged =
    db.execute(
      "SELECT last_sync FROM roots WHERE id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    lastSyncUnchanged == 1700000000,
    "BUG-05.6",
    "roots.last_sync unchanged after aborted sync"
  );

  // 3. PERF-03 Set-based stale deletion test:
  // Retain file_000 to file_049, modify file_050, delete file_051 to file_099,
  // add new_001
  Entry[] syncBatch;
  for (int i = 0; i < 50; i++) {
    syncBatch ~= initialEntries[i]; // retained unchanged
  }
  Entry modifiedEntry = initialEntries[50];
  modifiedEntry.size = 999999;
  modifiedEntry.sha256 = "MODIFIED_SHA";
  syncBatch ~= modifiedEntry;

  Entry brandNewEntry;
  brandNewEntry.rootId = rootId;
  brandNewEntry.relPath = "brand_new.txt";
  brandNewEntry.name = "brand_new.txt";
  brandNewEntry.parentPath = ".";
  brandNewEntry.isDir = false;
  brandNewEntry.size = 777;
  brandNewEntry.mtime = 1700005000;
  brandNewEntry.sha256 = "BRAND_NEW_SHA";
  syncBatch ~= brandNewEntry;

  // Stage and commit the sync
  entryRepo.stageEntriesBatch(rootId, syncBatch);
  entryRepo.commitStagedSync(rootId, 1700005500);

  // Verify stale files were deleted
  const finalCount =
    db.execute(
      "SELECT COUNT(*) FROM entries WHERE root_id = ?;",
      rootId
    ).oneValue!long;
  recordAssertion(
    finalCount == 52, // 50 unchanged + 1 modified + 1 brand new
    "PERF-03.1",
    format("Live entries count is exactly 52 (was 100, purged 49 stale rows)")
  );

  const staleCheck =
    db.execute(`
      SELECT COUNT(*) FROM entries
      WHERE root_id = ? AND rel_path = 'file_099.txt';
    `, rootId).oneValue!long;
  recordAssertion(
    staleCheck == 0,
    "PERF-03.2",
    "Stale file_099.txt was cleanly deleted"
  );

  {
    auto modCheck =
      db.execute(`
        SELECT sha256, size FROM entries
        WHERE root_id = ? AND rel_path = 'file_050.txt';
      `, rootId);
    auto modRow = modCheck.front;
    recordAssertion(
      modRow.peek!string(0) == "MODIFIED_SHA" && modRow.peek!long(1) == 999999,
      "PERF-03.3",
      "Modified entry has updated hash and size"
    );
  }

  const newCheck =
    db.execute(`
      SELECT COUNT(*) FROM entries
      WHERE root_id = ? AND rel_path = 'brand_new.txt';
    `, rootId).oneValue!long;
  recordAssertion(
    newCheck == 1,
    "PERF-03.4",
    "Brand new entry is present"
  );

  // 4. File-to-directory type change on same rel_path
  Entry[] typeBatch;
  Entry dirEntry;
  dirEntry.rootId = rootId;
  dirEntry.relPath = "file_001.txt"; // was file, now directory
  dirEntry.name = "file_001.txt";
  dirEntry.parentPath = ".";
  dirEntry.isDir = true;
  dirEntry.size = 0;
  dirEntry.mtime = 1700009000;
  dirEntry.sha256 = "DIR_HASH";
  typeBatch ~= dirEntry;

  entryRepo.stageEntriesBatch(rootId, typeBatch);
  entryRepo.commitStagedSync(rootId, 1700009000);

  const isDirAfter =
    db.execute(`
      SELECT is_dir FROM entries
      WHERE root_id = ? AND rel_path = 'file_001.txt';
    `, rootId).oneValue!int;
  recordAssertion(
    isDirAfter == 1,
    "PERF-03.5",
    "Entry transitioned from file to directory on same rel_path"
  );

  db.close();
}

// ---------------------------------------------------------------------------
// Suite 4: BUG-10 Migration Safety & PRAGMA query_only Restoration
// ---------------------------------------------------------------------------
void testMigrationSafety(string workDir) {
  writeln("\n=== SUITE 4: BUG-10 Migration Safety ===");

  const dbPath = buildPath(workDir, "migration_safety.db");
  if (exists(dbPath)) {
    remove(dbPath);
  }

  // 1. Create a schema v0 database
  {
    auto rawDb = Database(dbPath);
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
      VALUES ('root_v0', '/path/v0', 1600000000);
    `);
    rawDb.close();
  }

  // 2. Open legacy database: sets query_only = ON
  DbOpenResult v0Res = openDatabaseChecked(dbPath);
  recordAssertion(
    v0Res.isReadOnly,
    "BUG-10.1",
    "Legacy DB opened as read-only"
  );
  recordAssertion(
    v0Res.db.execute("PRAGMA query_only;").oneValue!int != 0,
    "BUG-10.2",
    "PRAGMA query_only is ON for unmigrated DB"
  );

  // 3. Induce migration error: inject a conflicting table that breaks
  // migrateFrom0to1 (e.g. entries table with incompatible schema or read-only)
  // We simulate failure by creating a conflicting version table with
  // incompatible structure
  v0Res.db.execute("PRAGMA query_only = OFF;");
  v0Res.db.execute("CREATE TABLE version (invalid_col TEXT NOT NULL);");
  v0Res.db.execute("PRAGMA query_only = ON;");

  bool migrationThrew = false;
  try {
    migrateDatabase(v0Res.db, 0);
  } catch (Exception e) {
    migrationThrew = true;
  }
  recordAssertion(
    migrationThrew,
    "BUG-10.3",
    "migrateDatabase failed as induced"
  );

  const queryOnlyAfterFail =
    v0Res.db.execute("PRAGMA query_only;").oneValue!int != 0;
  recordAssertion(
    queryOnlyAfterFail,
    "BUG-10.4",
    "PRAGMA query_only = ON is restored after migration failure"
  );

  // Verify write attempt fails because query_only is ON
  bool writeBlocked = false;
  try {
    v0Res.db.execute(
      "INSERT INTO roots (name, path, created_at) VALUES ('x', 'y', 1);"
    );
  } catch (Exception) {
    writeBlocked = true;
  }
  recordAssertion(
    writeBlocked,
    "BUG-10.5",
    "Writes blocked because query_only = ON remains enforced"
  );

  v0Res.db.close();

  // 4. Test clean migration sets write pragmas
  const cleanDbPath = buildPath(workDir, "migration_clean.db");
  if (exists(cleanDbPath)) {
    remove(cleanDbPath);
  }
  {
    auto rawDb = Database(cleanDbPath);
    rawDb.execute(`
      CREATE TABLE roots (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL UNIQUE,
        path        TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        last_sync   INTEGER
      );
    `);
    rawDb.close();
  }

  DbOpenResult cleanRes = openDatabaseChecked(cleanDbPath);
  migrateDatabase(cleanRes.db, 0);

  const jMode =
    cleanRes.db.execute("PRAGMA journal_mode;").oneValue!string;
  recordAssertion(
    jMode == "wal",
    "BUG-10.6",
    format("Migrated DB has journal_mode = '%s' (WAL)", jMode)
  );

  const syncMode =
    cleanRes.db.execute("PRAGMA synchronous;").oneValue!int;
  recordAssertion(
    syncMode == 1,
    "BUG-10.7",
    format("Migrated DB has synchronous = %d (NORMAL)", syncMode)
  );

  const queryOnlyClean =
    cleanRes.db.execute("PRAGMA query_only;").oneValue!int == 0;
  recordAssertion(
    queryOnlyClean,
    "BUG-10.8",
    "Migrated DB has query_only = OFF after successful migration"
  );

  // 5. Calling migrateDatabase with invalid version (-1 or >= schemaVersion)
  bool threwNeg = false;
  try {
    cleanRes.db.execute("PRAGMA query_only = OFF;");
    migrateDatabase(cleanRes.db, -1);
  } catch (Exception) {
    threwNeg = true;
  }
  recordAssertion(
    threwNeg,
    "BUG-10.9",
    "migrateDatabase throws on negative fromVersion"
  );

  bool threwCurrent = false;
  try {
    migrateDatabase(cleanRes.db, schemaVersion);
  } catch (Exception) {
    threwCurrent = true;
  }
  recordAssertion(
    threwCurrent,
    "BUG-10.10",
    "migrateDatabase throws when fromVersion >= schemaVersion"
  );

  cleanRes.db.close();
}

// ---------------------------------------------------------------------------
// Suite 5: openWorkerDatabase Concurrent Connection Storm
// ---------------------------------------------------------------------------
void testWorkerDatabaseConcurrency(string workDir) {
  writeln("\n=== SUITE 5: openWorkerDatabase Concurrency & Non-Contention ===");

  const dbPath = buildPath(workDir, "worker_storm.db");
  if (exists(dbPath)) {
    remove(dbPath);
  }

  // Initialize DB once with openDatabaseChecked
  DbOpenResult mainRes = openDatabaseChecked(dbPath);
  Database mainDb = mainRes.db;
  mainDb.execute(`
    INSERT INTO roots (name, path, created_at)
    VALUES ('storm_root', '/mnt/storm', 1700000000);
  `);
  const rootId = mainDb.lastInsertRowid;
  mainDb.close();

  // Launch 25 concurrent worker threads calling openWorkerDatabase
  const int workerCount = 25;
  shared int workersSucceeded = 0;
  shared int busyErrors = 0;
  shared int pragmaFkPass = 0;
  shared int pragmaTimeoutPass = 0;

  auto group = new ThreadGroup();

  for (int i = 0; i < workerCount; i++) {
    group.create({
      try {
        Database workerDb = openWorkerDatabase(dbPath, 15000);
        const fk = workerDb.execute("PRAGMA foreign_keys;").oneValue!int;
        if (fk == 1) {
          atomicOp!"+="(pragmaFkPass, 1);
        }
        const timeoutVal =
          workerDb.execute("PRAGMA busy_timeout;").oneValue!int;
        if (timeoutVal == 15000) {
          atomicOp!"+="(pragmaTimeoutPass, 1);
        }

        // Perform concurrent reads
        auto r = workerDb.execute(
          "SELECT COUNT(*) FROM roots WHERE id = ?;",
          rootId
        ).oneValue!long;
        if (r == 1) {
          atomicOp!"+="(workersSucceeded, 1);
        }
        workerDb.close();
      } catch (Exception e) {
        import std.algorithm.searching : canFind;
        if (e.msg.canFind("busy") || e.msg.canFind("locked")) {
          atomicOp!"+="(busyErrors, 1);
        }
        stderr.writeln("Worker thread error: ", e.msg);
      }
    });
  }

  group.joinAll();

  recordAssertion(
    atomicLoad(busyErrors) == 0,
    "WORKER-01",
    "Zero SQLITE_BUSY errors during concurrent worker connection storm"
  );
  recordAssertion(
    atomicLoad(workersSucceeded) == workerCount,
    "WORKER-02",
    format("All %d concurrent workers succeeded", workerCount)
  );
  recordAssertion(
    atomicLoad(pragmaFkPass) == workerCount,
    "WORKER-03",
    "All workers verified foreign_keys = ON"
  );
  recordAssertion(
    atomicLoad(pragmaTimeoutPass) == workerCount,
    "WORKER-04",
    "All workers verified busy_timeout = 15000"
  );
}

void main() {
  const baseWorkDir = buildPath(tempDir(), "listremo_empirical_m1_test");
  if (exists(baseWorkDir)) {
    rmdirRecurse(baseWorkDir);
  }
  mkdirRecurse(baseWorkDir);
  scope (exit) {
    if (exists(baseWorkDir)) {
      rmdirRecurse(baseWorkDir);
    }
  }

  writeln("============================================================");
  writeln("STARTING EMPIRICAL CHALLENGER VERIFICATION FOR MILESTONE 1");
  writeln("============================================================");

  testWalBackupStress(baseWorkDir);
  testLockOwnershipStress(baseWorkDir);
  testAtomicSyncStagingAndRollback(baseWorkDir);
  testMigrationSafety(baseWorkDir);
  testWorkerDatabaseConcurrency(baseWorkDir);

  writeln("\n============================================================");
  const totalFailures = atomicLoad(g_failures);
  if (totalFailures == 0) {
    writeln("ALL EMPIRICAL CHALLENGES PASSED (0 failures)!");
  } else {
    stderr.writeln(
      format(
        "EMPIRICAL CHALLENGES FAILED: %d failures recorded!",
        totalFailures
      )
    );
  }
  writeln("============================================================");

  if (totalFailures != 0) {
    import core.stdc.stdlib : exit;
    exit(1);
  }
}
