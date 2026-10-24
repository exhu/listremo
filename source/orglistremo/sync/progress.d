module orglistremo.sync.progress;

import std.format : format;

package(orglistremo):

enum SyncPhase {
  scanning,
  hashing,
  saving
}

struct SyncIssue {
  string describe() const {
    const action = isDir ? "access directory" : "read file";
    return format("Failed to %s '%s': %s", action, path, message);
  }

  string path;
  string message;
  bool isDir;
}

alias SyncIssueCallback = void delegate(const ref SyncIssue issue);

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

unittest {
  const SyncIssue fileIssue = SyncIssue("/tmp/a.txt", "Permission denied",
    false);
  assert(
    fileIssue.describe() ==
    "Failed to read file '/tmp/a.txt': Permission denied"
  );

  const SyncIssue dirIssue = SyncIssue("/tmp/dir", "Access denied", true);
  assert(
    dirIssue.describe() ==
    "Failed to access directory '/tmp/dir': Access denied"
  );
}
