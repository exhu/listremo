module orglistremo.model;

import std.string : strip;

enum emptyHash = "0";

enum EntryType {
  all,
  file,
  dir
}

enum SortField {
  path,
  size,
  mtime
}

enum OutputFormat {
  console,
  csv,
  html
}

enum ColorMode {
  autoMode,
  always,
  never
}

struct Root {
  long id;
  string name;
  string path;
  long createdAt;
  long lastSync;
  bool hasLastSync;
  ulong freeSpace = 0;
  bool hasFreeSpace = false;
}

struct RootSummary {
  Root root;
  ulong fileCount;
  ulong dirCount;
  ulong totalSize;
}

struct Entry {
  string fullPath() const {
    if (rootName.length == 0) {
      return relPath == "." ? "/" : relPath;
    }
    if (relPath == "." || relPath.length == 0) {
      return rootName ~ ":/";
    }
    return rootName ~ ":/" ~ relPath;
  }

  long id;
  long rootId;
  string rootName;
  string relPath;
  string parentPath;
  string name;
  bool isDir;
  ulong size;
  long mtime;
  string sha256 = emptyHash;
}

struct EntryParams {
  long id = 0;
  long rootId = 0;
  string rootName = null;
  string relPath = ".";
  bool isDir = false;
  ulong size = 0;
  long mtime = 0;
  string sha256 = emptyHash;
}

void deriveEntryPath(
  string relPath,
  out string parentPath,
  out string name
) {
  if (relPath == "." || relPath.length == 0) {
    name = ".";
    parentPath = null;
    return;
  }
  import std.string : lastIndexOf;
  const slashIdx = relPath.lastIndexOf('/');
  if (slashIdx == -1) {
    name = relPath;
    parentPath = ".";
  } else {
    name = relPath[slashIdx + 1 .. $];
    parentPath = relPath[0 .. slashIdx];
  }
}

Entry makeEntry(in EntryParams params) {
  Entry e;
  e.id = params.id;
  e.rootId = params.rootId;
  e.rootName = params.rootName;
  e.relPath = params.relPath;
  deriveEntryPath(params.relPath, e.parentPath, e.name);
  e.isDir = params.isDir;
  e.size = params.size;
  e.mtime = params.mtime;
  e.sha256 = params.sha256;
  return e;
}

Entry makeEntry(
  string relPath,
  bool isDir = false,
  ulong size = 0
) {
  EntryParams params;
  params.relPath = relPath;
  params.isDir = isDir;
  params.size = size;
  return makeEntry(params);
}

Entry makeEntry(
  long rootId,
  string rootName,
  string relPath
) {
  EntryParams params;
  params.rootId = rootId;
  params.rootName = rootName;
  params.relPath = relPath;
  return makeEntry(params);
}

struct EntryStats {
  size_t fileCount = 0;
  size_t dirCount = 0;
  ulong totalSize = 0;
}

EntryStats countEntries(in Entry[] entries) {
  EntryStats stats;
  foreach (ref e; entries) {
    if (e.isDir) {
      stats.dirCount++;
    } else {
      stats.fileCount++;
      stats.totalSize += e.size;
    }
  }
  return stats;
}

struct DuplicateStats {
  size_t groupCount = 0;
  size_t duplicateCopies = 0;
  ulong duplicateBytes = 0;
}

DuplicateStats summarizeDuplicates(in DuplicateGroup[] groups) {
  DuplicateStats stats;
  stats.groupCount = groups.length;
  foreach (ref g; groups) {
    const copies = g.entries.length;
    if (copies > 1) {
      stats.duplicateCopies += (copies - 1);
      stats.duplicateBytes += (copies - 1) * g.size;
    }
  }
  return stats;
}

struct TargetSpec {
  static TargetSpec parse(string spec, bool useGlob = false) {
    TargetSpec result;
    const trimmed = spec.strip();
    if (trimmed.length == 0) {
      result.rootName = useGlob ? "*" : "%";
      result.hasSubpath = false;
      return result;
    }

    import std.string : indexOf;
    const colonIdx = trimmed.indexOf(':');
    if (colonIdx == -1) {
      result.rootName = trimmed;
      result.hasSubpath = false;
      return result;
    }

    const rName = trimmed[0 .. colonIdx].strip();
    result.rootName = rName.length > 0 ? rName : (useGlob ? "*" : "%");
    string sub = trimmed[colonIdx + 1 .. $];
    while (sub.length > 0 && sub[0] == '/') {
      sub = sub[1 .. $];
    }
    while (sub.length > 0 && sub[$ - 1] == '/') {
      sub = sub[0 .. $ - 1];
    }

    if (sub.length == 0 || sub == ".") {
      result.subpath = "";
      result.hasSubpath = false;
    } else {
      result.subpath = sub;
      result.hasSubpath = true;
    }
    return result;
  }

  string rootName;
  string subpath;
  bool hasSubpath;
}

struct DuplicateGroup {
  string sha256;
  ulong size;
  bool isDir;
  Entry[] entries;
}

