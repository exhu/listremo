module orglistremo.output.console;

import orglistremo.model : ColorMode, DuplicateGroup, Entry, RootSummary;
import std.format : format;
import std.stdio : File, stdout, write, writefln, writeln;

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

void printConsoleRoots(
  RootSummary[] summaries,
  Styler styler,
  File outStream = stdout
) {
  if (summaries.length == 0) {
    outStream.writeln("No storage roots registered.");
    return;
  }

  outStream.writefln(
    "%-18s %-25s %-19s %8s %8s %12s",
    styler.header("NAME"),
    styler.header("PATH"),
    styler.header("LAST SYNC"),
    styler.header("FILES"),
    styler.header("DIRS"),
    styler.header("SIZE")
  );

  foreach (ref s; summaries) {
    const rawSize = formatSizeHuman(s.totalSize);
    outStream.writefln(
      "%-18s %-25s %-19s %8d %8d %12s",
      styler.root(s.root.name),
      s.root.path,
      styler.date(formatUnixTime(s.root.lastSync)),
      s.fileCount,
      s.dirCount,
      styler.size(rawSize)
    );
  }
}

void printConsoleEntries(
  Entry[] entries,
  Styler styler,
  bool fullHash = false,
  File outStream = stdout
) {
  if (entries.length == 0) {
    outStream.writeln("No entries found.");
    return;
  }

  outStream.writefln(
    "%-4s %-12s %-19s %-14s %s",
    styler.header("TYPE"),
    styler.header("SIZE"),
    styler.header("MODIFIED"),
    styler.header("SHA256"),
    styler.header("PATH")
  );

  foreach (ref e; entries) {
    const typeStr = e.isDir ? "DIR" : "FILE";
    const fp = e.fullPath();
    const dirFormatted = (fp.length > 0 && fp[$ - 1] == '/') ? fp : fp ~ "/";
    const pathStr = e.isDir ? styler.dir(dirFormatted) : fp;
    const hStr = formatHash(e.sha256, fullHash);

    outStream.writefln(
      "%-4s %-12s %-19s %-14s %s",
      e.isDir ? styler.dir(typeStr) : typeStr,
      styler.size(formatSizeHuman(e.size)),
      styler.date(formatUnixTime(e.mtime)),
      styler.hash(hStr),
      pathStr
    );
  }
}

void printConsoleDuplicates(
  DuplicateGroup[] groups,
  Styler styler,
  bool fullHash = false,
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
    const hStr = formatHash(g.sha256, fullHash);
    const sizeStr = formatSizeHuman(g.size);

    outStream.writefln(
      "[%s] SHA256: %s | Size: %s (%d copies)",
      g.isDir ? styler.dir(typeStr) : typeStr,
      styler.hash(hStr),
      styler.size(sizeStr),
      copies
    );

    foreach (ref e; g.entries) {
      const fp = e.fullPath();
      const dirFormatted = (fp.length > 0 && fp[$ - 1] == '/') ? fp : fp ~ "/";
      const pathStr = e.isDir ? styler.dir(dirFormatted) : fp;
      outStream.writefln("  -> %s", pathStr);
    }
  }

  outStream.writefln(
    "\nSummary: %d duplicate group(s), %d wasted copies (%s recoverable)",
    groups.length,
    duplicateCopies,
    styler.size(formatSizeHuman(totalDuplicateBytes))
  );
}

void printConsoleUnique(
  Entry[] entries,
  Styler styler,
  bool fullHash = false,
  File outStream = stdout
) {
  if (entries.length == 0) {
    outStream.writeln("No unique entries found.");
    return;
  }

  printConsoleEntries(entries, styler, fullHash, outStream);
  outStream.writefln("\nTotal unique entries: %d", entries.length);
}

unittest {
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
}
