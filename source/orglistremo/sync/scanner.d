module orglistremo.sync.scanner;

import d2sqlite3 : Database;
import orglistremo.db.repo : CachedFileEntry, EntryRepository;
import orglistremo.internal.os : getDeviceFreeSpace;
import orglistremo.model : Entry, Root;
import orglistremo.sync.hasher : ChildRecord, hashDirectory, hashFile;
import orglistremo.sync.progress :
  SyncIssue, SyncIssueCallback, SyncPhase, SyncProgress, SyncProgressCallback;
import std.datetime.systime : Clock;
import std.file :
  dirEntries, DirEntry, exists, isDir, isFile, isSymlink, SpanMode,
  timeLastModified;
import std.path : baseName, buildPath;

struct SyncResult {
  ulong fileCount;
  ulong dirCount;
  ulong totalSize;
  ulong reusedHashes;
  SyncIssue[] errors;
}

struct SyncOptions {
  bool force;
  bool forceHash;
  size_t batchSize = 1000;
  SyncProgressCallback onProgress;
  SyncIssueCallback onIssue;
}

bool isDiskDirEmpty(string path) {
  foreach (entry; dirEntries(path, SpanMode.shallow, false)) {
    return false;
  }
  return true;
}

SyncResult syncRoot(
  ref Database db,
  const ref Root root,
  in SyncOptions options = SyncOptions.init
) {
  if (!exists(root.path) || !isDir(root.path)) {
    import std.format : format;
    throw new Exception(
      format("Root path does not exist or is not a directory: %s", root.path)
    );
  }

  auto entryRepo = EntryRepository(db);

  if (!options.force && isDiskDirEmpty(root.path)
      && entryRepo.hasCatalogedEntries(root.id)) {
    import std.format : format;
    throw new Exception(
      format(
        "Fatal error: Root path '%s' is empty while database is not. " ~
        "Use --force to continue (and empty database root).",
        root.path
      )
    );
  }

  const cachedMap = entryRepo.getFileEntriesMap(root.id);

  ScannerContext ctx = ScannerContext(
    root.id,
    root.name,
    options.forceHash,
    cachedMap,
    options.onProgress,
    options.onIssue,
    &entryRepo,
    options.batchSize
  );
  scope (failure) {
    entryRepo.clearStagedEntries(root.id);
  }
  ctx.scanDir(root.path, ".");

  if (ctx.pendingBatch.length > 0) {
    ctx.flushBatch();
  }

  if (options.onProgress !is null) {
    SyncProgress p;
    p.phase = SyncPhase.saving;
    p.fileCount = ctx.stats.fileCount;
    p.dirCount = ctx.stats.dirCount;
    p.totalBytes = ctx.stats.totalSize;
    options.onProgress(p);
  }

  const freeSpaceOpt = getDeviceFreeSpace(root.path);
  const ulong freeSpace =
    freeSpaceOpt.isNull ? 0 : cast(ulong) freeSpaceOpt.get;
  const bool hasFreeSpace = !freeSpaceOpt.isNull;

  const syncTimestamp = Clock.currTime.toUnixTime();
  entryRepo.commitStagedSync(
    root.id,
    syncTimestamp,
    freeSpace,
    hasFreeSpace
  );

  return ctx.stats;
}

SyncResult syncRoot(
  ref Database db,
  const ref Root root,
  bool forceHash,
  SyncProgressCallback onProgress = null
) {
  SyncOptions options;
  options.forceHash = forceHash;
  options.onProgress = onProgress;
  return syncRoot(db, root, options);
}

private:

struct ScanDirResult {
  bool success;
  ChildRecord record;
}

struct ScannerContext {
  long rootId;
  string rootName;
  bool forceHash;
  const(CachedFileEntry[string]) cachedMap;
  SyncProgressCallback onProgress;
  SyncIssueCallback onIssue;
  EntryRepository* entryRepo;
  size_t batchSize = 1000;
  Entry[] allEntries;
  Entry[] pendingBatch;
  SyncResult stats;

  void flushBatch() {
    if (pendingBatch.length == 0 || entryRepo is null) {
      return;
    }
    try {
      entryRepo.stageEntriesBatch(rootId, pendingBatch);
      pendingBatch = null;
    } catch (Exception e) {
      recordIssue(rootName, "Batch staging failed: " ~ e.msg, true);
      throw e;
    }
  }

  void recordIssue(string path, string message, bool isDir) {
    SyncIssue issue = SyncIssue(path, message, isDir);
    stats.errors ~= issue;
    if (onIssue !is null) {
      onIssue(issue);
    }
  }