DuplicateGroup[] groupDuplicates(in Entry[] entries) {
  DuplicateGroup[] groups;
  if (entries.length == 0) {
    return groups;
  }

  void startNewGroup(ref DuplicateGroup group, in Entry e) {
    group = DuplicateGroup();
    group.sha256 = e.sha256;
    group.size = e.size;
    group.isDir = e.isDir;
    group.entries ~= e;
  }

  DuplicateGroup currentGroup;
  startNewGroup(currentGroup, entries[0]);

  foreach (i; 1 .. entries.length) {
    if (entries[i].sha256 == currentGroup.sha256 &&
        entries[i].isDir == currentGroup.isDir) {
      currentGroup.entries ~= entries[i];
    } else {
      groups ~= currentGroup;
      startNewGroup(currentGroup, entries[i]);
    }
  }
  groups ~= currentGroup;
  return groups;
}

unittest {
  // Test TargetSpec parsing
  const tEmptyLike = TargetSpec.parse("");
  assert(tEmptyLike.rootName == "%");
  assert(!tEmptyLike.hasSubpath);

  const tEmptyGlob = TargetSpec.parse("", true);
  assert(tEmptyGlob.rootName == "*");
  assert(!tEmptyGlob.hasSubpath);

  const t1 = TargetSpec.parse("backup");
  assert(t1.rootName == "backup");
  assert(!t1.hasSubpath);
  assert(t1.subpath == "");

  const t2 = TargetSpec.parse("backup:/");
  assert(t2.rootName == "backup");
  assert(!t2.hasSubpath);

  const t3 = TargetSpec.parse("backup:");
  assert(t3.rootName == "backup");
  assert(!t3.hasSubpath);

  const t4 = TargetSpec.parse("backup:/photos/2025/");
  assert(t4.rootName == "backup");
  assert(t4.hasSubpath);
  assert(t4.subpath == "photos/2025");

  const t5 = TargetSpec.parse("backup:photos/file.txt");
  assert(t5.rootName == "backup");
  assert(t5.hasSubpath);
  assert(t5.subpath == "photos/file.txt");

  const t6 = TargetSpec.parse(":");
  assert(t6.rootName == "%");
  assert(!t6.hasSubpath);

  const t6Glob = TargetSpec.parse(":", true);
  assert(t6Glob.rootName == "*");
  assert(!t6Glob.hasSubpath);

  const t7 = TargetSpec.parse(":/photos/%");
  assert(t7.rootName == "%");
  assert(t7.hasSubpath);
  assert(t7.subpath == "photos/%");

  const t7Glob = TargetSpec.parse(":/photos/*", true);
  assert(t7Glob.rootName == "*");
  assert(t7Glob.hasSubpath);
  assert(t7Glob.subpath == "photos/*");

  const t8 = TargetSpec.parse(":photos/100\\%done");
  assert(t8.rootName == "%");
  assert(t8.hasSubpath);
  assert(t8.subpath == "photos/100\\%done");

  // Test makeEntry & deriveEntryPath
  const eRoot = makeEntry(".");
  assert(eRoot.name == ".");
  assert(eRoot.parentPath is null);

  const eTop = makeEntry("test.txt", false, 100);
  assert(eTop.name == "test.txt");
  assert(eTop.parentPath == ".");
  assert(eTop.size == 100);

  const eSub = makeEntry(1, "r1", "docs/sub/readme.md");
  assert(eSub.rootId == 1);
  assert(eSub.rootName == "r1");
  assert(eSub.name == "readme.md");
  assert(eSub.parentPath == "docs/sub");

  // Test fullPath formatting
  Entry e;
  e.rootName = "drive1";
  e.relPath = ".";
  assert(e.fullPath() == "drive1:/");

  e.relPath = "docs/readme.txt";
  assert(e.fullPath() == "drive1:/docs/readme.txt");

  // Test countEntries
  Entry[] entries;
  entries ~= makeEntry("f1.txt", false, 100);
  entries ~= makeEntry("f2.txt", false, 250);
  entries ~= makeEntry("dir1", true, 0);
  const stats = countEntries(entries);
  assert(stats.fileCount == 2);
  assert(stats.dirCount == 1);
  assert(stats.totalSize == 350);

  // Test groupDuplicates & summarizeDuplicates
  Entry e1 = makeEntry("f1.txt", false, 100);
  e1.sha256 = "abc";
  Entry e2 = makeEntry("f2.txt", false, 100);
  e2.sha256 = "abc";
  Entry e3 = makeEntry("f3.txt", false, 200);
  e3.sha256 = "def";

  const groups = groupDuplicates([e1, e2, e3]);
  assert(groups.length == 2);
  assert(groups[0].entries.length == 2);
  assert(groups[1].entries.length == 1);

  const dupStats = summarizeDuplicates(groups);
  assert(dupStats.groupCount == 2);
  assert(dupStats.duplicateCopies == 1);
  assert(dupStats.duplicateBytes == 100);
}
