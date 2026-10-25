module orglistremo.sync.scanner;

import d2sqlite3 : Database;
import orglistremo.db.repo :
  CachedFileEntry, EntryRepository, RootRepository, SyncSaveParams;
import orglistremo.internal.os : getDeviceFreeSpace;
import orglistremo.model : deriveEntryPath, emptyHash, Entry, Root;
import orglistremo.pattern : matchesIgnoreList;
import orglistremo.sync.hasher :
  ChildRecord, DirectoryHashResult, hashDirectory, hashFile;
import orglistremo.sync.progress :
  SyncIssue, SyncIssueCallback, SyncPhase, SyncProgress, SyncProgressCallback;
import std.datetime.systime : Clock;
import std.file :
  dirEntries, DirEntry, exists, isDir, isFile, isSymlink, SpanMode,
  timeLastModified;
import std.path : baseName;

struct SyncResult {
  ulong fileCount;
  ulong dirCount;
  ulong totalSize;
  ulong reusedHashes;
  string[] syncedPaths;
  string[] ignoredPaths;
  SyncIssue[] errors;
}

struct SyncOptions {
  bool force;
  bool forceHash;
  bool dryRun;
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
  auto entryRepo = EntryRepository(db);
  validateSyncPreconditions(entryRepo, root, options.force);

  const cachedMap = entryRepo.getFileEntriesMap(root.id);
  const cachedDirMtimes = options.dryRun
    ? entryRepo.getDirMtimesMap(root.id)
    : null;
  const ignorePatterns = RootRepository(db).listIgnorePatterns(root.id);
  ScannerContext ctx = ScannerContext(
    root.id,
    root.name,
    options.forceHash,
    options.dryRun,
    options.batchSize,
    cachedMap,
    cachedDirMtimes,
    ignorePatterns,
    options.onProgress,
    options.onIssue,
    &entryRepo
  );
  scope (failure) {
    if (!options.dryRun) {
      entryRepo.clearStagedEntries(root.id);
    }
  }

  ctx.scanDir(root.path, ".");
  if (!options.dryRun) {
    finalizeSync(ctx, entryRepo, root);
  }
  sortResultPaths(ctx.stats);
  return ctx.stats;
}

private:

void finalizeSync(
  ref ScannerContext ctx,
  ref EntryRepository entryRepo,
  const ref Root root
) {
  if (ctx.pendingBatch.length > 0) {
    ctx.flushBatch();
  }
  if (ctx.onProgress !is null) {
    const SyncProgress p = ctx.makeProgress(SyncPhase.saving, "");
    ctx.onProgress(p);
  }
  commitRootSync(entryRepo, root);
}

void sortResultPaths(ref SyncResult stats) {
  import std.algorithm.sorting : sort;

  if (stats.syncedPaths.length > 1) {
    stats.syncedPaths.sort();
  }
  if (stats.ignoredPaths.length > 1) {
    stats.ignoredPaths.sort();
  }
}

void validateSyncPreconditions(
  ref EntryRepository entryRepo,
  const ref Root root,
  bool force
) {
  import std.format : format;

  if (!exists(root.path) || !isDir(root.path)) {
    throw new Exception(
      format("Root path does not exist or is not a directory: %s", root.path)
    );
  }

  if (!force && isDiskDirEmpty(root.path)
      && entryRepo.hasCatalogedEntries(root.id)) {
    throw new Exception(
      format(
        "Fatal error: Root path '%s' is empty while database is not. " ~
        "Use --force to continue (and empty database root).",
        root.path
      )
    );
  }
}

void commitRootSync(ref EntryRepository entryRepo, const ref Root root) {
  const freeSpaceOpt = getDeviceFreeSpace(root.path);
  const ulong freeSpace =
    freeSpaceOpt.isNull ? 0 : cast(ulong) freeSpaceOpt.get;
  const bool hasFreeSpace = !freeSpaceOpt.isNull;
  const long syncTimestamp = Clock.currTime.toUnixTime();

  entryRepo.commitStagedSync(
    SyncSaveParams(root.id, syncTimestamp, freeSpace, hasFreeSpace)
  );
}