  ScanDirResult scanDir(string diskPath, string relPath) {
    if (onProgress !is null) {
      SyncProgress p;
      p.phase = SyncPhase.scanning;
      p.currentPath = relPath;
      p.fileCount = stats.fileCount;
      p.dirCount = stats.dirCount;
      p.totalBytes = stats.totalSize;
      onProgress(p);
    }

    ChildRecord[] children;

    try {
      foreach (entry; dirEntries(diskPath, SpanMode.shallow)) {
        if (entry.isSymlink) {
          continue;
        }

        const childName = baseName(entry.name);
        const childRelPath = (relPath == ".")
          ? childName
          : relPath ~ "/" ~ childName;

        if (entry.isFile) {
          try {
            children ~= scanFile(entry, relPath, childName);
          } catch (Exception e) {
            recordIssue(entry.name, e.msg, false);
          }
        } else if (entry.isDir) {
          const childRes = scanDir(entry.name, childRelPath);
          if (childRes.success) {
            children ~= childRes.record;
          }
        }
      }
    } catch (Exception e) {
      if (relPath == ".") {
        throw e;
      }
      recordIssue(diskPath, e.msg, true);
      return ScanDirResult(false, ChildRecord.init);
    }

    return ScanDirResult(true, buildDirEntry(diskPath, relPath, children));
  }

  ChildRecord scanFile(
    DirEntry entry,
    string relPath,
    string childName
  ) {
    const childRelPath = (relPath == ".")
      ? childName
      : relPath ~ "/" ~ childName;
    const size = entry.size;
    const mtime = entry.timeLastModified.toUnixTime();
    string fileHash;

    reportFileScan(childRelPath, size);

    if (!forceHash && (childRelPath in cachedMap)) {
      const cached = cachedMap[childRelPath];
      if (cached.size == size && cached.mtime == mtime) {
        fileHash = cached.sha256;
        stats.reusedHashes++;
      } else {
        fileHash = computeFileHash(entry.name, childRelPath, size);
      }
    } else {
      fileHash = computeFileHash(entry.name, childRelPath, size);
    }

    Entry fileEntry;
    fileEntry.rootId = rootId;
    fileEntry.rootName = rootName;
    fileEntry.relPath = childRelPath;
    fileEntry.parentPath = relPath;
    fileEntry.name = childName;
    fileEntry.isDir = false;
    fileEntry.size = size;
    fileEntry.mtime = mtime;
    fileEntry.sha256 = fileHash;

    allEntries ~= fileEntry;
    pendingBatch ~= fileEntry;
    stats.fileCount++;
    stats.totalSize += size;

    if (entryRepo !is null && batchSize > 0
        && pendingBatch.length >= batchSize) {
      flushBatch();
    }

    return ChildRecord(childName, false, fileHash, size);
  }

  void reportFileScan(string childRelPath, ulong size) {
    if (onProgress !is null) {
      SyncProgress p;
      p.phase = SyncPhase.scanning;
      p.currentPath = childRelPath;
      p.fileCount = stats.fileCount;
      p.dirCount = stats.dirCount;
      p.totalBytes = stats.totalSize;
      p.fileBytesTotal = size;
      onProgress(p);
    }
  }

  string computeFileHash(
    string diskPath,
    string childRelPath,
    ulong size
  ) {
    void onChunk(ulong bytesHashed, ulong totalBytes) {
      if (onProgress !is null) {
        SyncProgress p;
        p.phase = SyncPhase.hashing;
        p.currentPath = childRelPath;
        p.fileCount = stats.fileCount;
        p.dirCount = stats.dirCount;
        p.totalBytes = stats.totalSize + bytesHashed;
        p.fileBytesHashed = bytesHashed;
        p.fileBytesTotal = totalBytes;
        onProgress(p);
      }
    }

    if (onProgress !is null) {
      onChunk(0, size);
    }
    return hashFile(diskPath, size, &onChunk);
  }

  ChildRecord buildDirEntry(
    string diskPath,
    string relPath,
    ChildRecord[] children
  ) {
    string dirHash;
    ulong dirSize;
    hashDirectory(children, dirHash, dirSize);

    long dirMtime = 0;
    try {
      dirMtime = timeLastModified(diskPath).toUnixTime();
    } catch (Exception) {
      dirMtime = Clock.currTime.toUnixTime();
    }

    Entry dirEntry;
    dirEntry.rootId = rootId;
    dirEntry.rootName = rootName;
    dirEntry.relPath = relPath;
    dirEntry.name = (relPath == ".") ? "." : baseName(diskPath);
    dirEntry.isDir = true;
    dirEntry.size = dirSize;
    dirEntry.mtime = dirMtime;
    dirEntry.sha256 = dirHash;

    if (relPath != ".") {
      const lastSlash = findLastSlash(relPath);
      dirEntry.parentPath = (lastSlash == -1) ? "." : relPath[0 .. lastSlash];
      stats.dirCount++;
    } else {
      dirEntry.parentPath = null;
      stats.totalSize = dirSize;
    }

    allEntries ~= dirEntry;
    pendingBatch ~= dirEntry;
    if (entryRepo !is null && batchSize > 0
        && pendingBatch.length >= batchSize) {
      flushBatch();
    }
    return ChildRecord(dirEntry.name, true, dirHash, dirSize);
  }
}

