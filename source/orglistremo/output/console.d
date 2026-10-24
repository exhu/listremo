module orglistremo.output.console;

import core.time : dur, Duration, MonoTime;
import orglistremo.internal.os :
  getTerminalWidth, isStdoutTty, isTty;
import orglistremo.model :
  ColorMode, DuplicateGroup, Entry, OutputFormat, RootSummary;
import orglistremo.output.units :
  formatDuration, formatHash, formatLastSync, formatSizeHuman, formatUnixTime;
import orglistremo.sync.scanner :
  SyncPhase, SyncProgress, SyncProgressCallback;
import std.format : format;
import std.stdio : File, stdout;

struct Styler {
  bool enabled;

  string wrap(string text, string code) const {
    return enabled ? "\033[" ~ code ~ "m" ~ text ~ "\033[0m" : text;
  }

  string bold(string s) const {
    return wrap(s, "1");
  }

  string header(string s) const {
    return wrap(s, "1;36");
  }

  string root(string s) const {
    return wrap(s, "1;35");
  }

  string dir(string s) const {
    return wrap(s, "1;34");
  }

  string size(string s) const {
    return wrap(s, "33");
  }

  string hash(string s) const {
    return wrap(s, "2;37");
  }

  string date(string s) const {
    return wrap(s, "32");
  }
}

struct OutputOptions {
  OutputFormat format = OutputFormat.console;
  Styler styler;
  bool fullHash = false;
}

final class ConsoleProgressReporter {
public:
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

  this(
    in OutputOptions opts,
    uint intervalMs,
    File stream,
    bool forceTty
  ) {
    this.styler = opts.styler;
    this.interval = dur!"msecs"(intervalMs);
    this.stream = stream;
    this.isTty = forceTty;
  }

  void onProgress(const ref SyncProgress progress) {
    update(progress);
  }

  void update(const ref SyncProgress progress) {
    if (!isTty) {
      return;
    }
    const now = MonoTime.currTime;
    const phaseChanged = !hasOutput || (progress.phase != lastPhase);
    if (!phaseChanged && (now - lastUpdateTime) < interval) {
      return;
    }
    lastUpdateTime = now;
    lastPhase = progress.phase;
    hasOutput = true;

    size_t visibleLen;
    const line = formatProgressLine(progress, visibleLen);
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

  void finish() {
    clear();
  }

  size_t currentVisibleLength() const {
    return lastVisibleLen;
  }

private:
  Styler styler;
  Duration interval;
  File stream;
  bool isTty;
  MonoTime lastUpdateTime;
  SyncPhase lastPhase;
  bool hasOutput;
  size_t lastVisibleLen;

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
      const msg = "  Saving database entries...";
      visibleLen = msg.length;
      return styler.enabled ? styler.header(msg) : msg;
    }

    const isHash = (progress.phase == SyncPhase.hashing);
    const tag = isHash ? "[hash]" : "[scan]";
    const styledTag = isHash ? styler.size(tag) : styler.header(tag);

    const sizeStr = formatSizeHuman(progress.totalBytes);
    const unstyledPrefix = format(
      "  %s %d files, %d dirs (%s) | ",
      tag, progress.fileCount, progress.dirCount, sizeStr
    );
    const styledPrefix = format(
      "  %s %d files, %d dirs (%s) | ",
      styledTag, progress.fileCount, progress.dirCount, sizeStr
    );

    string rawPath = progress.currentPath;
    if (isHash && progress.fileBytesTotal > 0) {
      const pct = cast(int)(
        (progress.fileBytesHashed * 100) / progress.fileBytesTotal
      );
      rawPath = format("%s (%d%%)", progress.currentPath, pct);
    }

    const termWidth = getTerminalWidth(stream.fileno);
    const visiblePrefixLen = unstyledPrefix.length;
    const avail = (termWidth > visiblePrefixLen + 1)
      ? termWidth - visiblePrefixLen - 1
      : 0;
    const truncatedPath = truncatePathLeft(rawPath, avail);

