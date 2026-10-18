module orglistremo.config;

import std.file : exists, isDir, mkdirRecurse;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;

string resolveDbPath(string cliDb = null) {
  if (cliDb.length > 0) {
    return cliDb;
  }
  const envDb = environment.get("LISTREMO_DB", null);
  if (envDb.length > 0) {
    return envDb;
  }
  const xdgData = environment.get("XDG_DATA_HOME", null);
  if (xdgData.length > 0) {
    return buildPath(xdgData, "listremo", "listremo.db");
  }
  return buildPath(expandTilde("~/.local/share"), "listremo", "listremo.db");
}

void ensureDbDirectory(string dbPath) {
  if (dbPath == ":memory:") {
    return;
  }
  const dir = dirName(dbPath);
  if (dir.length > 0 && !exists(dir)) {
    mkdirRecurse(dir);
  }
}

unittest {
  // Test CLI override precedence
  assert(resolveDbPath("/custom/path.db") == "/custom/path.db");

  // In-memory does not create directories
  ensureDbDirectory(":memory:");
}