struct ScanDirResult {
  bool success;
  ChildRecord record;
}

struct ScannerContext {
  invariant {
    assert(entryRepo !is null);
  }

  static string joinRelPath(string parentRelPath, string childName) {
    return (parentRelPath == ".")
      ? childName
      : parentRelPath ~ "/" ~ childName;
  }

  SyncProgress makeProgress(SyncPhase phase, string currentPath) const {
    SyncProgress p;
    p.phase = phase;
    p.currentPath = currentPath;
    p.fileCount = stats.fileCount;
    p.dirCount = stats.dirCount;
    p.totalBytes = stats.totalSize;
    return p;
  }

  void appendEntry(in Entry entry) {
    if (dryRun) {
      return;
    }
    pendingBatch ~= entry;
    if (batchSize > 0 && pendingBatch.length >= batchSize) {
      flushBatch();
    }
  }

  void flushBatch() {
    if (pendingBatch.length == 0) {
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
    const SyncIssue issue = SyncIssue(path, message, isDir);
    stats.errors ~= issue;
    if (onIssue !is null) {
      onIssue(issue);
    }
  }

  ScanDirResult scanDir(string diskPath, string relPath) {
    if (onProgress !is null) {
      const SyncProgress p = makeProgress(SyncPhase.scanning, relPath);
      onProgress(p);
    }

    ChildRecord[] children;
    try {
      foreach (entry; dirEntries(diskPath, SpanMode.shallow)) {
        scanDirEntry(entry, relPath, children);
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

  void scanDirEntry(
    DirEntry entry,
    string relPath,
    ref ChildRecord[] children
  ) {
    if (entry.isSymlink) {
      return;
    }

    const string childName = baseName(entry.name);
    const string childRelPath = joinRelPath(relPath, childName);
    const bool isDirectory = entry.isDir;

    if (matchesIgnoreList(childRelPath, isDirectory, ignorePatterns)) {
      stats.ignoredPaths ~= isDirectory ? (childRelPath ~ "/") : childRelPath;
      return;
    }

    if (entry.isFile) {
      try {
        children ~= scanFile(entry, relPath, childName);
      } catch (Exception e) {
        recordIssue(entry.name, e.msg, false);
      }
    } else if (isDirectory) {
      const ScanDirResult childRes = scanDir(entry.name, childRelPath);
      if (childRes.success) {
        children ~= childRes.record;
      }
    }
  }

  ChildRecord scanFile(
    DirEntry entry,
    string relPath,
    string childName
  ) {
    const string childRelPath = joinRelPath(relPath, childName);
    const ulong size = entry.size;
    const long mtime = entry.timeLastModified.toUnixTime();

    reportFileScan(childRelPath, size);
    const string fileHash = resolveFileHash(
      entry.name, childRelPath, FileMeta(size, mtime)
    );

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

    stats.fileCount++;
    stats.totalSize += size;
    appendEntry(fileEntry);

    return ChildRecord(childName, false, fileHash, size);
  }

  string resolveFileHash(
    string diskPath,
    string childRelPath,
    FileMeta meta
  ) {
    if (!forceHash) {
      if (const cached = childRelPath in cachedMap) {
        if (cached.size == meta.size && cached.mtime == meta.mtime) {
          stats.reusedHashes++;
          return cached.sha256;
        }
      }
    }
    if (dryRun) {
      stats.syncedPaths ~= childRelPath;
      return emptyHash;
    }
    return computeFileHash(diskPath, childRelPath, meta.size);
  }

  void reportFileScan(string childRelPath, ulong size) {
    if (onProgress !is null) {
      SyncProgress p = makeProgress(SyncPhase.scanning, childRelPath);
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
        SyncProgress p = makeProgress(SyncPhase.hashing, childRelPath);
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

  void recordDryRunDir(string relPath, long dirMtime) {
    if (!dryRun) {
      return;
    }
    if (!forceHash) {
      if (const cachedMtime = relPath in cachedDirMtimes) {
        if (*cachedMtime == dirMtime) {
          return;
        }
      }
    }
    stats.syncedPaths ~= relPath ~ "/";
  }

  ChildRecord buildDirEntry(
    string diskPath,
    string relPath,
    ChildRecord[] children
  ) {
    const DirectoryHashResult hashRes = dryRun
      ? sumDirChildren(children)
      : hashDirectory(children);
    const long dirMtime = readDirMtime(diskPath);

    Entry dirEntry;
    dirEntry.rootId = rootId;
    dirEntry.rootName = rootName;
    dirEntry.relPath = relPath;
    deriveEntryPath(relPath, dirEntry.parentPath, dirEntry.name);
    dirEntry.isDir = true;
    dirEntry.size = hashRes.totalSize;
    dirEntry.mtime = dirMtime;
    dirEntry.sha256 = hashRes.sha256;

    if (relPath != ".") {
      stats.dirCount++;
      recordDryRunDir(relPath, dirMtime);
    }

    appendEntry(dirEntry);
    return ChildRecord(dirEntry.name, true, hashRes.sha256, hashRes.totalSize);
  }

  const long rootId;
  const string rootName;
  const bool forceHash;
  const bool dryRun;
  const size_t batchSize;
  const(CachedFileEntry[string]) cachedMap;
  const(long[string]) cachedDirMtimes;
  const(string)[] ignorePatterns;
  SyncProgressCallback onProgress;
  SyncIssueCallback onIssue;
  EntryRepository* entryRepo;
  Entry[] pendingBatch;
  SyncResult stats;
}

DirectoryHashResult sumDirChildren(in ChildRecord[] children) {
  ulong totalSize = 0;
  foreach (ref const child; children) {
    totalSize += child.size;
  }
  return DirectoryHashResult(emptyHash, totalSize);
}

struct FileMeta {
  ulong size;
  long mtime;
}

long readDirMtime(string diskPath) {
  try {
    return timeLastModified(diskPath).toUnixTime();
  } catch (Exception) {
    return Clock.currTime.toUnixTime();
  }
}

unittest {
  import d2sqlite3 : Database;
  import orglistremo.db.connection : openDatabase;
  import orglistremo.db.repo : RootRepository;
  import orglistremo.internal.testutil : TempDir;
  import std.file : mkdirRecurse, remove, write;
  import std.path : buildPath;

  Database db = openDatabase(":memory:");
  RootRepository rootRepo = RootRepository(db);
  EntryRepository entryRepo = EntryRepository(db);

  TempDir baseTmp = TempDir("sync_base");
  mkdirRecurse(buildPath(baseTmp, "nested"));
  mkdirRecurse(buildPath(baseTmp, "empty_dir"));
  write(buildPath(baseTmp, "empty.txt"), "");
  write(buildPath(baseTmp, "data.txt"), "abc");
  write(buildPath(baseTmp, "nested", "sub.txt"), "xyz");

  const long rootId = rootRepo.addRoot("fixture", baseTmp);
  Root root;
  assert(rootRepo.findById(rootId, root));

  // First sync
  const SyncResult res1 = syncRoot(db, root);
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
  const Entry[] entries = entryRepo.listEntriesByRootId(rootId);
  bool foundEmptyFile = false;
  bool foundEmptyDir = false;
  foreach (ref const e; entries) {
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
  const SyncResult res2 = syncRoot(db, root);
  assert(res2.fileCount == 3);
  assert(res2.reusedHashes == 3);

  // Delete a file and verify stale entry removal
  remove(buildPath(baseTmp, "empty.txt"));

  const SyncResult res3 = syncRoot(db, root);
  assert(res3.fileCount == 2);
  const Entry[] entriesAfterDel = entryRepo.listEntriesByRootId(rootId);
  foreach (ref const e; entriesAfterDel) {
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

  SyncOptions progOpts;
  progOpts.forceHash = true;
  progOpts.onProgress = &testProgress;
  const SyncResult resProgress = syncRoot(db, root, progOpts);
  assert(resProgress.fileCount == 2);
  assert(scanEvents > 0);
  assert(hashEvents > 0);
  assert(saveEvents == 1);

  // Test empty root path safety check
  TempDir emptyBase = TempDir("sync_empty");

  // 1. Initial sync of empty directory when DB has 0 entries -> succeeds
  const long emptyRootId = rootRepo.addRoot("empty_root", emptyBase);
  Root emptyRoot;
  assert(rootRepo.findById(emptyRootId, emptyRoot));
  const SyncResult emptyRes = syncRoot(db, emptyRoot);
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
  assert(entryRepo.hasCatalogedEntries(emptyRootId));

  // 4. Syncing with force = true -> empties database root
  SyncOptions forceOpts;
  forceOpts.force = true;
  const SyncResult forcedRes = syncRoot(db, emptyRoot, forceOpts);
  assert(forcedRes.fileCount == 0);
  assert(!entryRepo.hasCatalogedEntries(emptyRootId));

  // Test continuation on unreadable file and directory
  import std.process : execute;
  TempDir permBase = TempDir("sync_perm");
  write(buildPath(permBase, "good.txt"), "hello");
  write(buildPath(permBase, "bad.txt"), "secret");
  const string badDir = buildPath(permBase, "bad_dir");
  mkdirRecurse(badDir);
  write(buildPath(badDir, "inner.txt"), "inner");

  execute(["chmod", "000", buildPath(permBase, "bad.txt")]);
  execute(["chmod", "000", badDir]);

  const long permRootId = rootRepo.addRoot("perm_root", permBase);
  Root permRoot;
  assert(rootRepo.findById(permRootId, permRoot));

  SyncIssue[] reportedIssues;
  SyncOptions permOpts;
  permOpts.onIssue = (const ref SyncIssue issue) {
    reportedIssues ~= issue;
  };

  const SyncResult permRes = syncRoot(db, permRoot, permOpts);
  assert(permRes.fileCount == 1);
  assert(permRes.errors.length == 2);
  assert(reportedIssues.length == 2);

  const Entry[] permEntries = entryRepo.listEntriesByRootId(permRootId);
  bool foundGood = false;
  bool foundBad = false;
  foreach (ref const e; permEntries) {
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
  const SyncResult batchRes = syncRoot(db, root, batchOpts);
  assert(batchRes.fileCount == 2);
  assert(entryRepo.listEntriesByRootId(rootId).length > 0);

  // Test sync with per-root ignore patterns (files and directories)
  TempDir ignoreBase = TempDir("sync_ignore");
  mkdirRecurse(buildPath(ignoreBase, "ignored_dir", "sub"));
  mkdirRecurse(buildPath(ignoreBase, "kept_dir"));
  write(buildPath(ignoreBase, "abc.d"), "code");
  write(buildPath(ignoreBase, "abc.d~"), "backup");
  write(buildPath(ignoreBase, "ignored_dir", "inside.txt"), "skip");
  write(buildPath(ignoreBase, "ignored_dir", "sub", "deep.d~"), "skip2");
  write(buildPath(ignoreBase, "kept_dir", "keep.txt"), "keep");
  write(buildPath(ignoreBase, "kept_dir", "temp.d~"), "skip3");

  const long igRootId = rootRepo.addRoot("MYROOT", ignoreBase);
  rootRepo.addIgnorePatterns(igRootId, ["*~", "ignored_dir"]);
  Root igRoot;
  assert(rootRepo.findById(igRootId, igRoot));

  const SyncResult igRes = syncRoot(db, igRoot);
  assert(igRes.fileCount == 2); // abc.d and kept_dir/keep.txt
  assert(igRes.dirCount == 1);  // kept_dir
  assert(
    igRes.ignoredPaths == ["abc.d~", "ignored_dir/", "kept_dir/temp.d~"]
  );

  const Entry[] igEntries = entryRepo.listEntriesByRootId(igRootId);
  string[] relPaths;
  foreach (ref const e; igEntries) {
    if (e.relPath != ".") {
      relPaths ~= e.relPath;
    }
  }
  assert(relPaths == ["abc.d", "kept_dir", "kept_dir/keep.txt"]);

  // Test dryRun mode: no DB modifications, no hashing, reports synced & ignored
  TempDir dryBase = TempDir("sync_dry");
  mkdirRecurse(buildPath(dryBase, "dir_a"));
  mkdirRecurse(buildPath(dryBase, "skip_dir"));
  write(buildPath(dryBase, "f1.txt"), "hello");
  write(buildPath(dryBase, "f1.txt~"), "ignored");
  write(buildPath(dryBase, "dir_a", "f2.txt"), "world");

  const long dryRootId = rootRepo.addRoot("DRYROOT", dryBase);
  rootRepo.addIgnorePatterns(dryRootId, ["*~", "skip_dir"]);
  Root dryRoot;
  assert(rootRepo.findById(dryRootId, dryRoot));

  int dryHashEvents = 0;
  int drySaveEvents = 0;
  SyncOptions dryOpts;
  dryOpts.dryRun = true;
  dryOpts.onProgress = (const ref SyncProgress p) {
    if (p.phase == SyncPhase.hashing) {
      dryHashEvents++;
    } else if (p.phase == SyncPhase.saving) {
      drySaveEvents++;
    }
  };

  // 1. Dry-run on unsynced root: all non-ignored paths listed, DB untouched
  const SyncResult dryRes1 = syncRoot(db, dryRoot, dryOpts);
  assert(dryRes1.fileCount == 2);
  assert(dryRes1.dirCount == 1);
  assert(dryRes1.reusedHashes == 0);
  assert(dryRes1.syncedPaths == ["dir_a/", "dir_a/f2.txt", "f1.txt"]);
  assert(dryRes1.ignoredPaths == ["f1.txt~", "skip_dir/"]);
  assert(dryHashEvents == 0);
  assert(drySaveEvents == 0);
  assert(!entryRepo.hasCatalogedEntries(dryRootId));

  // 2. Real sync populates DB
  const SyncResult realRes = syncRoot(db, dryRoot);
  assert(realRes.fileCount == 2);
  assert(entryRepo.hasCatalogedEntries(dryRootId));

  // 3. Dry-run when nothing changed: syncedPaths is empty, 2 reused hashes
  const SyncResult dryRes2 = syncRoot(db, dryRoot, dryOpts);
  assert(dryRes2.fileCount == 2);
  assert(dryRes2.reusedHashes == 2);
  assert(dryRes2.syncedPaths.length == 0);
  assert(dryRes2.ignoredPaths == ["f1.txt~", "skip_dir/"]);

  // 4. Modify a file and add a new dir + file -> dry-run reports only changes
  write(buildPath(dryBase, "f1.txt"), "hello modified content");
  mkdirRecurse(buildPath(dryBase, "dir_b"));
  write(buildPath(dryBase, "dir_b", "f3.txt"), "new");

  const SyncResult dryRes3 = syncRoot(db, dryRoot, dryOpts);
  assert(dryRes3.fileCount == 3);
  assert(dryRes3.dirCount == 2);
  assert(dryRes3.reusedHashes == 1); // dir_a/f2.txt reused
  assert(dryRes3.syncedPaths == ["dir_b/", "dir_b/f3.txt", "f1.txt"]);
  // Verify DB still has only the 2 files from realRes
  assert(entryRepo.getFileEntriesMap(dryRootId).length == 2);
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
