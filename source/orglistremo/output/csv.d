module orglistremo.output.csv;

import orglistremo.model : DuplicateGroup, Entry, RootSummary;
import std.format : format;
import std.stdio : File, stdout, writefln, writeln;

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
  // Format is YYYYMMDDTHHMMSS; convert to ISO-8601: YYYY-MM-DDTHH:MM:SS
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

void printCsvRoots(RootSummary[] summaries, File outStream = stdout) {
  outStream.writeln("name,path,last_sync,file_count,dir_count,total_size");
  foreach (ref s; summaries) {
    outStream.writefln(
      "%s,%s,%s,%d,%d,%d",
      escapeCsvField(s.root.name),
      escapeCsvField(s.root.path),
      escapeCsvField(formatIso8601(s.root.lastSync)),
      s.fileCount,
      s.dirCount,
      s.totalSize
    );
  }
}

void printCsvEntries(Entry[] entries, File outStream = stdout) {
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

void printCsvDuplicates(DuplicateGroup[] groups, File outStream = stdout) {
  outStream.writeln("sha256,size,type,root,full_path,rel_path,mtime");
  foreach (ref g; groups) {
    const typeStr = g.isDir ? "D" : "F";
    foreach (ref e; g.entries) {
      outStream.writefln(
        "%s,%d,%s,%s,%s,%s,%s",
        escapeCsvField(g.sha256),
        g.size,
        typeStr,
        escapeCsvField(e.rootName),
        escapeCsvField(e.fullPath()),
        escapeCsvField(e.relPath),
        escapeCsvField(formatIso8601(e.mtime))
      );
    }
  }
}

void printCsvUnique(Entry[] entries, File outStream = stdout) {
  outStream.writeln("sha256,size,type,root,full_path,rel_path,mtime");
  foreach (ref e; entries) {
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
}

unittest {
  assert(escapeCsvField("simple") == "simple");
  assert(escapeCsvField("with,comma") == "\"with,comma\"");
  assert(escapeCsvField("with\"quote") == "\"with\"\"quote\"");
  assert(escapeCsvField("line\nbreak") == "\"line\nbreak\"");

  assert(formatIso8601(0) == "");
  const iso = formatIso8601(1700000000);
  assert(iso.length == 19);
  assert(iso[10] == 'T');
}
