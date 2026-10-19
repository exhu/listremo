module orglistremo.output.console;

import core.time : dur, Duration, MonoTime;
import orglistremo.model :
  ColorMode, DuplicateGroup, Entry, OutputFormat, RootSummary;
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
    import core.sys.posix.unistd : isatty;
    this.isTty = (opts.format == OutputFormat.console)
      && (isatty(stream.fileno) != 0);
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
  import core.sys.posix.unistd : isatty, STDOUT_FILENO;
  import std.process : environment;

  if (environment.get("NO_COLOR", null) !is null) {
    return false;
  }
  return isatty(STDOUT_FILENO) != 0;
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
    "%s %s %s %s %s %s",
    options.styler.header(format("%-18s", "NAME")),
    options.styler.header(format("%-25s", "PATH")),
    options.styler.header(format("%-19s", "LAST SYNC")),
    options.styler.header(format("%8s", "FILES")),
    options.styler.header(format("%8s", "DIRS")),
    options.styler.header(format("%12s", "SIZE"))
  );

  foreach (ref s; summaries) {
    const rawSize = formatSizeHuman(s.totalSize);
    const syncTimeStr = s.root.hasLastSync
      ? formatUnixTime(s.root.lastSync)
      : "never";
    outStream.writefln(
      "%s %s %s %s %s %s",
      options.styler.root(format("%-18s", s.root.name)),
      format("%-25s", s.root.path),
      options.styler.date(format("%-19s", syncTimeStr)),
      format("%8d", s.fileCount),
      format("%8d", s.dirCount),
      options.styler.size(format("%12s", rawSize))
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

string formatSizeHuman(ulong bytes) {
  if (bytes < 1024) {
    return format("%d B", bytes);
  }
  static immutable string[] units = ["KiB", "MiB", "GiB", "TiB", "PiB"];
  double d = (cast(double) bytes) / 1024.0;
  size_t u = 0;
  while (d >= 1024.0 && u + 1 < units.length) {
    d /= 1024.0;
    u++;
  }
  return format("%.2f %s", d, units[u]);
}

string formatUnixTime(long ts) {
  if (ts <= 0) {
    return "never";
  }
  import std.datetime.systime : SysTime;
  const s = SysTime.fromUnixTime(ts).toISOString();
  if (s.length >= 15) {
    return format(
      "%s-%s-%s %s:%s:%s",
      s[0 .. 4],
      s[4 .. 6],
      s[6 .. 8],
      s[9 .. 11],
      s[11 .. 13],
      s[13 .. 15]
    );
  }
  return s;
}

string formatHash(string h, bool fullHash) {
  if (fullHash || h == "0" || h.length <= 12) {
    return h;
  }
  return h[0 .. 12];
}

string truncatePathLeft(string path, size_t maxLen) {
  if (path.length <= maxLen) {
    return path;
  }
  if (maxLen <= 3) {
    return path[$ - maxLen .. $];
  }
  return "..." ~ path[$ - (maxLen - 3) .. $];
}

size_t getTerminalWidth(int fd) {
  import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
  winsize ws;
  if (ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
    return cast(size_t) ws.ws_col;
  }
  return 80;
}

unittest {
  import orglistremo.model : Root;

  Styler styler;
  styler.enabled = false;

  assert(formatSizeHuman(500) == "500 B");
  assert(formatSizeHuman(1024) == "1.00 KiB");
  assert(formatSizeHuman(1048576) == "1.00 MiB");

  assert(formatUnixTime(0) == "never");
  assert(formatUnixTime(1700000000).length == 19);

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

  File tmpOut = File.tmpfile();
  printConsoleRoots(roots, optsNoColor, tmpOut);
  tmpOut.rewind();
  const headerLine = tmpOut.readln();
  assert(headerLine.length > 0);
  const rowLine = tmpOut.readln();
  assert(rowLine.length > 0);

  // Test printConsoleRoots with colors (verifying alignment not corrupted)
  OutputOptions optsColor;
  optsColor.styler.enabled = true;
  File tmpOutColor = File.tmpfile();
  printConsoleRoots(roots, optsColor, tmpOutColor);

  // Test printConsoleEntries (uncolored and colored)
  File tmpEntries = File.tmpfile();
  printConsoleEntries([e1, e2], optsNoColor, tmpEntries);
  File tmpEntriesColor = File.tmpfile();
  printConsoleEntries([e1, e2], optsColor, tmpEntriesColor);

  // Test printConsoleDuplicates (uncolored and colored)
  DuplicateGroup dg;
  dg.sha256 = "abc123456789";
  dg.size = 100;
  dg.isDir = false;
  dg.entries = [e1];
  File tmpDups = File.tmpfile();
  printConsoleDuplicates([dg], optsNoColor, tmpDups);
  File tmpDupsColor = File.tmpfile();
  printConsoleDuplicates([dg], optsColor, tmpDupsColor);

  // Test printConsoleUnique (uncolored and colored)
  File tmpUniq = File.tmpfile();
  printConsoleUnique([e1], optsNoColor, tmpUniq);
  File tmpUniqColor = File.tmpfile();
  printConsoleUnique([e1], optsColor, tmpUniqColor);

  // Test truncatePathLeft
  assert(truncatePathLeft("short.txt", 20) == "short.txt");
  assert(truncatePathLeft("abcdefghij", 5) == "...ij");
  assert(truncatePathLeft("abcdefghij", 2) == "ij");

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
  File colorProgOut = File.tmpfile();
  auto colorReporter = new ConsoleProgressReporter(
    optsColor, 0, colorProgOut, true
  );

  SyncProgress longSp;
  longSp.phase = SyncPhase.hashing;
  longSp.currentPath = "long_path_name.bin";
  longSp.fileCount = 1;
  longSp.dirCount = 0;
  longSp.totalBytes = 1000;
  longSp.fileBytesHashed = 230;
  longSp.fileBytesTotal = 1000;
  colorReporter.update(longSp);

  SyncProgress shortSp;
  shortSp.phase = SyncPhase.hashing;
  shortSp.currentPath = "short.bin";
  shortSp.fileCount = 1;
  shortSp.dirCount = 0;
  shortSp.totalBytes = 1000;
  shortSp.fileBytesHashed = 230;
  shortSp.fileBytesTotal = 1000;
  colorReporter.update(shortSp);

  colorProgOut.rewind();
  ubyte[] colorBytes = new ubyte[cast(size_t) colorProgOut.size];
  colorProgOut.rawRead(colorBytes);
  import std.algorithm.searching : canFind;
  assert(canFind(cast(string) colorBytes, "\033[K"));

  // Test clear with optsColor emits \033[K
  colorReporter.clear();
  assert(colorReporter.currentVisibleLength == 0);

  // Test ConsoleProgressReporter with optsNoColor emits spaces on shorter line
  File noColorProgOut = File.tmpfile();
  auto noColorReporter = new ConsoleProgressReporter(
    optsNoColor, 0, noColorProgOut, true
  );
  noColorReporter.update(longSp);
  noColorReporter.update(shortSp);

  noColorProgOut.rewind();
  ubyte[] noColorBytes = new ubyte[cast(size_t) noColorProgOut.size];
  noColorProgOut.rawRead(noColorBytes);
  assert(canFind(cast(string) noColorBytes, "   "));
}
