module orglistremo.output.console;

import core.time : dur, Duration, MonoTime;
import orglistremo.internal.os : getTerminalWidth, isStdoutTty, isTty;
import orglistremo.model : DuplicateGroup, Entry, RootSummary;
import orglistremo.output.options :
  ColorMode, OutputFormat, OutputOptions, Styler;
import orglistremo.output.units :
  formatHash, formatLastSync, formatSizeHuman, formatUnixTime;
import orglistremo.sync.progress : SyncPhase, SyncProgress;
import std.format : format;
import std.stdio : File, stdout;

final class ConsoleProgressReporter {
  this(
    in OutputOptions opts,
    uint intervalMs = 1000,
    File stream = stdout
  ) {
    this.styler = opts.styler;
    this.interval = dur!"msecs"(intervalMs);
    this.stream = stream;
    this.isTty = (opts.format == OutputFormat.console)
      && .isTty(stream.fileno);
  }

  void update(const ref SyncProgress progress) {
    if (!isTty) {
      return;
    }
    const MonoTime now = MonoTime.currTime;
    const bool phaseChanged = !hasOutput || (progress.phase != lastPhase);
    if (!phaseChanged && (now - lastUpdateTime) < interval) {
      return;
    }
    lastUpdateTime = now;
    lastPhase = progress.phase;
    hasOutput = true;

    size_t visibleLen;
    const string line = formatProgressLine(progress, visibleLen);
    renderLine(line, visibleLen);
  }

  void clear() {
    if (!isTty || lastVisibleLen == 0) {
      return;
    }
    if (styler.enabled) {
      stream.writef("\r\033[K");
    } else {
      import std.array : replicate;
      stream.writef("\r%s\r", " ".replicate(lastVisibleLen));
    }
    stream.flush();
    lastVisibleLen = 0;
  }

  size_t currentVisibleLength() const {
    return lastVisibleLen;
  }

  package(orglistremo) void enableTtyForTest(bool enabled = true) {
    this.isTty = enabled;
  }

private:
  void renderLine(string line, size_t visibleLen) {
    if (styler.enabled) {
      stream.writef("\r%s\033[K", line);
    } else {
      string spaces = "";
      if (lastVisibleLen > visibleLen) {
        import std.array : replicate;
        spaces = " ".replicate(lastVisibleLen - visibleLen);
      }
      stream.writef("\r%s%s", line, spaces);
    }
    stream.flush();
    lastVisibleLen = visibleLen;
  }

  string formatProgressLine(
    const ref SyncProgress progress,
    out size_t visibleLen
  ) const {
    if (progress.phase == SyncPhase.saving) {
      const string msg = "  Saving database entries...";
      visibleLen = msg.length;
      return styler.enabled ? styler.header(msg) : msg;
    }

    const bool isHash = (progress.phase == SyncPhase.hashing);
    const string tag = isHash ? "[hash]" : "[scan]";
    const string styledTag = isHash ? styler.size(tag) : styler.header(tag);

    const string sizeStr = formatSizeHuman(progress.totalBytes);
    const string unstyledPrefix = format(
      "  %s %d files, %d dirs (%s) | ",
      tag, progress.fileCount, progress.dirCount, sizeStr
    );
    const string styledPrefix = format(
      "  %s %d files, %d dirs (%s) | ",
      styledTag, progress.fileCount, progress.dirCount, sizeStr
    );

    string rawPath = progress.currentPath;
    if (isHash && progress.fileBytesTotal > 0) {
      const int pct = cast(int)(
        (progress.fileBytesHashed * 100) / progress.fileBytesTotal
      );
      rawPath = format("%s (%d%%)", progress.currentPath, pct);
    }

    const uint termWidth = getTerminalWidth(stream.fileno);
    const size_t visiblePrefixLen = unstyledPrefix.length;
    const size_t avail = (termWidth > visiblePrefixLen + 1)
      ? termWidth - visiblePrefixLen - 1
      : 0;
    const string truncatedPath = truncatePathLeft(rawPath, avail);

    visibleLen = visiblePrefixLen + truncatedPath.length;
    return styledPrefix ~ truncatedPath;
  }

  Styler styler;
  Duration interval;
  File stream;
  bool isTty;
  MonoTime lastUpdateTime;
  SyncPhase lastPhase;
  bool hasOutput;
  size_t lastVisibleLen;
}

bool shouldColorize(ColorMode mode) {
  if (mode == ColorMode.always) {
    return true;
  }
  if (mode == ColorMode.never) {
    return false;
  }
  import std.process : environment;

  if (environment.get("NO_COLOR", null) !is null) {
    return false;
  }
  return isStdoutTty();
}

