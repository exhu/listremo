module orglistremo.output.csv;

import orglistremo.model : DuplicateGroup, Entry, RootSummary;
import std.format : format;
import std.stdio : File, stdout;

void printCsvRoots(in RootSummary[] summaries, File outStream = stdout) {
  outStream.writeln("name,path,last_sync,file_count,dir_count,total_size");
  foreach (ref s; summaries) {
    const syncStr = s.root.hasLastSync ? formatIso8601(s.root.lastSync) : "";
    outStream.writefln(
      "%s,%s,%s,%d,%d,%d",
      escapeCsvField(s.root.name),
      escapeCsvField(s.root.path),
      escapeCsvField(syncStr),
      s.fileCount,
      s.dirCount,
      s.totalSize
    );
  }
}

void printCsvEntries(in Entry[] entries, File outStream = stdout) {
  outStream.writeln("root,full_path,rel_path,type,size,mtime,sha256");
  foreach (ref e; entries) {
    const typeStr = e.isDir ? "D" : "F";
    outStream.writefln(
      "%s,%s,%s,%s,%d,%s,%s",
      escapeCsvField(e.rootName),
      escapeCsvField(e.fullPath()),
      escapeCsvField(e.relPath),
      typeStr,
      e.size,
      escapeCsvField(formatIso8601(e.mtime)),
      escapeCsvField(e.sha256)
    );
  }
}

void printCsvDuplicates(
  in DuplicateGroup[] groups,
  File outStream = stdout
) {
  writeHashQueryHeader(outStream);
  foreach (ref g; groups) {
    foreach (ref e; g.entries) {
      writeHashQueryRow(e, outStream);
    }
  }
}

void printCsvUnique(in Entry[] entries, File outStream = stdout) {
  writeHashQueryHeader(outStream);
  foreach (ref e; entries) {
    writeHashQueryRow(e, outStream);
  }
}

private:

void writeHashQueryHeader(File outStream) {
  outStream.writeln("sha256,size,type,root,full_path,rel_path,mtime");
}

void writeHashQueryRow(in Entry e, File outStream) {
  const typeStr = e.isDir ? "D" : "F";
  outStream.writefln(
    "%s,%d,%s,%s,%s,%s,%s",
    escapeCsvField(e.sha256),
    e.size,
    typeStr,
    escapeCsvField(e.rootName),
    escapeCsvField(e.fullPath()),
    escapeCsvField(e.relPath),
    escapeCsvField(formatIso8601(e.mtime))
  );
}

string escapeCsvField(string val) {
  bool needsQuotes = false;
  foreach (c; val) {
    if (c == ',' || c == '"' || c == '\n' || c == '\r') {
      needsQuotes = true;
      break;
    }
  }

  if (!needsQuotes) {
    return val;
  }

  string escaped = "\"";
  foreach (c; val) {
    if (c == '"') {
      escaped ~= "\"\"";
    } else {
      escaped ~= c;
    }
  }
  escaped ~= "\"";
  return escaped;
}

string formatIso8601(long unixTs) {
  if (unixTs <= 0) {
    return "";
  }
  import std.datetime.systime : SysTime;
  const s = SysTime.fromUnixTime(unixTs).toISOString();
  if (s.length >= 15) {
    return format(
      "%s-%s-%sT%s:%s:%s",
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

unittest {
  import orglistremo.model : Root;

  assert(escapeCsvField("simple") == "simple");
  assert(escapeCsvField("with,comma") == "\"with,comma\"");
  assert(escapeCsvField("with\"quote") == "\"with\"\"quote\"");
  assert(escapeCsvField("line\nbreak") == "\"line\nbreak\"");

  assert(formatIso8601(0) == "");
  const iso = formatIso8601(1700000000);
  assert(iso.length == 19);
  assert(iso[10] == 'T');

  // Test printCsvRoots with and without lastSync
  Root r1 = Root(1, "r1", "/mnt/r1", 1000, 1700000000, true);
  Root r2 = Root(2, "r2", "/mnt/r2", 1000, 0, false);
  RootSummary[] roots = [
    RootSummary(r1, 5, 1, 100),
    RootSummary(r2, 0, 0, 0)
  ];

  File tmpRoots = File.tmpfile();
  printCsvRoots(roots, tmpRoots);
  tmpRoots.rewind();
  assert(
    tmpRoots.readln() ==
    "name,path,last_sync,file_count,dir_count,total_size\n"
  );
  const lineR1 = tmpRoots.readln();
  assert(lineR1.length > 0);
  const lineR2 = tmpRoots.readln();
  assert(lineR2.length > 0);

  // Test printCsvEntries
  Entry e = Entry(
    1, 1, "r1", "doc.txt", ".", "doc.txt", false, 10, 1700000000, "abc"
  );
  File tmpEntries = File.tmpfile();
  printCsvEntries([e], tmpEntries);

  // Test printCsvDuplicates
  DuplicateGroup dg;
  dg.sha256 = "abc";
  dg.size = 10;
  dg.isDir = false;
  dg.entries = [e];
  File tmpDups = File.tmpfile();
  printCsvDuplicates([dg], tmpDups);

  // Test printCsvUnique
  File tmpUniq = File.tmpfile();
  printCsvUnique([e], tmpUniq);
}
