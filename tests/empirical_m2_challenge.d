module orglistremo.empirical_m2_challenge;

version (unittest):

import core.atomic : atomicLoad, atomicOp;
import core.runtime : Runtime, UnitTestResult;
import core.sync.mutex : Mutex;
import core.thread : Thread, ThreadGroup;
import core.time : dur;
import d2sqlite3 : Database, Statement;
import orglistremo.db.connection : openDatabaseChecked, readDbSchemaVersion;
import orglistremo.db.migration : migrateDatabase;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.internal.os :
  getDeviceFreeSpace, getLocalHostName, getTerminalWidth, isPidAlive,
  isStdoutTty, isTty;
import orglistremo.internal.testutil :
  captureOutput, createLegacyV0Db, LegacyV0Options, TempDir;
import std.file :
  exists, mkdirRecurse, readText, remove, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : environment, execute, thisProcessID;
import std.stdio : File, stderr, writeln;

shared static this() {
  Runtime.extendedModuleUnitTester = () {
    UnitTestResult result;
    result.runMain = true;
    result.summarize = false;
    return result;
  };
}

shared int g_failures = 0;

void recordAssertion(bool condition, string testId, string detail) {
  if (condition) {
    writeln("  [PASS] ", testId, ": ", detail);
  } else {
    atomicOp!"+="(g_failures, 1);
    stderr.writeln("  [FAIL] ", testId, ": ", detail);
  }
}

// ===========================================================================
// SUITE 1: TempDir Concurrency & Collision-Freedom
// ===========================================================================

void runThreadTempDirWorker(
  shared(string[])* allPaths,
  Mutex pathsMutex,
  int threadIdx,
  int countPerThread
) {
  foreach (i; 0 .. countPerThread) {
    const string tag = format("t_%d_%d", threadIdx, i);
    TempDir dir = TempDir(tag);
    const string dirPath = dir.path;

    // Verify directory exists
    assert(exists(dirPath), "TempDir must exist on disk");

    // Write unique file inside
    const string fpath = dir.subPath("probe.txt");
    const string payload = format("th=%d_seq=%d", threadIdx, i);
    write(fpath, payload);
    assert(readText(fpath) == payload, "Payload mismatch");

    pathsMutex.lock();
    try {
      *allPaths ~= dirPath;
    } finally {
      pathsMutex.unlock();
    }
    // dir closed at end of iteration
  }
}

void testTempDirThreads(int threadCount, int countPerThread) {
  shared(string[]) createdPaths;
  Mutex mtx = new Mutex();
  ThreadGroup group = new ThreadGroup();

  foreach (t; 0 .. threadCount) {
    const int tIdx = t;
    group.create({
      runThreadTempDirWorker(&createdPaths, mtx, tIdx, countPerThread);
    });
  }
  group.joinAll();

  const totalAllocated = threadCount * countPerThread;
  recordAssertion(
    createdPaths.length == totalAllocated,
    "TEMPDIR-01",
    format(
      "Allocated %d TempDirs across %d threads", totalAllocated, threadCount
    )
  );

  // Check for uniqueness
  bool[string] uniqueMap;
  foreach (p; createdPaths) {
    uniqueMap[p] = true;
  }
  recordAssertion(
    uniqueMap.length == totalAllocated,
    "TEMPDIR-02",
    format("%d/%d unique paths (0 collisions across threads)",
           uniqueMap.length, totalAllocated)
  );

  // Verify all were cleaned up on destruction
  int lingering = 0;
  foreach (p; createdPaths) {
    if (exists(p)) {
      lingering++;
    }
  }
  recordAssertion(
    lingering == 0,
    "TEMPDIR-03",
    format("0 lingering directories after thread destruction (%d checked)",
           createdPaths.length)
  );
}