string formatEntryPath(in Entry e, in Styler styler) {
  if (e.rootName.length > 0) {
    const string rootPart = styler.root(e.rootName);
    if (e.isDir) {
      if (e.relPath == "." || e.relPath.length == 0) {
        return rootPart ~ styler.dir(":/");
      }
      return rootPart ~ ":/" ~ styler.dir(e.relPath ~ "/");
    }
    return rootPart ~ ":/" ~ e.relPath;
  }

  if (e.isDir) {
    const string p = (e.relPath == "." || e.relPath.length == 0)
      ? "/"
      : e.relPath ~ "/";
    return styler.dir(p);
  }
  return e.relPath;
}

void printConsoleRoots(
  in RootSummary[] summaries,
  in OutputOptions options,
  File outStream = stdout
) {
  if (summaries.length == 0) {
    outStream.writeln("No storage roots registered.");
    return;
  }

  outStream.writefln(
    "%s %s %s %s %s %s %s",
    options.styler.header(format("%-18s", "NAME")),
    options.styler.header(format("%-25s", "PATH")),
    options.styler.header(format("%-19s", "LAST SYNC")),
    options.styler.header(format("%8s", "FILES")),
    options.styler.header(format("%8s", "DIRS")),
    options.styler.header(format("%12s", "SIZE")),
    options.styler.header(format("%12s", "FREE SPACE"))
  );

  foreach (ref const s; summaries) {
    const string rawSize = formatSizeHuman(s.totalSize);
    const string syncTimeStr = formatLastSync(
      s.root.lastSync, s.root.hasLastSync
    );
    const string freeStr = s.root.hasFreeSpace
      ? formatSizeHuman(s.root.freeSpace)
      : "-";
    outStream.writefln(
      "%s %s %s %s %s %s %s",
      options.styler.root(format("%-18s", s.root.name)),
      format("%-25s", s.root.path),
      options.styler.date(format("%-19s", syncTimeStr)),
      format("%8d", s.fileCount),
      format("%8d", s.dirCount),
      options.styler.size(format("%12s", rawSize)),
      options.styler.size(format("%12s", freeStr))
    );
  }
}

void printConsoleEntries(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  if (entries.length == 0) {
    outStream.writeln("No entries found.");
    return;
  }

  outStream.writefln(
    "%s %s %s %s %s",
    options.styler.header(format("%-4s", "TYPE")),
    options.styler.header(format("%-12s", "SIZE")),
    options.styler.header(format("%-19s", "MODIFIED")),
    options.styler.header(format("%-14s", "SHA256")),
    options.styler.header("PATH")
  );

  foreach (ref const e; entries) {
    const string typeStr = e.isDir ? "DIR" : "FILE";
    const string pathStr = formatEntryPath(e, options.styler);
    const string hStr = formatHash(e.sha256, options.fullHash);
    const string sizeStr = formatSizeHuman(e.size);
    const string mtimeStr = formatUnixTime(e.mtime);

    const string typeCol = e.isDir
      ? options.styler.dir(format("%-4s", typeStr))
      : format("%-4s", typeStr);

    outStream.writefln(
      "%s %s %s %s %s",
      typeCol,
      options.styler.size(format("%-12s", sizeStr)),
      options.styler.date(format("%-19s", mtimeStr)),
      options.styler.hash(format("%-14s", hStr)),
      pathStr
    );
  }
}

void printConsoleDuplicates(
  in DuplicateGroup[] groups,
  in OutputOptions options,
  File outStream = stdout
) {
  if (groups.length == 0) {
    outStream.writeln("No duplicate entries found.");
    return;
  }

  ulong totalDuplicateBytes = 0;
  ulong duplicateCopies = 0;

  foreach (ref const g; groups) {
    const ulong copies = cast(ulong) g.entries.length;
    if (copies > 1) {
      duplicateCopies += (copies - 1);
      totalDuplicateBytes += (copies - 1) * g.size;
    }

    const string typeStr = g.isDir ? "DIR" : "FILE";
    const string hStr = formatHash(g.sha256, options.fullHash);
    const string sizeStr = formatSizeHuman(g.size);

    outStream.writefln(
      "[%s] SHA256: %s | Size: %s (%d copies)",
      g.isDir ? options.styler.dir(typeStr) : typeStr,
      options.styler.hash(hStr),
      options.styler.size(sizeStr),
      copies
    );

    foreach (ref const e; g.entries) {
      const string pathStr = formatEntryPath(e, options.styler);
      outStream.writefln("  -> %s", pathStr);
    }
  }

  outStream.writefln(
    "\nSummary: %d duplicate group(s), %d wasted copies (%s recoverable)",
    groups.length,
    duplicateCopies,
    options.styler.size(formatSizeHuman(totalDuplicateBytes))
  );
}

