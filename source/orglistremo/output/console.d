module orglistremo.output.console;

import orglistremo.model :
  ColorMode, DuplicateGroup, Entry, OutputFormat, RootSummary;
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
}
