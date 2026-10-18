module orglistremo.sync.hasher;

import std.algorithm.sorting : sort;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;
import std.stdio : File;

struct ChildRecord {
  string name;
  bool isDir;
  string sha256;
  ulong size;
}

string hashFile(string filePath, ulong fileSize) {
  if (fileSize == 0) {
    return "0";
  }

  auto file = File(filePath, "rb");
  SHA256 sha;
  sha.start();

  foreach (ubyte[] chunk; file.byChunk(1024 * 1024)) {
    sha.put(chunk);
  }

  return sha.finish().toHexString!(LetterCase.lower).idup;
}

void hashDirectory(
  ChildRecord[] children,
  out string outSha256,
  out ulong outTotalSize
) {
  if (children.length == 0) {
    outSha256 = "0";
    outTotalSize = 0;
    return;
  }

  // Sort children deterministically by name in lexicographical UTF-8 byte order
  children.sort!((a, b) => a.name < b.name);

  ulong totalSize = 0;
  SHA256 sha;
  sha.start();

  foreach (ref child; children) {
    totalSize += child.size;
    const typeTag = child.isDir ? "D" : "F";
    const line = typeTag ~ ":" ~ child.name ~ ":" ~ child.sha256 ~ "\n";
    sha.put(cast(const(ubyte)[]) line);
  }

  outTotalSize = totalSize;
  outSha256 = sha.finish().toHexString!(LetterCase.lower).idup;
}

unittest {
  import std.file : exists, remove, tempDir, write;
  import std.path : buildPath;

  // Test empty file
  const emptyHash = hashFile("/dev/null", 0);
  assert(emptyHash == "0");

  // Test non-empty file
  const tmpFile = buildPath(tempDir(), "listremo_hasher_test.txt");
  scope (exit) {
    if (exists(tmpFile)) {
      remove(tmpFile);
    }
  }
  write(tmpFile, "hello listremo\n");
  const computedHash = hashFile(tmpFile, 15);
  // SHA-256 of "hello listremo\n" is known
  assert(computedHash.length == 64);

  // Test empty directory
  ChildRecord[] emptyChildren;
  string dirHash;
  ulong dirSize;
  hashDirectory(emptyChildren, dirHash, dirSize);
  assert(dirHash == "0");
  assert(dirSize == 0);

  // Test deterministic directory hashing regardless of initial child order
  ChildRecord[] c1 = [
    ChildRecord("b.txt", false, "hash_b", 20),
    ChildRecord("a.txt", false, "hash_a", 10),
    ChildRecord("sub", true, "hash_sub", 50)
  ];
  ChildRecord[] c2 = [
    ChildRecord("sub", true, "hash_sub", 50),
    ChildRecord("a.txt", false, "hash_a", 10),
    ChildRecord("b.txt", false, "hash_b", 20)
  ];

  string h1, h2;
  ulong s1, s2;
  hashDirectory(c1, h1, s1);
  hashDirectory(c2, h2, s2);

  assert(h1 == h2);
  assert(s1 == 80);
  assert(s2 == 80);
  assert(h1.length == 64);
}