void testTempDirMultiProcess(string workDir) {
  version (Posix) {
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : fork;

    const int processCount = 4;
    const int dirsPerProc = 30;
    int[processCount] pids;

    foreach (pIdx; 0 .. processCount) {
      const int pid = fork();
      if (pid == 0) {
        // Child process
        const string procLog = buildPath(
          workDir, format("proc_%d.log", pIdx)
        );
        File logFile = File(procLog, "w");
        foreach (d; 0 .. dirsPerProc) {
          TempDir dir = TempDir("multi_proc");
          logFile.writeln(dir.path);
        }
        logFile.flush();
        logFile.close();
        import core.stdc.stdlib : exit;
        exit(0);
      } else {
        pids[pIdx] = pid;
      }
    }

    // Wait for all children
    foreach (pid; pids) {
      int status;
      waitpid(pid, &status, 0);
    }

    bool[string] allProcPaths;
    int totalCount = 0;
    foreach (pIdx; 0 .. processCount) {
      const string procLog = buildPath(
        workDir, format("proc_%d.log", pIdx)
      );
      if (exists(procLog)) {
        File f = File(procLog, "r");
        foreach (line; f.byLine()) {
          allProcPaths[line.idup] = true;
          totalCount++;
        }
        f.close();
      }
    }

    const int expected = processCount * dirsPerProc;
    recordAssertion(
      totalCount == expected && allProcPaths.length == expected,
      "TEMPDIR-04",
      format("Multi-process: %d/%d paths unique (0 collisions across %d procs)",
             allProcPaths.length, expected, processCount)
    );
  }
}

// ===========================================================================
// SUITE 2: TempDir Cleanup with Read-Only and Permission-Stripped Files
// ===========================================================================

void testCleanupReadOnlyFiles() {
  string dirPath;
  {
    TempDir dir = TempDir("ro_files");
    dirPath = dir.path;

    const string normalFile = dir.subPath("normal.txt");
    const string roFile = dir.subPath("ro.txt");
    const string zeroFile = dir.subPath("zero.txt");

    write(normalFile, "normal data");
    write(roFile, "read-only data");
    write(zeroFile, "no permission data");

    version (Posix) {
      execute(["chmod", "444", roFile]);
      execute(["chmod", "000", zeroFile]);
    }
  } // Destructor runs cleanupPath

  recordAssertion(
    !exists(dirPath),
    "CLEANUP-01",
    "Cleaned up TempDir containing chmod 444 and chmod 000 files"
  );
}

void testCleanupRestrictedDirs() {
  string dirPath;
  {
    TempDir dir = TempDir("ro_dirs");
    dirPath = dir.path;

    const string sub500 = dir.subPath("sub_500");
    const string sub000 = dir.subPath("sub_000");

    mkdirRecurse(sub500);
    mkdirRecurse(sub000);

    write(buildPath(sub500, "f1.txt"), "sub500 content");
    write(buildPath(sub000, "f2.txt"), "sub000 content");

    version (Posix) {
      execute(["chmod", "500", sub500]);
      execute(["chmod", "000", sub000]);
    }
  } // Destructor runs

  recordAssertion(
    !exists(dirPath),
    "CLEANUP-02",
    "Cleaned up TempDir containing subdirs with chmod 500 and chmod 000"
  );
}

void testCleanupDeepHierarchy() {
  string dirPath;
  {
    TempDir dir = TempDir("deep_hier");
    dirPath = dir.path;

    const string l1 = dir.subPath("lvl1");
    const string l2 = buildPath(l1, "lvl2");
    const string l3 = buildPath(l2, "lvl3");
    const string l4 = buildPath(l3, "lvl4");
    mkdirRecurse(l4);

    write(buildPath(l4, "deep.txt"), "deep nested data");
    write(buildPath(l2, "mid.txt"), "mid level data");

    version (Posix) {
      execute(["chmod", "500", l3]);
      execute(["chmod", "500", l1]);
    }
  }

  recordAssertion(
    !exists(dirPath),
    "CLEANUP-03",
    "Cleaned up deep 4-level nested directory with intermediate chmod 500"
  );
}

void testCleanupSymlinks() {
  string dirPath;
  {
    TempDir dir = TempDir("symlinks");
    dirPath = dir.path;

    const string realFile = dir.subPath("real.txt");
    write(realFile, "real content");

    version (Posix) {
      import core.sys.posix.unistd : symlink;
      import std.string : toStringz;

      // Internal symlink
      symlink(realFile.toStringz, dir.subPath("link_internal").toStringz);
      // Dangling symlink
      symlink("/nonexistent/file/path".toStringz,
              dir.subPath("link_dangling").toStringz);
      // Outside symlink
      symlink("/dev/null".toStringz, dir.subPath("link_outside").toStringz);
    }
  }

  recordAssertion(
    !exists(dirPath),
    "CLEANUP-04",
    "Cleaned up TempDir containing internal, dangling, and outside symlinks"
  );
}