void printConsoleUnique(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  if (entries.length == 0) {
    outStream.writeln("No unique entries found.");
    return;
  }

  printConsoleEntries(entries, options, outStream);
  outStream.writefln("\nTotal unique entries: %d", entries.length);
}

private:

size_t countCodePoints(string s) {
  size_t count = 0;
  foreach (const char c; s) {
    if ((c & 0xC0) != 0x80) {
      count++;
    }
  }
  return count;
}

size_t findSuffixStart(string s, size_t targetCodePoints) {
  if (targetCodePoints == 0 || s.length == 0) {
    return s.length;
  }
  size_t count = 0;
  size_t i = s.length;
  while (i > 0) {
    i--;
    if ((s[i] & 0xC0) != 0x80) {
      count++;
      if (count == targetCodePoints) {
        return i;
      }
    }
  }
  return 0;
}

string truncatePathLeft(string path, size_t maxLen) {
  if (maxLen == 0) {
    return "";
  }
  if (path.length <= maxLen || countCodePoints(path) <= maxLen) {
    return path;
  }
  if (maxLen <= 3) {
    const size_t start = findSuffixStart(path, maxLen);
    return path[start .. $];
  }
  const size_t start = findSuffixStart(path, maxLen - 3);
  return "..." ~ path[start .. $];
}

