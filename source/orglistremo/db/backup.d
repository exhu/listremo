module orglistremo.db.backup;

import orglistremo.config : ensureDbDirectory;
import orglistremo.model : OutputFormat;
import orglistremo.output.console : OutputOptions;
import std.stdio : stderr, stdout, writefln;

string proposeBackupPath(string dbPath) {
  import std.algorithm.searching : endsWith;
  import std.file : exists;
  import std.format : format;

  const prefix = dbPath.endsWith(".db")
    ? dbPath[0 .. $ - 3]
    : dbPath;
  ulong idx = 1;
  while (true) {
    const candidate = format("%s-backup-%d.db", prefix, idx);
    if (!exists(candidate)) {
      return candidate;
    }
    idx++;
  }
}

bool promptBackupPath(
  string dbPath,
  out string chosenPath,
  string actionName = "Migration"
) {
  import std.file : exists;
  import std.stdio : readln, writef;
  import std.string : strip;

  while (true) {
    const proposed = proposeBackupPath(dbPath);
    writef(
      "Backup file path [%s] (Enter to accept, Ctrl-C to abort): ",
      proposed
    );
    stdout.flush();

    const line = readln();
    if (line is null) {
      stderr.writefln("\n%s aborted.", actionName);
      return false;
    }

    const trimmed = line.strip();
    const candidate = trimmed.length > 0 ? trimmed : proposed;
    if (exists(candidate)) {
      stderr.writefln(
        "File '%s' already exists and will not be overwritten.",
        candidate
      );
      continue;
    }

    chosenPath = candidate;
    return true;
  }
}

bool writeDatabaseBackup(
  string dbPath,
  string backupPath,
  in OutputOptions opts
) {
  import std.file : copy;

  try {
    ensureDbDirectory(backupPath);
    copy(dbPath, backupPath);
    if (opts.format == OutputFormat.console) {
      writefln("Saved database backup to '%s'.", backupPath);
    }
    return true;
  } catch (Exception e) {
    stderr.writefln(
      "Error: Failed to write backup file '%s': %s",
      backupPath,
      e.msg
    );
    return false;
  }
}