// ===========================================================================
// SUITE 3: createLegacyV0Db on File Paths and :memory:
// ===========================================================================

void testLegacyV0FileMigration(string workDir) {
  const string dbPath = buildPath(workDir, "legacy_file.db");
  const options = LegacyV0Options("v0_root", "/mnt/v0_data", 1612345678);

  createLegacyV0Db(dbPath, options);
  recordAssertion(exists(dbPath), "LEGACY-01", "Legacy v0 file DB created");

  auto db = Database(dbPath);
  const int v0 = readDbSchemaVersion(db);
  recordAssertion(
    v0 == 0,
    "LEGACY-02",
    format("Initial schema version is 0 (read %d)", v0)
  );

  // Check initial root
  Statement stmt = db.prepare("SELECT name, path, created_at FROM roots;");
  auto res = stmt.execute();
  recordAssertion(
    !res.empty && res.oneValue!string == "v0_root",
    "LEGACY-03",
    "Initial root 'v0_root' present in v0 roots table"
  );

  // Migrate DB to latest schema
  migrateDatabase(db, 0);

  const int vLatest = readDbSchemaVersion(db);
  recordAssertion(
    vLatest == schemaVersion,
    "LEGACY-04",
    format("Migrated file DB to schema version %d", vLatest)
  );

  // Verify new columns and tables
  Statement checkCol = db.prepare("SELECT free_space FROM roots LIMIT 1;");
  auto colRes = checkCol.execute();
  recordAssertion(
    !colRes.empty,
    "LEGACY-05",
    "Column 'free_space' accessible in migrated roots table"
  );

  Statement checkLock = db.prepare("SELECT count(*) FROM sync_locks;");
  const long lockCount = checkLock.execute().oneValue!long;
  recordAssertion(
    lockCount == 0,
    "LEGACY-06",
    "Table 'sync_locks' created and queryable"
  );
  db.close();
}

void testLegacyV0InMemoryMigration() {
  Database memDb = Database(":memory:");
  const options = LegacyV0Options("mem_root", "/ram/data", 1698765432);

  createLegacyV0Db(memDb, options);

  const int v0 = readDbSchemaVersion(memDb);
  recordAssertion(
    v0 == 0,
    "LEGACY-07",
    format("In-memory legacy schema version is 0 (read %d)", v0)
  );

  migrateDatabase(memDb, 0);

  const int vLatest = readDbSchemaVersion(memDb);
  recordAssertion(
    vLatest == schemaVersion,
    "LEGACY-08",
    format("In-memory migrated successfully to schema version %d", vLatest)
  );

  Statement checkRoot = memDb.prepare(
    "SELECT name, path FROM roots WHERE name = ?;"
  );
  checkRoot.bind(1, "mem_root");
  auto r = checkRoot.execute();
  recordAssertion(
    !r.empty && r.oneValue!string == "mem_root",
    "LEGACY-09",
    "Preserved root data in migrated in-memory DB"
  );
  memDb.close();
}

void testLegacyV0EmptyOptions() {
  Database memDb = Database(":memory:");
  createLegacyV0Db(memDb, LegacyV0Options("", "", 0));

  Statement countStmt = memDb.prepare("SELECT count(*) FROM roots;");
  const long count = countStmt.execute().oneValue!long;
  recordAssertion(
    count == 0,
    "LEGACY-10",
    "Legacy DB with empty rootName contains 0 initial roots"
  );

  migrateDatabase(memDb, 0);
  recordAssertion(
    readDbSchemaVersion(memDb) == schemaVersion,
    "LEGACY-11",
    "Migrated empty legacy DB successfully to schemaVersion"
  );
  memDb.close();
}

// ===========================================================================
// SUITE 4: captureOutput Stress & ANSI Sequences
// ===========================================================================

