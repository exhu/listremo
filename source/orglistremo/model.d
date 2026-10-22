module orglistremo.model;

import std.string : strip;

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
  string sha256;
}

struct TargetSpec {
  static TargetSpec parse(string spec) {
    TargetSpec result;
    const trimmed = spec.strip();
    if (trimmed.length == 0) {
      return result;
    }

    const colonIdx = findColon(trimmed);
    if (colonIdx == -1) {
      result.rootName = trimmed;
      result.hasSubpath = false;
      return result;
    }

    const rName = trimmed[0 .. colonIdx].strip();
    result.rootName = rName.length > 0 ? rName : "%";
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

private:
  static ptrdiff_t findColon(string s) {
    foreach (i, c; s) {
      if (c == ':') {
        return i;
      }
    }
    return -1;
  }
}

bool hasPatternWildcard(string s) {
  size_t backslashes = 0;
  foreach (c; s) {
    if (c == '\\') {
      backslashes++;
    } else {
      if (c == '%' && (backslashes % 2 == 0)) {
        return true;
      }
      backslashes = 0;
    }
  }
  return false;
}

string unescapePatternEscapes(string s) {
  string res;
  size_t i = 0;
  while (i < s.length) {
    if (s[i] == '\\' && i + 1 < s.length &&
        (s[i + 1] == '%' || s[i + 1] == '\\')) {
      res ~= s[i + 1];
      i += 2;
    } else {
      res ~= s[i];
      i++;
    }
  }
  return res;
}

struct DuplicateGroup {
  string sha256;
  ulong size;
  bool isDir;
  Entry[] entries;
}

unittest {
  // Test TargetSpec parsing
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

  const t7 = TargetSpec.parse(":/photos/%");
  assert(t7.rootName == "%");
  assert(t7.hasSubpath);
  assert(t7.subpath == "photos/%");

  const t8 = TargetSpec.parse(":photos/100\\%done");
  assert(t8.rootName == "%");
  assert(t8.hasSubpath);
  assert(t8.subpath == "photos/100\\%done");

  // Test hasPatternWildcard
  assert(hasPatternWildcard("%"));
  assert(hasPatternWildcard("abc%"));
  assert(hasPatternWildcard("%def"));
  assert(!hasPatternWildcard("abc"));
  assert(!hasPatternWildcard("abc\\%def"));
  assert(hasPatternWildcard("abc\\\\%def"));
  assert(!hasPatternWildcard("abc\\\\\\%def"));

  // Test unescapePatternEscapes
  assert(unescapePatternEscapes("100\\%done") == "100%done");
  assert(unescapePatternEscapes("path\\\\file") == "path\\file");
  assert(unescapePatternEscapes("normal") == "normal");

  // Test fullPath formatting
  Entry e;
  e.rootName = "drive1";
  e.relPath = ".";
  assert(e.fullPath() == "drive1:/");

  e.relPath = "docs/readme.txt";
  assert(e.fullPath() == "drive1:/docs/readme.txt");
}
