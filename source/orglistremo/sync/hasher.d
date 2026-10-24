module orglistremo.sync.hasher;

import orglistremo.model : emptyHash;
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

struct DirectoryHashResult {
  string sha256;
  ulong totalSize;
}

alias HashChunkCallback = void delegate(ulong bytesHashed, ulong totalBytes);

string hashFile(
  string filePath,
  ulong fileSize,
  HashChunkCallback onChunk = null
) {
  if (fileSize == 0) {
    return emptyHash;
  }

  File file = File(filePath, "rb");
  SHA256 sha;
  sha.start();

  ulong bytesHashed = 0;
  foreach (ubyte[] chunk; file.byChunk(1024 * 1024)) {
    sha.put(chunk);
    bytesHashed += chunk.length;
    if (onChunk !is null) {
      onChunk(bytesHashed, fileSize);
    }
  }

  return sha.finish().toHexString!(LetterCase.lower).idup;
}

/**
 * Computes the deterministic SHA-256 hash and total byte size of a directory.
 *
 * Note: Sorts `children` in-place by name in lexicographical UTF-8 byte order.
 */
DirectoryHashResult hashDirectory(ChildRecord[] children) {
  if (children.length == 0) {
    return DirectoryHashResult(emptyHash, 0);
  }

  children.sort!((a, b) => a.name < b.name);

  ulong totalSize = 0;
  SHA256 sha;
  sha.start();

  foreach (ref const child; children) {
    totalSize += child.size;
    const string typeTag = child.isDir ? "D" : "F";
    const string line = typeTag ~ ":" ~ child.name ~ ":" ~ child.sha256 ~ "\n";
    sha.put(cast(const(ubyte)[]) line);
  }

  const string hashHex = sha.finish().toHexString!(LetterCase.lower).idup;
  return DirectoryHashResult(hashHex, totalSize);
}

unittest {
  import orglistremo.internal.testutil : TempDir;
  import std.file : write;

  // Test empty file
  const string zeroHash = hashFile("/dev/null", 0);
  assert(zeroHash == emptyHash);

  // Test non-empty file
  TempDir tempDir = TempDir("hasher");
  const string tmpFile = tempDir.subPath("test.txt");
  write(tmpFile, "hello listremo\n");
  ulong callbackBytesHashed = 0;
  ulong callbackTotalBytes = 0;
  int chunkCallCount = 0;
  void onChunkTest(ulong hashed, ulong total) {
    callbackBytesHashed = hashed;
    callbackTotalBytes = total;
    chunkCallCount++;
  }

  const string computedHash = hashFile(tmpFile, 15, &onChunkTest);
  assert(computedHash.length == 64);
  assert(chunkCallCount == 1);
  assert(callbackBytesHashed == 15);
  assert(callbackTotalBytes == 15);

  // Test empty directory
  ChildRecord[] emptyChildren;
  const DirectoryHashResult emptyRes = hashDirectory(emptyChildren);
  assert(emptyRes.sha256 == emptyHash);
  assert(emptyRes.totalSize == 0);

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

  const DirectoryHashResult res1 = hashDirectory(c1);
  const DirectoryHashResult res2 = hashDirectory(c2);

  assert(res1.sha256 == res2.sha256);
  assert(res1.totalSize == 80);
  assert(res2.totalSize == 80);
  assert(res1.sha256.length == 64);
}