void testCaptureOutputHighVolume() {
  enum int lineCount = 30_000;

  const string captured = captureOutput((File f) {
    foreach (i; 0 .. lineCount) {
      f.writeln("Line ", i, ": high volume stream payload 1234567890ABCDEF");
    }
  });

  import std.string : splitLines;
  const string[] lines = captured.splitLines();
  recordAssertion(
    lines.length == lineCount,
    "CAPTURE-01",
    format("Captured all %d lines in high volume output (%d bytes)",
           lineCount, captured.length)
  );

  const string expectedLast = format(
    "Line %d: high volume stream payload 1234567890ABCDEF", lineCount - 1
  );
  recordAssertion(
    lines[0] == "Line 0: high volume stream payload 1234567890ABCDEF" &&
    lines[$ - 1] == expectedLast,
    "CAPTURE-02",
    "First and last lines match exact content without truncation"
  );
}

void testCaptureOutputAnsi() {
  const string ansiText =
    "\033[1;31mBold Red\033[0m " ~
    "\033[38;2;255;128;64m24-bit TrueColor\033[0m " ~
    "\033[2J\033[H" ~
    "🚀 UTF-8: 日本語 Тест München" ~
    "\033[?25l\033[K\n";

  const string captured = captureOutput((File f) {
    f.write(ansiText);
  });

  recordAssertion(
    captured == ansiText,
    "CAPTURE-03",
    "Preserved exact byte stream for complex ANSI codes and multibyte UTF-8"
  );
}

void testCaptureOutputEdgeCases() {
  const string emptyCaptured = captureOutput((File f) {
    // Write nothing
  });
  recordAssertion(
    emptyCaptured == "",
    "CAPTURE-04",
    "Zero-length output returns empty string"
  );

  const char[6] binaryData = ['A', '\0', 'B', '\0', 'C', '\n'];
  const string binCaptured = captureOutput((File f) {
    f.rawWrite(binaryData[]);
  });
  recordAssertion(
    binCaptured.length == binaryData.length &&
    binCaptured[1] == '\0' && binCaptured[3] == '\0',
    "CAPTURE-05",
    "Binary data with null bytes captured without string truncation"
  );
}

// ===========================================================================
// SUITE 5: isPidAlive Positive, Negative and Invalid PIDs
// ===========================================================================

void testIsPidAliveValid() {
  recordAssertion(
    isPidAlive(thisProcessID),
    "PID-01",
    format("Current PID (%d) is alive", thisProcessID)
  );

  version (Posix) {
    import core.sys.posix.unistd : getppid;
    const int ppid = getppid();
    recordAssertion(
      isPidAlive(ppid),
      "PID-02",
      format("Parent PID (%d) is alive", ppid)
    );

    recordAssertion(
      isPidAlive(1),
      "PID-03",
      "PID 1 (init/systemd) is reported alive across privilege boundaries"
    );
  }
}

void testIsPidAliveSpawnAndExit() {
  version (Posix) {
    import core.sys.posix.signal : kill, SIGKILL;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : fork, pause;

    const int childPid = fork();
    if (childPid == 0) {
      // Child process sleeps until killed
      pause();
      import core.stdc.stdlib : exit;
      exit(0);
    }

    // Give child time to enter pause
    Thread.sleep(dur!"msecs"(20));

    recordAssertion(
      isPidAlive(childPid),
      "PID-04",
      format("Spawned child PID (%d) is alive while running", childPid)
    );

    // Kill child
    kill(childPid, SIGKILL);
    int status;
    waitpid(childPid, &status, 0);

    // Reap completed - now PID is dead
    recordAssertion(
      !isPidAlive(childPid),
      "PID-05",
      format("Reaped child PID (%d) is dead", childPid)
    );
  }
}

void testIsPidAliveInvalid() {
  recordAssertion(!isPidAlive(0), "PID-06", "PID 0 is not alive");
  recordAssertion(!isPidAlive(-1), "PID-07", "PID -1 is not alive");
  recordAssertion(!isPidAlive(-100), "PID-08", "PID -100 is not alive");
  recordAssertion(!isPidAlive(int.min), "PID-09", "PID int.min is not alive");

  version (Posix) {
    recordAssertion(
      !isPidAlive(99_999_999),
      "PID-10",
      "Non-existent PID 99999999 is reported dead"
    );
  }
}