ptrdiff_t findLastSlash(string s) {
  for (ptrdiff_t i = cast(ptrdiff_t) s.length - 1; i >= 0; i--) {
    if (s[i] == '/') {
      return i;
    }
  }
  return -1;
}

unittest {
  import d2sqlite3 : Database;
  import orglistremo.db.connection : openDatabase;
  import orglistremo.db.repo : RootRepository;
  import orglistremo.internal.testutil : TempDir;
  import std.file : mkdir, mkdirRecurse, write;

  Database db = openDatabase(":memory:");
  RootRepository rootRepo = RootRepository(db);
  EntryRepository entryRepo = EntryRepository(db);

  // Setup temporary directory structure:
  // temp_fixture/
  //   empty.txt (0 bytes)
  //   data.txt ("abc", 3 bytes)
  //   empty_dir/
  //   nested/
  //     sub.txt ("xyz", 3 bytes)
  TempDir baseTmp = TempDir("sync_base");
  mkdirRecurse(buildPath(baseTmp, "nested"));
  mkdirRecurse(buildPath(baseTmp, "empty_dir"));
  write(buildPath(baseTmp, "empty.txt"), "");
  write(buildPath(baseTmp, "data.txt"), "abc");
  write(buildPath(baseTmp, "nested", "sub.txt"), "xyz");

  const rootId = rootRepo.addRoot("fixture", baseTmp);
  Root root;
  assert(rootRepo.findById(rootId, root));

  // First sync
  SyncResult res1 = syncRoot(db, root, false);
  assert(res1.fileCount == 3);
  assert(res1.dirCount == 2);
  assert(res1.totalSize == 6);
  assert(res1.reusedHashes == 0);

  Root syncedRoot;
  assert(rootRepo.findById(rootId, syncedRoot));
  version (Posix) {
    assert(syncedRoot.hasFreeSpace);
    assert(syncedRoot.freeSpace > 0);
  }

  // Verify empty.txt has hash "0"
  const entries = entryRepo.listEntriesByRootId(rootId);
  bool foundEmptyFile = false;
  bool foundEmptyDir = false;
  foreach (ref e; entries) {
    if (e.relPath == "empty.txt") {
      assert(e.sha256 == "0");
      assert(e.size == 0);
      assert(e.parentPath == ".");
      foundEmptyFile = true;
    }
    if (e.relPath == "empty_dir") {
      assert(e.sha256 == "0");
      assert(e.size == 0);
      assert(e.isDir);
      foundEmptyDir = true;
    }
  }
  assert(foundEmptyFile);
  assert(foundEmptyDir);

  // Second sync with no changes -> hashes should be reused
  SyncResult res2 = syncRoot(db, root, false);
  assert(res2.fileCount == 3);
  assert(res2.reusedHashes == 3);

  // Delete a file and verify stale entry removal
  import std.file : remove;
  remove(buildPath(baseTmp, "empty.txt"));

  SyncResult res3 = syncRoot(db, root, false);
  assert(res3.fileCount == 2);
  const entriesAfterDel = entryRepo.listEntriesByRootId(rootId);
  foreach (ref e; entriesAfterDel) {
    assert(e.relPath != "empty.txt");
  }

  // Test syncRoot with progress callback
  int scanEvents = 0;
  int hashEvents = 0;
  int saveEvents = 0;
  void testProgress(const ref SyncProgress p) {
    if (p.phase == SyncPhase.scanning) {
      scanEvents++;
    } else if (p.phase == SyncPhase.hashing) {
      hashEvents++;
    } else if (p.phase == SyncPhase.saving) {
      saveEvents++;
    }
  }

  SyncResult resProgress = syncRoot(db, root, true, &testProgress);
  assert(resProgress.fileCount == 2);
  assert(scanEvents > 0);
  assert(hashEvents > 0);
  assert(saveEvents == 1);

  // Test empty root path safety check
  TempDir emptyBase = TempDir("sync_empty");

  // 1. Initial sync of empty directory when DB has 0 entries -> succeeds
  const emptyRootId = rootRepo.addRoot("empty_root", emptyBase);
  Root emptyRoot;
  assert(rootRepo.findById(emptyRootId, emptyRoot));
  SyncResult emptyRes = syncRoot(db, emptyRoot, false);
  assert(emptyRes.fileCount == 0);

  // 2. Add an entry to DB so DB is non-empty
  Entry dummyEntry;
  dummyEntry.rootId = emptyRootId;
  dummyEntry.rootName = "empty_root";
  dummyEntry.relPath = "file.txt";
  dummyEntry.name = "file.txt";
  dummyEntry.isDir = false;
  dummyEntry.size = 10;
  dummyEntry.mtime = 1000;
  dummyEntry.sha256 = "dummy";
  entryRepo.saveSyncEntries(emptyRootId, [dummyEntry], 1000);
  assert(entryRepo.hasCatalogedEntries(emptyRootId));

  // 3. Syncing empty directory when DB is not empty -> throws fatal error
  bool threwFatal = false;
  try {
    syncRoot(db, emptyRoot, SyncOptions.init);
  } catch (Exception e) {
    threwFatal = true;
    import std.algorithm.searching : canFind;
    assert(canFind(e.msg, "Fatal error"));
  }
  assert(threwFatal);
  // Verify DB entries were NOT emptied
  assert(entryRepo.hasCatalogedEntries(emptyRootId));

  // 4. Syncing with force = true -> empties database root
  SyncOptions forceOpts;
  forceOpts.force = true;
  SyncResult forcedRes = syncRoot(db, emptyRoot, forceOpts);
  assert(forcedRes.fileCount == 0);
  assert(!entryRepo.hasCatalogedEntries(emptyRootId));

  // Test continuation on unreadable file and directory
  import std.process : execute;
  TempDir permBase = TempDir("sync_perm");
  write(buildPath(permBase, "good.txt"), "hello");
  write(buildPath(permBase, "bad.txt"), "secret");
  const badDir = buildPath(permBase, "bad_dir");
  mkdirRecurse(badDir);
  write(buildPath(badDir, "inner.txt"), "inner");

  execute(["chmod", "000", buildPath(permBase, "bad.txt")]);
  execute(["chmod", "000", badDir]);

  const permRootId = rootRepo.addRoot("perm_root", permBase);
  Root permRoot;
  assert(rootRepo.findById(permRootId, permRoot));

  SyncIssue[] reportedIssues;
  SyncOptions permOpts;
  permOpts.onIssue = (const ref SyncIssue issue) {
    reportedIssues ~= issue;
  };

  SyncResult permRes = syncRoot(db, permRoot, permOpts);
  // good.txt should be synced
  assert(permRes.fileCount == 1);
  // bad.txt and bad_dir should be in errors
  assert(permRes.errors.length == 2);
  assert(reportedIssues.length == 2);

  const permEntries = entryRepo.listEntriesByRootId(permRootId);
  bool foundGood = false;
  bool foundBad = false;
  foreach (ref e; permEntries) {
    if (e.relPath == "good.txt") {
      foundGood = true;
    }
    if (e.relPath == "bad.txt") {
      foundBad = true;
    }
  }
  assert(foundGood);
  assert(!foundBad);

  // Test sync with small batchSize (batchSize = 1)
  SyncOptions batchOpts;
  batchOpts.batchSize = 1;
  SyncResult batchRes = syncRoot(db, root, batchOpts);
  assert(batchRes.fileCount == 2);
  assert(entryRepo.listEntriesByRootId(rootId).length > 0);
}

