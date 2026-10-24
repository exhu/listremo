module orglistremo.cli.query_cmd;

import d2sqlite3 : Database;
import orglistremo.cli.args : ArgCursor, parseChoice;
import orglistremo.cli.roots : resolveRoots, RootLookupOptions;
import orglistremo.db.repo :
  EntryRepository, HashQueryFilter, ListEntriesFilter, RootRepository;
import orglistremo.model :
  Entry, EntryType, Root, SortField, TargetSpec;
import orglistremo.output.formatter :
  outputDuplicates, outputEntries, outputUnique;
import orglistremo.output.options : OutputOptions;
import std.stdio : stderr, writefln, writeln;

package(orglistremo):

struct ListArgs {
  string[] targets;
  EntryType typeFilter = EntryType.all;
  SortField sortField = SortField.path;
  bool useGlob;
  string hashPattern;
  bool hasHash;
}

struct DuplicateOrUniqueArgs {
  string[] targets;
  EntryType typeFilter = EntryType.file;
  bool skipEmpty;
  bool useGlob;
}

bool parseListArgs(string[] args, out ListArgs parsed) {
  ArgCursor cur = ArgCursor(args);
  while (!cur.empty()) {
    string val;
    if (cur.matchFlag("--type")) {
      if (!cur.nextValue("--type", val) ||
          !parseChoice(val, parsed.typeFilter, "--type")) {
        return false;
      }
    } else if (cur.matchFlag("--sort")) {
      if (!cur.nextValue("--sort", val) ||
          !parseChoice(val, parsed.sortField, "--sort")) {
        return false;
      }
    } else if (cur.matchFlag("--glob")) {
      parsed.useGlob = true;
    } else if (cur.matchFlag("--hash")) {
      if (!cur.nextValue("--hash", parsed.hashPattern)) {
        return false;
      }
      parsed.hasHash = true;
    } else if (cur.isOption()) {
      stderr.writefln("Unknown flag '%s' for list.", cur.front());
      return false;
    } else {
      if (parsed.hasHash) {
        stderr.writefln(
          "Unexpected argument '%s'. Target path must be passed before --hash.",
          cur.front()
        );
        return false;
      }
      parsed.targets ~= cur.take();
    }
  }

  if (parsed.targets.length == 0 && !parsed.hasHash) {
    stderr.writeln(
      "Usage: listremo list [<target>...] [--hash <pattern>] [--glob] " ~
      "[--type all|file|dir] [--sort path|size|mtime]"
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

  RootRepository rootRepo = RootRepository(db);
  TargetSpec[] specs;
  if (!resolveTargetSpecs(
    rootRepo,
    listArgs.targets.length > 0 ? listArgs.targets : [""],
    listArgs.useGlob,
    specs
  )) {
    return 1;
  }

  Entry[] allEntries = collectListEntries(db, specs, listArgs);
  if (specs.length > 1) {
    sortEntries(allEntries, listArgs.sortField);
  }

  outputEntries(allEntries, opts);
  return 0;
}

bool parseDuplicateOrUniqueArgs(
  string cmdName,
  string[] args,
  out DuplicateOrUniqueArgs parsed
) {
  ArgCursor cur = ArgCursor(args);
  while (!cur.empty()) {
    string val;
    if (cur.matchFlag("--type")) {
      if (!cur.nextValue("--type", val) ||
          !parseChoice(val, parsed.typeFilter, "--type")) {
        return false;
      }
    } else if (cur.matchFlag("--glob")) {
      parsed.useGlob = true;
    } else if (cur.matchFlag("--skip-empty")) {
      parsed.skipEmpty = true;
    } else if (cur.isOption()) {
      stderr.writefln("Unknown flag '%s' for %s.", cur.front(), cmdName);
      return false;
    } else {
      parsed.targets ~= cur.take();
    }
  }
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

void sortEntries(Entry[] entries, SortField sortField) {
  import std.algorithm.sorting : sort;

  switch (sortField) {
    case SortField.size:
      entries.sort!((a, b) {
        if (a.size != b.size) {
          return a.size > b.size;
        }
        return (a.rootName != b.rootName)
          ? (a.rootName < b.rootName)
          : (a.relPath < b.relPath);
      });
      break;
    case SortField.mtime:
      entries.sort!((a, b) {
        if (a.mtime != b.mtime) {
          return a.mtime > b.mtime;
        }
        return (a.rootName != b.rootName)
          ? (a.rootName < b.rootName)
          : (a.relPath < b.relPath);
      });
      break;
    case SortField.path:
    default:
      entries.sort!((a, b) {
        return (a.rootName != b.rootName)
          ? (a.rootName < b.rootName)
          : (a.relPath < b.relPath);
      });
      break;
  }
}

private:

bool resolveTargetSpecs(
  ref RootRepository rootRepo,
  in string[] rawTargets,
  bool useGlob,
  out TargetSpec[] specs
) {
  const RootLookupOptions lookupOpts = RootLookupOptions(useGlob, null);
  foreach (t; rawTargets) {
    const TargetSpec spec = TargetSpec.parse(t, useGlob);
    Root[] matched;
    if (!resolveRoots(rootRepo, spec.rootName, matched, lookupOpts)) {
      return false;
    }
    specs ~= spec;
  }
  return true;
}

Entry[] collectListEntries(
  ref Database db,
  in TargetSpec[] specs,
  in ListArgs listArgs
) {
  EntryRepository entryRepo = EntryRepository(db);
  Entry[] allEntries;
  bool[long] seenIds;

  foreach (ref const spec; specs) {
    ListEntriesFilter filter;
    filter.subpath = spec.hasSubpath ? spec.subpath : null;
    filter.typeFilter = listArgs.typeFilter;
    filter.sort = listArgs.sortField;
    filter.useGlob = listArgs.useGlob;
    filter.hashPattern = listArgs.hasHash ? listArgs.hashPattern : null;

    const batch = entryRepo.listEntriesByPattern(spec.rootName, filter);
    foreach (ref const e; batch) {
      if (e.id !in seenIds) {
        seenIds[e.id] = true;
        allEntries ~= e;
      }
    }
  }
  return allEntries;
}

bool resolveHashQueryFilter(
  ref RootRepository rootRepo,
  in DuplicateOrUniqueArgs args,
  out HashQueryFilter filter
) {
  filter.typeFilter = args.typeFilter;
  filter.skipEmpty = args.skipEmpty;
  filter.useGlob = args.useGlob;

  if (args.targets.length == 0) {
    return true;
  }
  return resolveTargetSpecs(
    rootRepo, args.targets, args.useGlob, filter.targets
  );
}

unittest {
  ListArgs listArgs;
  assert(
    parseListArgs(
      ["list", "myroot", "other:/sub", "--type", "file", "--sort", "size"],
      listArgs
    )
  );
  assert(listArgs.targets == ["myroot", "other:/sub"]);
  assert(listArgs.typeFilter == EntryType.file);
  assert(listArgs.sortField == SortField.size);

  ListArgs invalidType;
  assert(!parseListArgs(["list", "myroot", "--type", "invalid"], invalidType));

  ListArgs missingTypeVal;
  assert(!parseListArgs(["list", "myroot", "--type"], missingTypeVal));

  DuplicateOrUniqueArgs dupArgs;
  assert(
    parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "--type", "all", "--skip-empty"], dupArgs
    )
  );
  assert(dupArgs.typeFilter == EntryType.all);
  assert(dupArgs.skipEmpty);

  DuplicateOrUniqueArgs dupGlobArgs;
  assert(
    parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "r*", "b*:/sub", "--glob"], dupGlobArgs
    )
  );
  assert(dupGlobArgs.targets == ["r*", "b*:/sub"]);
  assert(dupGlobArgs.useGlob);

  DuplicateOrUniqueArgs dupUnknown;
  assert(
    !parseDuplicateOrUniqueArgs(
      "duplicates", ["duplicates", "--unknown"], dupUnknown
    )
  );

  Entry[] toSort = [
    Entry(1, 1, "rA", "f1", ".", "f1", false, 100, 1000, "h1"),
    Entry(2, 1, "rA", "f2", ".", "f2", false, 500, 3000, "h2"),
    Entry(3, 2, "rB", "f3", ".", "f3", false, 200, 2000, "h3"),
    Entry(4, 2, "rB", "f4", ".", "f4", false, 800, 4000, "h4")
  ];
  sortEntries(toSort, SortField.size);
  assert(toSort[0].size == 800);
  assert(toSort[1].size == 500);
  assert(toSort[2].size == 200);
  assert(toSort[3].size == 100);

  sortEntries(toSort, SortField.mtime);
  assert(toSort[0].mtime == 4000);
  assert(toSort[1].mtime == 3000);
  assert(toSort[2].mtime == 2000);
  assert(toSort[3].mtime == 1000);
}