// ===========================================================================
// SUITE 6: getLocalHostName & Socketless OS Wrappers
// ===========================================================================

void testGetLocalHostName() {
  const string host = getLocalHostName();
  recordAssertion(
    host.length > 0 && host != "",
    "HOST-01",
    format("getLocalHostName() returned non-empty string: '%s'", host)
  );

  version (Posix) {
    import core.sys.posix.unistd : gethostname;
    import std.string : fromStringz;

    char[256] buf;
    if (gethostname(buf.ptr, buf.length) == 0) {
      buf[$ - 1] = '\0';
      const string sysHost = buf.ptr.fromStringz.idup;
      recordAssertion(
        host == sysHost,
        "HOST-02",
        format("getLocalHostName matches POSIX gethostname ('%s')", sysHost)
      );
    }
  }

  // Verify that source/orglistremo/internal/os.d does NOT import std.socket
  const string osSource = readText("source/orglistremo/internal/os.d");
  import std.string : indexOf;
  recordAssertion(
    osSource.indexOf("std.socket") == -1,
    "HOST-03",
    "source/orglistremo/internal/os.d contains NO imports of std.socket"
  );
}

void testOtherOsWrappers() {
  // Free space on /tmp
  const freeSpace = getDeviceFreeSpace(tempDir());
  recordAssertion(
    !freeSpace.isNull && freeSpace.get > 0,
    "OS-01",
    format("getDeviceFreeSpace(tempDir) returned %d bytes", freeSpace.get)
  );

  // Invalid path free space returns null
  const invalidSpace = getDeviceFreeSpace("/nonexistent_path_xyz_123");
  recordAssertion(
    invalidSpace.isNull,
    "OS-02",
    "getDeviceFreeSpace on nonexistent path returns null"
  );

  // Terminal width default fallback
  const uint defWidth = getTerminalWidth(-1);
  recordAssertion(
    defWidth == 80,
    "OS-03",
    format("getTerminalWidth(-1) returns default 80 (got %d)", defWidth)
  );

  // TTY detection on invalid fd
  recordAssertion(
    !isTty(-1),
    "OS-04",
    "isTty(-1) returns false"
  );
}

// ===========================================================================
// MAIN RUNNER
// ===========================================================================

void main() {
  const string baseWorkDir = buildPath(tempDir(), "listremo_empirical_m2_test");
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
  writeln("STARTING EMPIRICAL CHALLENGER VERIFICATION FOR MILESTONE 2");
  writeln("============================================================");

  writeln("\n=== SUITE 1: TempDir Concurrency & Collision-Freedom ===");
  testTempDirThreads(16, 50); // 800 TempDirs across 16 threads
  testTempDirMultiProcess(baseWorkDir);

  writeln("\n=== SUITE 2: TempDir Cleanup with Restricted Permissions ===");
  testCleanupReadOnlyFiles();
  testCleanupRestrictedDirs();
  testCleanupDeepHierarchy();
  testCleanupSymlinks();

  writeln("\n=== SUITE 3: createLegacyV0Db and Migration ===");
  testLegacyV0FileMigration(baseWorkDir);
  testLegacyV0InMemoryMigration();
  testLegacyV0EmptyOptions();

  writeln("\n=== SUITE 4: captureOutput High Volume and ANSI ===");
  testCaptureOutputHighVolume();
  testCaptureOutputAnsi();
  testCaptureOutputEdgeCases();

  writeln("\n=== SUITE 5: isPidAlive POSIX / Process Verification ===");
  testIsPidAliveValid();
  testIsPidAliveSpawnAndExit();
  testIsPidAliveInvalid();

  writeln("\n=== SUITE 6: getLocalHostName and OS Wrappers ===");
  testGetLocalHostName();
  testOtherOsWrappers();

  writeln("\n============================================================");
  const int totalFailures = atomicLoad(g_failures);
  if (totalFailures == 0) {
    writeln("ALL EMPIRICAL CHALLENGES PASSED (0 failures)!");
  } else {
    stderr.writeln(
      format(
        "EMPIRICAL CHALLENGES FAILED: %d failures recorded!", totalFailures
      )
    );
  }
  writeln("============================================================");

  if (totalFailures != 0) {
    import core.stdc.stdlib : exit;
    exit(1);
  }
}