unittest {
  version (Posix) {
    import std.file : tempDir;

    const freeOpt = getDeviceFreeSpace(tempDir());
    assert(!freeOpt.isNull);
    assert(freeOpt.get > 0);
    assert(getDeviceFreeSpace("/nonexistent_path_987654").isNull);
  }
}

unittest {
  import orglistremo.internal.testutil : TempDir;
  import std.file : FileException, remove, symlink, write;
  import std.process : execute;

  TempDir emptyTestDir = TempDir("chk_empty");

  // 1. Truly empty directory returns true
  assert(isDiskDirEmpty(emptyTestDir.path));

  // 2. Symlink-only directory returns false (BUG-09)
  const string symlinkPath = emptyTestDir.subPath("link_entry");
  symlink("nonexistent_target", symlinkPath);
  assert(!isDiskDirEmpty(emptyTestDir.path));
  remove(symlinkPath);

  // 3. Regular file returns false
  const string filePath = emptyTestDir.subPath("file_entry.txt");
  write(filePath, "data");
  assert(!isDiskDirEmpty(emptyTestDir.path));
  remove(filePath);

  // 4. Permission denied propagates FileException (BUG-09)
  execute(["chmod", "000", emptyTestDir.path]);
  bool threwFileException = false;
  try {
    isDiskDirEmpty(emptyTestDir.path);
  } catch (FileException) {
    threwFileException = true;
  }
  assert(threwFileException);
}
