module orglistremo.app;

import d2sqlite3 : Database;
import orglistremo.config : resolveDbPath;
import orglistremo.db.connection : openDatabase;
import orglistremo.db.repo : EntryRepository, RootRepository;
import orglistremo.model :
  ColorMode, Entry, EntryType, OutputFormat, Root, SortField, TargetSpec;
import orglistremo.output.console : shouldColorize, Styler;
import orglistremo.output.formatter :
  outputDuplicates, outputEntries, outputRoots, outputUnique;
import orglistremo.sync.scanner : syncRoot;
import std.getopt : config, defaultGetoptPrinter, getopt, GetoptResult;
import std.stdio : stderr, stdout, writefln, writeln;

version (unittest) {
  // Exclude main and command handlers during unit test build
} else {
  int main(string[] args) {
    string cliDb = null;
    string formatStr = "console";
    bool csvFlag = false;
    string colorStr = "auto";
    bool fullHash = false;
    bool helpFlag = false;

    try {
      auto r = getopt(
        args,
        config.passThrough,
        config.caseSensitive,
        "db", "Path to SQLite database", &cliDb,
        "format", "Output format (console or csv)", &formatStr,
        "csv", "Shortcut for --format csv", &csvFlag,
        "color", "Color mode (auto, always, never)", &colorStr,
        "full-hash", "Display full 64-char SHA256 in console", &fullHash,
        "help|h", "Display this help message", &helpFlag
      );

      if (helpFlag || args.length <= 1) {
        printUsage();
        return 0;
      }
    } catch (Exception e) {
      stderr.writefln("Error parsing global options: %s", e.msg);
      return 1;
    }

    const outputFormat = (csvFlag || formatStr == "csv")
      ? OutputFormat.csv
      : OutputFormat.console;

    ColorMode colorMode = ColorMode.autoMode;
    if (colorStr == "always") {
      colorMode = ColorMode.always;
    } else if (colorStr == "never") {
      colorMode = ColorMode.never;
    }

    Styler styler;
    styler.enabled = (outputFormat == OutputFormat.console)
      && shouldColorize(colorMode);

    const dbPath = resolveDbPath(cliDb);
    Database db;
    try {
      db = openDatabase(dbPath);
    } catch (Exception e) {
      stderr.writefln("Failed to open database '%s': %s", dbPath, e.msg);
      return 1;
    }

    const subcmd = args[1];
    string[] subArgs = args[1 .. $];

    switch (subcmd) {
      case "root":
        return handleRootCommand(db, subArgs, outputFormat, styler);
      case "sync":
        return handleSyncCommand(db, subArgs, outputFormat, styler);
      case "list":
      case "files":
        return handleListCommand(
          db, subArgs, outputFormat, styler, fullHash
        );
      case "duplicates":
        return handleDuplicatesCommand(
          db, subArgs, outputFormat, styler, fullHash
        );
      case "unique":
        return handleUniqueCommand(
          db, subArgs, outputFormat, styler, fullHash
        );
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

  int handleRootCommand(
    ref Database db,
    string[] args,
    OutputFormat fmt,
    Styler styler
  ) {
    if (args.length < 2) {
      stderr.writeln("Usage: listremo root <add|remove|set-path|list>");
      return 1;
    }
    auto rootRepo = RootRepository(db);
    const action = args[1];

    switch (action) {
      case "add":
        if (args.length < 4) {
          stderr.writeln("Usage: listremo root add <name> <path>");
          return 1;
        }
        try {
          rootRepo.addRoot(args[2], args[3]);
          if (fmt == OutputFormat.console) {
            writefln("Registered root '%s' -> '%s'", args[2], args[3]);
          }
          return 0;
        } catch (Exception e) {
          stderr.writefln("Error: %s", e.msg);
          return 1;
        }

      case "remove":
        if (args.length < 3) {
          stderr.writeln("Usage: listremo root remove <name>");
          return 1;
        }
        if (rootRepo.removeRoot(args[2])) {
          if (fmt == OutputFormat.console) {
            writefln("Removed root '%s' and cataloged entries.", args[2]);
          }
          return 0;
        }
        stderr.writefln("Error: Root '%s' not found.", args[2]);
        return 1;

      case "set-path":
        if (args.length < 4) {
          stderr.writeln("Usage: listremo root set-path <name> <new_path>");
          return 1;
        }
        if (rootRepo.setPath(args[2], args[3])) {
          if (fmt == OutputFormat.console) {
            writefln("Updated path for '%s' -> '%s'", args[2], args[3]);
          }
          return 0;
        }
        stderr.writefln("Error: Root '%s' not found.", args[2]);
        return 1;

      case "list":
        auto roots = rootRepo.listRoots();
        outputRoots(roots, fmt, styler);
        return 0;

      default:
        stderr.writefln("Unknown root action '%s'.", action);
        return 1;
    }
  }

  int handleSyncCommand(
    ref Database db,
    string[] args,
    OutputFormat fmt,
    Styler styler
  ) {
    bool allFlag = false;
    bool forceHash = false;
    string targetRoot = null;

    for (size_t i = 1; i < args.length; i++) {
      if (args[i] == "--all") {
        allFlag = true;
      } else if (args[i] == "--force-hash") {
        forceHash = true;
      } else if (args[i].length > 0 && args[i][0] != '-') {
        targetRoot = args[i];
      }
    }

    if (!allFlag && targetRoot.length == 0) {
      stderr.writeln("Usage: listremo sync <name> [--force-hash] OR --all");
      return 1;
    }

    auto rootRepo = RootRepository(db);
    Root[] toSync;

    if (allFlag) {
      auto summaries = rootRepo.listRoots();
      foreach (ref s; summaries) {
        toSync ~= s.root;
      }
    } else {
      Root r;
      if (!rootRepo.findByName(targetRoot, r)) {
        stderr.writefln("Error: Root '%s' not registered.", targetRoot);
        return 1;
      }
      toSync ~= r;
    }

    bool hadError = false;
    foreach (ref root; toSync) {
      if (fmt == OutputFormat.console) {
        writefln("Syncing root '%s' (%s)...", root.name, root.path);
      }
      try {
        const stats = syncRoot(db, root, forceHash);
        if (fmt == OutputFormat.console) {
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

  int handleListCommand(
    ref Database db,
    string[] args,
    OutputFormat fmt,
    Styler styler,
    bool fullHash
  ) {
    string typeStr = "all";
    string sortStr = "path";
    string target = null;

    for (size_t i = 1; i < args.length; i++) {
      if (args[i] == "--type" && i + 1 < args.length) {
        typeStr = args[++i];
      } else if (args[i] == "--sort" && i + 1 < args.length) {
        sortStr = args[++i];
      } else if (args[i].length > 0 && args[i][0] != '-') {
        target = args[i];
      }
    }

    if (target.length == 0) {
      stderr.writeln("Usage: listremo list <target> [--type all|file|dir]");
      return 1;
    }

    const spec = TargetSpec.parse(target);
    auto rootRepo = RootRepository(db);
    Root root;
    if (!rootRepo.findByName(spec.rootName, root)) {
      stderr.writefln("Error: Root '%s' not found.", spec.rootName);
      return 1;
    }

    EntryType typeFilter = EntryType.all;
    if (typeStr == "file") {
      typeFilter = EntryType.file;
    } else if (typeStr == "dir") {
      typeFilter = EntryType.dir;
    }

    SortField sortField = SortField.path;
    if (sortStr == "size") {
      sortField = SortField.size;
    } else if (sortStr == "mtime") {
      sortField = SortField.mtime;
    }

    auto entryRepo = EntryRepository(db);
    auto entries = entryRepo.listEntries(
      root.id,
      spec.hasSubpath ? spec.subpath : null,
      typeFilter,
      sortField
    );

    outputEntries(entries, fmt, styler, fullHash);
    return 0;
  }

  int handleDuplicatesCommand(
    ref Database db,
    string[] args,
    OutputFormat fmt,
    Styler styler,
    bool fullHash
  ) {
    string typeStr = "file";
    bool skipEmpty = false;
    string target = null;

    for (size_t i = 1; i < args.length; i++) {
      if (args[i] == "--type" && i + 1 < args.length) {
        typeStr = args[++i];
      } else if (args[i] == "--skip-empty") {
        skipEmpty = true;
      } else if (args[i].length > 0 && args[i][0] != '-') {
        target = args[i];
      }
    }

    EntryType typeFilter = EntryType.file;
    if (typeStr == "dir") {
      typeFilter = EntryType.dir;
    } else if (typeStr == "all") {
      typeFilter = EntryType.all;
    }

    auto entryRepo = EntryRepository(db);
    Entry[] rawEntries;

    if (target.length > 0) {
      const spec = TargetSpec.parse(target);
      auto rootRepo = RootRepository(db);
      Root root;
      if (!rootRepo.findByName(spec.rootName, root)) {
        stderr.writefln("Error: Root '%s' not found.", spec.rootName);
        return 1;
      }
      rawEntries = entryRepo.listDuplicates(
        true,
        root.id,
        spec.hasSubpath ? spec.subpath : null,
        typeFilter,
        skipEmpty
      );
    } else {
      rawEntries = entryRepo.listDuplicates(
        false, 0, null, typeFilter, skipEmpty
      );
    }

    auto groups = entryRepo.groupDuplicates(rawEntries);
    outputDuplicates(groups, fmt, styler, fullHash);
    return 0;
  }

  int handleUniqueCommand(
    ref Database db,
    string[] args,
    OutputFormat fmt,
    Styler styler,
    bool fullHash
  ) {
    string typeStr = "file";
    bool skipEmpty = false;
    string target = null;

    for (size_t i = 1; i < args.length; i++) {
      if (args[i] == "--type" && i + 1 < args.length) {
        typeStr = args[++i];
      } else if (args[i] == "--skip-empty") {
        skipEmpty = true;
      } else if (args[i].length > 0 && args[i][0] != '-') {
        target = args[i];
      }
    }

    EntryType typeFilter = EntryType.file;
    if (typeStr == "dir") {
      typeFilter = EntryType.dir;
    } else if (typeStr == "all") {
      typeFilter = EntryType.all;
    }

    auto entryRepo = EntryRepository(db);
    Entry[] entries;

    if (target.length > 0) {
      const spec = TargetSpec.parse(target);
      auto rootRepo = RootRepository(db);
      Root root;
      if (!rootRepo.findByName(spec.rootName, root)) {
        stderr.writefln("Error: Root '%s' not found.", spec.rootName);
        return 1;
      }
      entries = entryRepo.listUnique(
        true,
        root.id,
        spec.hasSubpath ? spec.subpath : null,
        typeFilter,
        skipEmpty
      );
    } else {
      entries = entryRepo.listUnique(
        false, 0, null, typeFilter, skipEmpty
      );
    }

    outputUnique(entries, fmt, styler, fullHash);
    return 0;
  }
}
