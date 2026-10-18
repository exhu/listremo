module orglistremo.app;

import d2sqlite3 : Database;
import orglistremo.config : resolveDbPath;
import orglistremo.db.connection : openDatabase;
import orglistremo.db.repo :
  EntryRepository, HashQueryFilter, ListEntriesFilter, RootRepository;
import orglistremo.model :
  ColorMode, Entry, EntryType, OutputFormat, Root, RootSummary, SortField,
  TargetSpec;
import orglistremo.output.console : OutputOptions, shouldColorize, Styler;
import orglistremo.output.formatter :
  outputDuplicates, outputEntries, outputRoots, outputUnique;
import orglistremo.sync.scanner : syncRoot;
import std.getopt : config, getopt;
import std.stdio : stderr, writefln, writeln;

version (unittest) {
  // main is excluded so the unit test runner provides its own entry point
} else {
  int main(string[] args) {
    CliGlobalOptions globals;
    if (!parseGlobalOptions(args, globals)) {
      return 1;
    }

    if (globals.showHelp || args.length <= 1 || args[1] == "help") {
      printUsage();
      return 0;
    }

    if (args[1].length > 0 && args[1][0] == '-') {
      stderr.writefln(
        "Unrecognized option '%s'. Run 'listremo help'.", args[1]
      );
      return 1;
    }

    OutputOptions opts;
    if (!buildOutputOptions(globals, opts)) {
      return 1;
    }

    const dbPath = resolveDbPath(globals.cliDb);
    Database db;
    try {
      db = openDatabase(dbPath);
    } catch (Exception e) {
      stderr.writefln("Failed to open database '%s': %s", dbPath, e.msg);
      return 1;
    }

    return dispatchCommand(db, args[1 .. $], opts);
  }
}

private:

struct CliGlobalOptions {
  string cliDb;
  string formatStr = "console";
  bool csvFlag;
  string colorStr = "auto";
  bool fullHash;
  bool showHelp;
}

struct SyncArgs {
  bool allFlag;
  bool forceHash;
  string targetRoot;
}

struct ListArgs {
  string target;
  EntryType typeFilter = EntryType.all;
  SortField sortField = SortField.path;
}

struct DuplicateOrUniqueArgs {
  string target;
  EntryType typeFilter = EntryType.file;
  bool skipEmpty;
}

bool parseGlobalOptions(ref string[] args, out CliGlobalOptions globals) {
  try {
    getopt(
      args,
      config.passThrough,
      config.caseSensitive,
      "db", "Path to SQLite database", &globals.cliDb,
      "format", "Output format (console or csv)", &globals.formatStr,
      "csv", "Shortcut for --format csv", &globals.csvFlag,
      "color", "Color mode (auto, always, never)", &globals.colorStr,
      "full-hash", "Display full 64-char SHA256 in console", &globals.fullHash,
      "help|h", "Display this help message", &globals.showHelp
    );
    return true;
  } catch (Exception e) {
    stderr.writefln("Error parsing global options: %s", e.msg);
    return false;
  }
}

bool buildOutputOptions(
  in CliGlobalOptions globals,
  out OutputOptions opts
) {
  if (globals.formatStr != "console" && globals.formatStr != "csv") {
    stderr.writefln(
      "Invalid --format '%s'. Valid values: console, csv.", globals.formatStr
    );
    return false;
  }

  ColorMode colorMode;
  if (globals.colorStr == "auto") {
    colorMode = ColorMode.autoMode;
  } else if (globals.colorStr == "always") {
    colorMode = ColorMode.always;
  } else if (globals.colorStr == "never") {
    colorMode = ColorMode.never;
  } else {
    stderr.writefln(
      "Invalid --color '%s'. Valid values: auto, always, never.",
      globals.colorStr
    );
    return false;
  }

  opts.format = (globals.csvFlag || globals.formatStr == "csv")
    ? OutputFormat.csv
    : OutputFormat.console;

  opts.styler.enabled = (opts.format == OutputFormat.console)
    && shouldColorize(colorMode);
  opts.fullHash = globals.fullHash;
  return true;
}

