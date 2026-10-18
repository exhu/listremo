#!/usr/bin/env rdmd
// Checks that D and markdown files do not exceed 80 columns.
module check_line_length;

import std.algorithm.searching : endsWith;
import std.file : dirEntries, exists, isDir, isFile, SpanMode;
import std.path : extension;
import std.stdio : File, stderr, writeln, writefln;
import std.string : stripRight;

int main(string[] args) {
  immutable size_t maxCols = 80;
  size_t violations = 0;

  void checkFile(string filePath) {
    auto f = File(filePath, "r");
    size_t lineNum = 1;
    foreach (line; f.byLine()) {
      const lineStr = line.stripRight("\r\n");
      if (lineStr.length > maxCols) {
        writefln(
          "%s:%d exceeds %d cols (%d)",
          filePath,
          lineNum,
          maxCols,
          lineStr.length
        );
        violations++;
      }
      lineNum++;
    }
  }

  void processPath(string path) {
    if (!exists(path)) {
      return;
    }
    if (isFile(path)) {
      checkFile(path);
    } else if (isDir(path)) {
      foreach (entry; dirEntries(path, SpanMode.depth)) {
        if (!entry.isFile) {
          continue;
        }
        const ext = extension(entry.name);
        if (ext == ".d" || ext == ".md") {
          checkFile(entry.name);
        }
      }
    }
  }

  const targets = (args.length > 1)
    ? args[1 .. $]
    : ["source", "spec/plan1-implementation.md", ".agents/skills"];

  foreach (target; targets) {
    processPath(target);
  }

  if (violations > 0) {
    stderr.writefln("Found %d line length violations.", violations);
    return 1;
  }

  writeln("All checked files adhere to the 80 column limit.");
  return 0;
}
