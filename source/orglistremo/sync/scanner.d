module orglistremo.sync.scanner;

import d2sqlite3 : Database;
import orglistremo.db.repo : CachedFileEntry, EntryRepository;
import orglistremo.model : Entry, Root;
import orglistremo.sync.hasher : ChildRecord, hashDirectory, hashFile;
import std.datetime.systime : Clock;
import std.file :
  dirEntries, exists, isDir, isFile, isSymlink, SpanMode, timeLastModified;
import std.path : baseName, buildPath;

struct SyncResult {
  ulong fileCount;
  ulong dirCount;
  ulong totalSize;
  ulong reusedHashes;
}

SyncResult syncRoot(
  ref Database db,
  const ref Root root,
  bool forceHash = false
) {
  if (!exists(root.path) || !isDir(root.path)) {
    import std.format : format;
    throw new Exception(
      format("Root path does not exist or is not a directory: %s", root.path)
    );
  }

  auto entryRepo = EntryRepository(db);
  auto cachedMap = entryRepo.getFileEntriesMap(root.id);

  Entry[] allEntries;
  SyncResult stats;

  ChildRecord scanDirRecursive(string diskPath, string relPath) {
    ChildRecord[] children;

    foreach (entry; dirEntries(diskPath, SpanMode.shallow)) {
      if (entry.isSymlink) {
        continue;
      }

      const childName = baseName(entry.name);
      const childRelPath = (relPath == ".")
        ? childName
        : relPath ~ "/" ~ childName;
      const childParentPath = relPath;

      if (entry.isFile) {
        const size = entry.size;
        const mtime = entry.timeLastModified.toUnixTime();
        string fileHash;

        if (!forceHash && (childRelPath in cachedMap)) {
          const cached = cachedMap[childRelPath];
          if (cached.size == size && cached.mtime == mtime) {
            fileHash = cached.sha256;
            stats.reusedHashes++;
          } else {
            fileHash = hashFile(entry.name, size);
          }
        } else {
          fileHash = hashFile(entry.name, size);
        }

        Entry fileEntry;
        fileEntry.rootId = root.id;
        fileEntry.rootName = root.name;
        fileEntry.relPath = childRelPath;
        fileEntry.parentPath = childParentPath;
        fileEntry.name = childName;
        fileEntry.isDir = false;
        fileEntry.size = size;
        fileEntry.mtime = mtime;
        fileEntry.sha256 = fileHash;

        allEntries ~= fileEntry;
        stats.fileCount++;

        children ~= ChildRecord(childName, false, fileHash, size);
      } else if (entry.isDir) {
        // Post-order bottom-up traversal
        ChildRecord dirChild = scanDirRecursive(entry.name, childRelPath);
        children ~= dirChild;
      }
    }

    // Bottom-up Merkle directory hash & recursive size
    string dirHash;
    ulong dirSize;
    hashDirectory(children, dirHash, dirSize);

    const dirMtime = timeLastModified(diskPath).toUnixTime();

    Entry dirEntry;
    dirEntry.rootId = root.id;
    dirEntry.rootName = root.name;
    dirEntry.relPath = relPath;
    dirEntry.parentPath = (relPath == ".") ? null : relPath;
    dirEntry.name = (relPath == ".") ? "." : baseName(diskPath);
    dirEntry.isDir = true;
    dirEntry.size = dirSize;
    dirEntry.mtime = dirMtime;
    dirEntry.sha256 = dirHash;

    if (relPath != ".") {
      // Find parent path
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

  scanDirRecursive(root.path, ".");

  const syncTimestamp = Clock.currTime.toUnixTime();
  entryRepo.saveSyncEntries(root.id, allEntries, syncTimestamp);

  return stats;
}

private:

ptrdiff_t findLastSlash(string s) {
  for (ptrdiff_t i = cast(ptrdiff_t) s.length - 1; i >= 0; i--) {
    if (s[i] == '/') {
      return i;
    }
  }
  return -1;
}

unittest {
  import orglistremo.db.connection : openDatabase;
  import orglistremo.db.repo : RootRepository;
  import std.file : mkdir, mkdirRecurse, rmdirRecurse, tempDir, write;

  auto db = openDatabase(":memory:");
  auto rootRepo = RootRepository(db);
  auto entryRepo = EntryRepository(db);

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
  auto entries = entryRepo.listEntries(rootId);
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
  auto entriesAfterDel = entryRepo.listEntries(rootId);
  foreach (ref e; entriesAfterDel) {
    assert(e.relPath != "empty.txt");
  }
}