unittest {
  import orglistremo.internal.testutil : captureOutput;
  import orglistremo.model : Root;

  Styler styler;
  styler.enabled = false;

  // Test formatEntryPath
  Entry e1 = Entry(1, 1, "r1", "doc.txt", ".", "doc.txt", false, 10, 0, "h");
  assert(formatEntryPath(e1, styler) == "r1:/doc.txt");

  Entry e2 = Entry(2, 1, "r1", "photos", ".", "photos", true, 0, 0, "h");
  assert(formatEntryPath(e2, styler) == "r1:/photos/");

  Entry e3 = Entry(3, 1, "r1", ".", null, ".", true, 0, 0, "h");
  assert(formatEntryPath(e3, styler) == "r1:/");

  // Test styled formatEntryPath
  Styler coloredStyler;
  coloredStyler.enabled = true;
  assert(formatEntryPath(e1, coloredStyler) == "\033[1;35mr1\033[0m:/doc.txt");
  assert(
    formatEntryPath(e2, coloredStyler) ==
    "\033[1;35mr1\033[0m:/\033[1;34mphotos/\033[0m"
  );

  // Test printConsoleRoots without colors
  OutputOptions optsNoColor;
  optsNoColor.styler.enabled = false;

  Root r = Root(1, "main", "/mnt/data", 1000, 2000, true);
  RootSummary[] roots = [RootSummary(r, 10, 2, 2048)];

  const rootsOut = captureOutput((File f) {
    printConsoleRoots(roots, optsNoColor, f);
  });
  import std.string : splitLines;
  const rootLines = rootsOut.splitLines();
  assert(rootLines.length >= 2);
  assert(rootLines[0].length > 0);
  assert(rootLines[1].length > 0);

  // Test printConsoleRoots with colors (verifying alignment not corrupted)
  OutputOptions optsColor;
  optsColor.styler.enabled = true;
  captureOutput((File f) {
    printConsoleRoots(roots, optsColor, f);
  });

  // Test printConsoleEntries (uncolored and colored)
  captureOutput((File f) {
    printConsoleEntries([e1, e2], optsNoColor, f);
  });
  captureOutput((File f) {
    printConsoleEntries([e1, e2], optsColor, f);
  });

  // Test printConsoleDuplicates (uncolored and colored)
  DuplicateGroup dg;
  dg.sha256 = "abc123456789";
  dg.size = 100;
  dg.isDir = false;
  dg.entries = [e1];
  captureOutput((File f) {
    printConsoleDuplicates([dg], optsNoColor, f);
  });
  captureOutput((File f) {
    printConsoleDuplicates([dg], optsColor, f);
  });

  // Test printConsoleUnique (uncolored and colored)
  captureOutput((File f) {
    printConsoleUnique([e1], optsNoColor, f);
  });
  captureOutput((File f) {
    printConsoleUnique([e1], optsColor, f);
  });

  // Test truncatePathLeft
  import std.utf : validate;
  assert(truncatePathLeft("short.txt", 20) == "short.txt");
  assert(truncatePathLeft("abcdefghij", 5) == "...ij");
  assert(truncatePathLeft("abcdefghij", 2) == "ij");
  assert(truncatePathLeft("abcdefghij", 0) == "");

  // Multibyte 2-byte characters (Cyrillic: 9 chars, 18 bytes)
  const string cyrillic = "документы";
  assert(truncatePathLeft(cyrillic, 10) == "документы");
  assert(truncatePathLeft(cyrillic, 5) == "...ты");
  assert(truncatePathLeft(cyrillic, 2) == "ты");
  validate(truncatePathLeft(cyrillic, 5));

  // Multibyte 3-byte characters (CJK: 7 chars, 21 bytes)
  const string japanese = "日本語テキスト";
  assert(truncatePathLeft(japanese, 8) == "日本語テキスト");
  assert(truncatePathLeft(japanese, 5) == "...スト");
  assert(truncatePathLeft(japanese, 2) == "スト");
  validate(truncatePathLeft(japanese, 5));

  // Test ConsoleProgressReporter with enableTtyForTest(true)
  File progOut = File.tmpfile();
  auto reporter = new ConsoleProgressReporter(optsNoColor, 1000, progOut);
  reporter.enableTtyForTest();

  SyncProgress sp1;
  sp1.phase = SyncPhase.scanning;
  sp1.currentPath = "dir/file.txt";
  sp1.fileCount = 5;
  sp1.dirCount = 2;
  sp1.totalBytes = 1024;
  reporter.update(sp1);
  assert(reporter.currentVisibleLength > 0);

  // Immediate update with same phase should be throttled by interval
  const lenAfterFirst = reporter.currentVisibleLength;
  sp1.fileCount = 6;
  reporter.update(sp1);
  assert(reporter.currentVisibleLength == lenAfterFirst);

  // Phase change bypasses throttling
  SyncProgress sp2;
  sp2.phase = SyncPhase.hashing;
  sp2.currentPath = "big.bin";
  sp2.fileCount = 6;
  sp2.dirCount = 2;
  sp2.totalBytes = 2048;
  sp2.fileBytesHashed = 500;
  sp2.fileBytesTotal = 1000;
  reporter.update(sp2);
  assert(reporter.currentVisibleLength > 0);

  // Saving phase
  SyncProgress sp3;
  sp3.phase = SyncPhase.saving;
  reporter.update(sp3);

  // Clear resets visible length to 0
  reporter.clear();
  assert(reporter.currentVisibleLength == 0);

  // Test ConsoleProgressReporter with enableTtyForTest(false) -> does not write
  File nonTtyOut = File.tmpfile();
  auto nonTtyReporter = new ConsoleProgressReporter(
    optsNoColor, 1000, nonTtyOut
  );
  nonTtyReporter.enableTtyForTest(false);
  nonTtyReporter.update(sp1);
  assert(nonTtyReporter.currentVisibleLength == 0);

  // Test ConsoleProgressReporter with optsColor: emits \033[K on line overwrite
  SyncProgress longSp;
  longSp.phase = SyncPhase.hashing;
  longSp.currentPath = "long_path_name.bin";
  longSp.fileCount = 1;
  longSp.dirCount = 0;
  longSp.totalBytes = 1000;
  longSp.fileBytesHashed = 230;
  longSp.fileBytesTotal = 1000;

  SyncProgress shortSp;
  shortSp.phase = SyncPhase.hashing;
  shortSp.currentPath = "short.bin";
  shortSp.fileCount = 1;
  shortSp.dirCount = 0;
  shortSp.totalBytes = 1000;
  shortSp.fileBytesHashed = 230;
  shortSp.fileBytesTotal = 1000;

  const colorProgOut = captureOutput((File f) {
    auto colorReporter = new ConsoleProgressReporter(optsColor, 0, f);
    colorReporter.enableTtyForTest();
    colorReporter.update(longSp);
    colorReporter.update(shortSp);
    colorReporter.clear();
    assert(colorReporter.currentVisibleLength == 0);
  });
  import std.algorithm.searching : canFind;
  assert(canFind(colorProgOut, "\033[K"));

  // Test ConsoleProgressReporter with optsNoColor emits spaces on shorter line
  const noColorProgOut = captureOutput((File f) {
    auto noColorReporter = new ConsoleProgressReporter(optsNoColor, 0, f);
    noColorReporter.enableTtyForTest();
    noColorReporter.update(longSp);
    noColorReporter.update(shortSp);
  });
  assert(canFind(noColorProgOut, "   "));
}