void printUsage() {
  writeln("Usage: listremo [global options] <command> [arguments...]\n");
  writeln("Commands:");
  writeln("  root add <name> <path>       Register a new storage root");
  writeln("  root remove <name>           Remove a root and entries");
  writeln("  root set-path <name> <path>  Update mount path of a root");
  writeln("  root list                    List all registered storage roots");
  writeln("  sync <name> [--force-hash]   Synchronize a storage root");
  writeln("  sync --all [--force-hash]    Synchronize all storage roots");
  writeln("  list <target> [options]      List files & dirs (alias: files)");
  writeln("  duplicates [<target>] [opts] Find duplicate files/dirs");
  writeln("  unique [<target>] [options]  Find unique files/dirs\n");
  writeln("Global Options:");
  writeln("  --db <path>                  SQLite database path");
  writeln("  --format <console|csv>       Output format (default: console)");
  writeln("  --csv                        Shorthand for --format csv");
  writeln("  --color <auto|always|never>  Control ANSI colors");
  writeln("  --full-hash                  Show full 64-char hashes");
}

int dispatchCommand(
  ref Database db,
  string[] subArgs,
  in OutputOptions opts
) {
  const subcmd = subArgs[0];
  switch (subcmd) {
    case "root":
      return handleRootCommand(db, subArgs, opts);
    case "sync":
      return handleSyncCommand(db, subArgs, opts);
    case "list":
    case "files":
      return handleListCommand(db, subArgs, opts);
    case "duplicates":
      return handleDuplicatesCommand(db, subArgs, opts);
    case "unique":
      return handleUniqueCommand(db, subArgs, opts);
    case "help":
      printUsage();
      return 0;
    default:
      stderr.writefln(
        "Unknown subcommand '%s'. Run 'listremo help'.", subcmd
      );
      return 1;
  }
}

int handleRootCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 2) {
    stderr.writeln("Usage: listremo root <add|remove|set-path|list>");
    return 1;
  }
  RootRepository rootRepo = RootRepository(db);
  const action = args[1];

  switch (action) {
    case "add":
      return handleRootAdd(rootRepo, args, opts);
    case "remove":
      return handleRootRemove(rootRepo, args, opts);
    case "set-path":
      return handleRootSetPath(rootRepo, args, opts);
    case "list":
      const summaries = rootRepo.listRoots();
      outputRoots(summaries, opts);
      return 0;
    default:
      stderr.writefln("Unknown root action '%s'.", action);
      return 1;
  }
}

int handleRootAdd(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 4) {
    stderr.writeln("Usage: listremo root add <name> <path>");
    return 1;
  }
  try {
    rootRepo.addRoot(args[2], args[3]);
    if (opts.format == OutputFormat.console) {
      writefln("Registered root '%s' -> '%s'", args[2], args[3]);
    }
    return 0;
  } catch (Exception e) {
    stderr.writefln("Error: %s", e.msg);
    return 1;
  }
}

int handleRootRemove(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 3) {
    stderr.writeln("Usage: listremo root remove <name>");
    return 1;
  }
  if (rootRepo.removeRoot(args[2])) {
    if (opts.format == OutputFormat.console) {
      writefln("Removed root '%s' and cataloged entries.", args[2]);
    }
    return 0;
  }
  stderr.writefln("Error: Root '%s' not found.", args[2]);
  return 1;
}

int handleRootSetPath(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 4) {
    stderr.writeln("Usage: listremo root set-path <name> <new_path>");
    return 1;
  }
  if (rootRepo.setPath(args[2], args[3])) {
    if (opts.format == OutputFormat.console) {
      writefln("Updated path for '%s' -> '%s'", args[2], args[3]);
    }
    return 0;
  }
  stderr.writefln("Error: Root '%s' not found.", args[2]);
  return 1;
}

bool parseSyncArgs(string[] args, out SyncArgs parsed) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--all") {
      parsed.allFlag = true;
    } else if (arg == "--force-hash") {
      parsed.forceHash = true;
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for sync.", arg);
      return false;
    } else {
      if (parsed.targetRoot.length > 0) {
        stderr.writefln("Unexpected argument '%s'.", arg);
        return false;
      }
      parsed.targetRoot = arg;
    }
  }

  if (parsed.allFlag && parsed.targetRoot.length > 0) {
    stderr.writeln("Error: Cannot specify both <name> and --all.");
    return false;
  }
  if (!parsed.allFlag && parsed.targetRoot.length == 0) {
    stderr.writeln("Usage: listremo sync <name> [--force-hash] OR --all");
    return false;
  }
  return true;
}

int handleSyncCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  SyncArgs syncArgs;
  if (!parseSyncArgs(args, syncArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(db);
  Root[] toSync;
  if (syncArgs.allFlag) {
    const summaries = rootRepo.listRoots();
    foreach (ref s; summaries) {
      toSync ~= s.root;
    }
  } else {
    Root r;
    if (!rootRepo.findByName(syncArgs.targetRoot, r)) {
      stderr.writefln("Error: Root '%s' not registered.", syncArgs.targetRoot);
      return 1;
    }
    toSync ~= r;
  }

  bool hadError = false;
  foreach (ref root; toSync) {
    if (opts.format == OutputFormat.console) {
      writefln("Syncing root '%s' (%s)...", root.name, root.path);
    }
    try {
      const stats = syncRoot(db, root, syncArgs.forceHash);
      if (opts.format == OutputFormat.console) {
        writefln(
          "  Done: %d files, %d dirs, %d reused hashes.",
          stats.fileCount,
          stats.dirCount,
          stats.reusedHashes
        );
      }
    } catch (Exception e) {
      stderr.writefln("Error syncing root '%s': %s", root.name, e.msg);
      hadError = true;
    }
  }

  return hadError ? 1 : 0;
}

bool parseTypeFilter(string val, out EntryType filter) {
  if (val == "all") {
    filter = EntryType.all;
    return true;
  }
  if (val == "file") {
    filter = EntryType.file;
    return true;
  }
  if (val == "dir") {
    filter = EntryType.dir;
    return true;
  }
  stderr.writefln(
    "Invalid --type '%s'. Valid values: all, file, dir.", val
  );
  return false;
}

bool parseSortField(string val, out SortField field) {
  if (val == "path") {
    field = SortField.path;
    return true;
  }
  if (val == "size") {
    field = SortField.size;
    return true;
  }
  if (val == "mtime") {
    field = SortField.mtime;
    return true;
  }
  stderr.writefln(
    "Invalid --sort '%s'. Valid values: path, size, mtime.", val
  );
  return false;
}

bool parseListArgs(string[] args, out ListArgs parsed) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--type") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --type option.");
        return false;
      }
      if (!parseTypeFilter(args[++i], parsed.typeFilter)) {
        return false;
      }
    } else if (arg == "--sort") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --sort option.");
        return false;
      }
      if (!parseSortField(args[++i], parsed.sortField)) {
        return false;
      }
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for list.", arg);
      return false;
    } else {
      if (parsed.target.length > 0) {
        stderr.writefln("Unexpected argument '%s'.", arg);
        return false;
      }
      parsed.target = arg;
    }
  }

  if (parsed.target.length == 0) {
    stderr.writeln(
      "Usage: listremo list <target> [--type all|file|dir] " ~
      "[--sort path|size|mtime]"
    );
    return false;
  }
  return true;
}

int handleListCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  ListArgs listArgs;
  if (!parseListArgs(args, listArgs)) {
    return 1;
  }

  const spec = TargetSpec.parse(listArgs.target);
  RootRepository rootRepo = RootRepository(db);
  Root root;
  if (!rootRepo.findByName(spec.rootName, root)) {
    stderr.writefln("Error: Root '%s' not found.", spec.rootName);
    return 1;
  }

  EntryRepository entryRepo = EntryRepository(db);
  ListEntriesFilter filter;
  filter.subpath = spec.hasSubpath ? spec.subpath : null;
  filter.typeFilter = listArgs.typeFilter;
  filter.sort = listArgs.sortField;

  const entries = entryRepo.listEntries(root.id, filter);
  outputEntries(entries, opts);
  return 0;
}

bool parseDuplicateOrUniqueArgs(
  string cmdName,
  string[] args,
  out DuplicateOrUniqueArgs parsed
) {
  for (size_t i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg == "--type") {
      if (i + 1 >= args.length) {
        stderr.writeln("Error: Missing value for --type option.");
        return false;
      }
      if (!parseTypeFilter(args[++i], parsed.typeFilter)) {
        return false;
      }
    } else if (arg == "--skip-empty") {
      parsed.skipEmpty = true;
    } else if (arg.length > 0 && arg[0] == '-') {
      stderr.writefln("Unknown flag '%s' for %s.", arg, cmdName);
      return false;
    } else {
      if (parsed.target.length > 0) {
        stderr.writefln("Unexpected argument '%s'.", arg);
        return false;
      }
      parsed.target = arg;
    }
  }
  return true;
}

bool resolveHashQueryFilter(
  ref RootRepository rootRepo,
  in DuplicateOrUniqueArgs args,
  out HashQueryFilter filter
) {
  filter.typeFilter = args.typeFilter;
  filter.skipEmpty = args.skipEmpty;

  if (args.target.length == 0) {
    filter.hasRoot = false;
    return true;
  }

  const spec = TargetSpec.parse(args.target);
  Root root;
  if (!rootRepo.findByName(spec.rootName, root)) {
    stderr.writefln("Error: Root '%s' not found.", spec.rootName);
    return false;
  }

  filter.hasRoot = true;
  filter.rootId = root.id;
  filter.subpath = spec.hasSubpath ? spec.subpath : null;
  return true;
}

int handleDuplicatesCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  DuplicateOrUniqueArgs parsedArgs;
  if (!parseDuplicateOrUniqueArgs("duplicates", args, parsedArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(db);
  HashQueryFilter filter;
  if (!resolveHashQueryFilter(rootRepo, parsedArgs, filter)) {
    return 1;
  }

  EntryRepository entryRepo = EntryRepository(db);
  const rawEntries = entryRepo.listDuplicates(filter);
  const groups = entryRepo.groupDuplicates(rawEntries);
  outputDuplicates(groups, opts);
  return 0;
}

int handleUniqueCommand(
  ref Database db,
  string[] args,
  in OutputOptions opts
) {
  DuplicateOrUniqueArgs parsedArgs;
  if (!parseDuplicateOrUniqueArgs("unique", args, parsedArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(db);
  HashQueryFilter filter;
  if (!resolveHashQueryFilter(rootRepo, parsedArgs, filter)) {
    return 1;
  }

  EntryRepository entryRepo = EntryRepository(db);
  const entries = entryRepo.listUnique(filter);
  outputUnique(entries, opts);
  return 0;
}

unittest {
  import orglistremo.db.connection : openDatabase;

  // Test global options parsing
  string[] validArgs = ["listremo", "--format", "csv", "--color", "never"];
  CliGlobalOptions globals;
  assert(parseGlobalOptions(validArgs, globals));
  assert(globals.formatStr == "csv");
  assert(globals.colorStr == "never");

  OutputOptions opts;
  assert(buildOutputOptions(globals, opts));
  assert(opts.format == OutputFormat.csv);
  assert(!opts.styler.enabled);

  // Test invalid global options
  globals.formatStr = "xml";
  assert(!buildOutputOptions(globals, opts));
  globals.formatStr = "console";
  globals.colorStr = "rainbow";
  assert(!buildOutputOptions(globals, opts));

  // Test sync args parsing & validation
  SyncArgs syncArgs;
  assert(parseSyncArgs(["sync", "myroot", "--force-hash"], syncArgs));
  assert(syncArgs.targetRoot == "myroot");
  assert(syncArgs.forceHash);
  assert(!syncArgs.allFlag);

  SyncArgs syncAll;
  assert(parseSyncArgs(["sync", "--all"], syncAll));
  assert(syncAll.allFlag);

  // Conflicting sync arguments
  SyncArgs conflictArgs;
  assert(!parseSyncArgs(["sync", "myroot", "--all"], conflictArgs));

  // Unknown sync flag
  SyncArgs unknownFlagArgs;
  assert(!parseSyncArgs(["sync", "--bogus"], unknownFlagArgs));

  // Test list args parsing & validation
  ListArgs listArgs;
  assert(
    parseListArgs(
      ["list", "myroot", "--type", "file", "--sort", "size"], listArgs
    )
  );
  assert(listArgs.target == "myroot");
  assert(listArgs.typeFilter == EntryType.file);
  assert(listArgs.sortField == SortField.size);

  ListArgs invalidType;
  assert(!parseListArgs(["list", "myroot", "--type", "invalid"], invalidType));

  ListArgs missingTypeVal;
  assert(!parseListArgs(["list", "myroot", "--type"], missingTypeVal));

  // Test duplicate / unique args parsing & validation
  DuplicateOrUniqueArgs dupArgs;
  assert(
    parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "--type", "all", "--skip-empty"], dupArgs
    )
  );
  assert(dupArgs.typeFilter == EntryType.all);
  assert(dupArgs.skipEmpty);

  DuplicateOrUniqueArgs dupUnknown;
  assert(
    !parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "--unknown"], dupUnknown
    )
  );

  // Test command execution on memory db
  Database db = openDatabase(":memory:");
  OutputOptions testOpts;
  testOpts.styler.enabled = false;

  // Root commands
  assert(
    handleRootCommand(db, ["root", "add", "r1", "/mnt/r1"], testOpts) == 0
  );
  assert(handleRootCommand(db, ["root", "list"], testOpts) == 0);
  assert(
    handleRootCommand(
      db, ["root", "set-path", "r1", "/mnt/new"], testOpts
    ) == 0
  );
  assert(handleRootCommand(db, ["root", "remove", "r1"], testOpts) == 0);
}