    visibleLen = visiblePrefixLen + truncatedPath.length;
    return styledPrefix ~ truncatedPath;
  }
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
    const rootPart = styler.root(e.rootName);
    if (e.isDir) {
      if (e.relPath == "." || e.relPath.length == 0) {
        return rootPart ~ styler.dir(":/");
      }
      return rootPart ~ ":/" ~ styler.dir(e.relPath ~ "/");
    }
    return rootPart ~ ":/" ~ e.relPath;
  }

  if (e.isDir) {
    const p = (e.relPath == "." || e.relPath.length == 0)
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

  foreach (ref s; summaries) {
    const rawSize = formatSizeHuman(s.totalSize);
    const syncTimeStr = formatLastSync(s.root.lastSync, s.root.hasLastSync);
    const freeStr = s.root.hasFreeSpace
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

  foreach (ref e; entries) {
    const typeStr = e.isDir ? "DIR" : "FILE";
    const pathStr = formatEntryPath(e, options.styler);
    const hStr = formatHash(e.sha256, options.fullHash);
    const sizeStr = formatSizeHuman(e.size);
    const mtimeStr = formatUnixTime(e.mtime);

    const typeCol = e.isDir
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

  foreach (ref g; groups) {
    const copies = cast(ulong) g.entries.length;
    if (copies > 1) {
      duplicateCopies += (copies - 1);
      totalDuplicateBytes += (copies - 1) * g.size;
    }

    const typeStr = g.isDir ? "DIR" : "FILE";
    const hStr = formatHash(g.sha256, options.fullHash);
    const sizeStr = formatSizeHuman(g.size);

    outStream.writefln(
      "[%s] SHA256: %s | Size: %s (%d copies)",
      g.isDir ? options.styler.dir(typeStr) : typeStr,
      options.styler.hash(hStr),
      options.styler.size(sizeStr),
      copies
    );

    foreach (ref e; g.entries) {
      const pathStr = formatEntryPath(e, options.styler);
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

  assert(formatSizeHuman(500) == "500 B");
  assert(formatSizeHuman(1024) == "1.00 KiB");
  assert(formatSizeHuman(1048576) == "1.00 MiB");

  assert(formatUnixTime(0).length == 19);
  assert(formatUnixTime(1700000000).length == 19);
  assert(formatLastSync(0, false) == "never");
  assert(formatLastSync(0, true).length == 19);

  assert(formatHash("0", false) == "0");
  assert(formatHash("abcdef0123456789", false) == "abcdef012345");
  assert(formatHash("abcdef0123456789", true) == "abcdef0123456789");

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

  // Test ConsoleProgressReporter with forceTty = true
  File progOut = File.tmpfile();
  auto reporter = new ConsoleProgressReporter(
    optsNoColor, 1000, progOut, true
  );

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

  // Test ConsoleProgressReporter with forceTty = false -> does not write
  File nonTtyOut = File.tmpfile();
  auto nonTtyReporter = new ConsoleProgressReporter(
    optsNoColor, 1000, nonTtyOut, false
  );
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
    auto colorReporter = new ConsoleProgressReporter(
      optsColor, 0, f, true
    );
    colorReporter.update(longSp);
    colorReporter.update(shortSp);
    colorReporter.clear();
    assert(colorReporter.currentVisibleLength == 0);
  });
  import std.algorithm.searching : canFind;
  assert(canFind(colorProgOut, "\033[K"));

  // Test ConsoleProgressReporter with optsNoColor emits spaces on shorter line
  const noColorProgOut = captureOutput((File f) {
    auto noColorReporter = new ConsoleProgressReporter(
      optsNoColor, 0, f, true
    );
    noColorReporter.update(longSp);
    noColorReporter.update(shortSp);
  });
  assert(canFind(noColorProgOut, "   "));
}
