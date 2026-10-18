module orglistremo.sync.scanner;

import d2sqlite3 : Database;
import orglistremo.db.repo : CachedFileEntry, EntryRepository;
import orglistremo.model : Entry, Root;
import orglistremo.sync.hasher : ChildRecord, hashDirectory, hashFile;
import std.datetime.systime : Clock;
import std.file :
  dirEntries, DirEntry, exists, isDir, isFile, isSymlink, SpanMode,
  timeLastModified;
import std.path : baseName, buildPath;

enum SyncPhase {
  scanning,
  hashing,
  saving
}

struct SyncProgress {
  SyncPhase phase;
  string currentPath;
  ulong fileCount;
  ulong dirCount;
  ulong totalBytes;
  ulong fileBytesHashed;
  ulong fileBytesTotal;
}

alias SyncProgressCallback = void delegate(const ref SyncProgress progress);

struct SyncResult {
  ulong fileCount;
  ulong dirCount;
  ulong totalSize;
  ulong reusedHashes;
}

SyncResult syncRoot(
  ref Database db,
  const ref Root root,
  bool forceHash = false,
  SyncProgressCallback onProgress = null
) {
  if (!exists(root.path) || !isDir(root.path)) {
    import std.format : format;
    throw new Exception(
      format("Root path does not exist or is not a directory: %s", root.path)
    );
  }

  auto entryRepo = EntryRepository(db);
  const cachedMap = entryRepo.getFileEntriesMap(root.id);

  ScannerContext ctx = ScannerContext(
    root.id, root.name, forceHash, cachedMap, onProgress
  );
  ctx.scanDir(root.path, ".");

  if (onProgress !is null) {
    SyncProgress p;
    p.phase = SyncPhase.saving;
    p.fileCount = ctx.stats.fileCount;
    p.dirCount = ctx.stats.dirCount;
    p.totalBytes = ctx.stats.totalSize;
    onProgress(p);
  }

  const syncTimestamp = Clock.currTime.toUnixTime();
  entryRepo.saveSyncEntries(root.id, ctx.allEntries, syncTimestamp);

  return ctx.stats;
}

private:

struct ScannerContext {
  long rootId;
  string rootName;
  bool forceHash;
  const(CachedFileEntry[string]) cachedMap;
  SyncProgressCallback onProgress;
  Entry[] allEntries;
  SyncResult stats;

  ChildRecord scanDir(string diskPath, string relPath) {
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

    foreach (entry; dirEntries(diskPath, SpanMode.shallow)) {
      if (entry.isSymlink) {
        continue;
      }

      const childName = baseName(entry.name);
      const childRelPath = (relPath == ".")
        ? childName
        : relPath ~ "/" ~ childName;

      if (entry.isFile) {
        children ~= scanFile(entry, relPath, childName);
      } else if (entry.isDir) {
        children ~= scanDir(entry.name, childRelPath);
      }
    }

    return buildDirEntry(diskPath, relPath, children);
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
    stats.fileCount++;
    stats.totalSize += size;

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

    const dirMtime = timeLastModified(diskPath).toUnixTime();

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
  import std.file : mkdir, mkdirRecurse, rmdirRecurse, tempDir, write;

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
  const baseTmp = buildPath(tempDir(), "listremo_sync_test");
  if (exists(baseTmp)) {
    rmdirRecurse(baseTmp);
  }
  mkdirRecurse(buildPath(baseTmp, "nested"));
  mkdirRecurse(buildPath(baseTmp, "empty_dir"));
  write(buildPath(baseTmp, "empty.txt"), "");
  write(buildPath(baseTmp, "data.txt"), "abc");
  write(buildPath(baseTmp, "nested", "sub.txt"), "xyz");

  scope (exit) {
    if (exists(baseTmp)) {
      rmdirRecurse(baseTmp);
    }
  }

  const rootId = rootRepo.addRoot("fixture", baseTmp);
  Root root;
  assert(rootRepo.findById(rootId, root));

  // First sync
  SyncResult res1 = syncRoot(db, root, false);
  assert(res1.fileCount == 3);
  assert(res1.dirCount == 2);
  assert(res1.totalSize == 6);
  assert(res1.reusedHashes == 0);

  // Verify empty.txt has hash "0"
  const entries = entryRepo.listEntries(rootId);
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
  const entriesAfterDel = entryRepo.listEntries(rootId);
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
}
