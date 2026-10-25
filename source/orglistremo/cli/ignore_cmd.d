module orglistremo.cli.ignore_cmd;

import orglistremo.cli.context : DbContext, requireWritable;
import orglistremo.cli.roots : resolveRoots;
import orglistremo.db.repo : RootRepository;
import orglistremo.model : Root;
import orglistremo.output.options : OutputOptions;
import orglistremo.pattern : parseIgnorePatterns;
import std.file : exists, isFile, readText;
import std.stdio : File, stderr, stdout, writefln, writeln;

package(orglistremo):

int handleIgnoreCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      "Usage: listremo ignore <root-name-pattern> [ignore-list-file]"
    );
    return 1;
  }

  const string rootPattern = args[1];
  if (rootPattern.length == 0) {
    stderr.writeln("Error: Root name pattern cannot be empty.");
    return 1;
  }

  if (args.length == 3 && !requireWritable(ctx)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(ctx.db);
  Root[] matched;
  if (!resolveRoots(rootRepo, rootPattern, matched)) {
    return 1;
  }

  if (args.length == 2) {
    printIgnoreLists(rootRepo, matched);
    return 0;
  }

  return applyIgnoreListFile(rootRepo, matched, args[2]);
}

int handleIgnoreDeleteCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (args.length != 2) {
    stderr.writeln("Usage: listremo ignore-delete <root-name-pattern>");
    return 1;
  }

  const string rootPattern = args[1];
  if (rootPattern.length == 0) {
    stderr.writeln("Error: Root name pattern cannot be empty.");
    return 1;
  }

  if (!requireWritable(ctx)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(ctx.db);
  Root[] matched;
  if (!resolveRoots(rootRepo, rootPattern, matched)) {
    return 1;
  }

  deleteIgnoreLists(rootRepo, matched);
  return 0;
}

void printIgnoreLists(
  ref RootRepository rootRepo,
  in Root[] roots,
  File outStream = stdout
) {
  foreach (ref const root; roots) {
    const string[] patterns = rootRepo.listIgnorePatterns(root.id);
    if (patterns.length == 0) {
      outStream.writefln("%s: (no ignore patterns)", root.name);
    } else {
      outStream.writefln("%s (%d):", root.name, patterns.length);
      foreach (pat; patterns) {
        outStream.writefln("  %s", pat);
      }
    }
  }
}

struct IgnoreUpdateRequest {
  Root[] roots;
  string[] patterns;
}

void applyIgnoreUpdate(
  ref RootRepository rootRepo,
  in IgnoreUpdateRequest req,
  File outStream = stdout
) {
  foreach (ref const root; req.roots) {
    const string[] added = rootRepo.addIgnorePatterns(root.id, req.patterns);
    if (added.length > 0) {
      outStream.writefln(
        "Updated ignore list for root '%s' (added %d):",
        root.name,
        added.length
      );
      foreach (pat; added) {
        outStream.writefln("  + %s", pat);
      }
    } else {
      outStream.writefln(
        "Ignore list for root '%s' already contains all specified patterns.",
        root.name
      );
    }
  }
}

void deleteIgnoreLists(
  ref RootRepository rootRepo,
  in Root[] roots,
  File outStream = stdout
) {
  foreach (ref const root; roots) {
    const string[] removed = rootRepo.clearIgnorePatterns(root.id);
    if (removed.length > 0) {
      outStream.writefln(
        "Deleted ignore list for root '%s' (removed %d):",
        root.name,
        removed.length
      );
      foreach (pat; removed) {
        outStream.writefln("  - %s", pat);
      }
    } else {
      outStream.writefln(
        "Root '%s' has no ignore patterns to delete.",
        root.name
      );
    }
  }
}

private:

int applyIgnoreListFile(
  ref RootRepository rootRepo,
  in Root[] matched,
  string filePath
) {
  string[] patterns;
  if (!readIgnoreFile(filePath, patterns)) {
    return 1;
  }
  applyIgnoreUpdate(rootRepo, IgnoreUpdateRequest(matched.dup, patterns));
  return 0;
}

bool readIgnoreFile(string filePath, out string[] patterns) {
  if (filePath.length == 0 || !exists(filePath) || !isFile(filePath)) {
    stderr.writefln(
      "Error: Ignore list file '%s' does not exist.", filePath
    );
    return false;
  }
  try {
    const string content = readText(filePath);
    patterns = parseIgnorePatterns(content);
    return true;
  } catch (Exception e) {
    stderr.writefln(
      "Error reading ignore list file '%s': %s", filePath, e.msg
    );
    return false;
  }
}

unittest {
  import d2sqlite3 : Database;
  import orglistremo.db.connection : openDatabase;
  import orglistremo.db.schema_version : schemaVersion;
  import orglistremo.internal.testutil : captureOutput, TempDir;
  import std.algorithm.searching : canFind;
  import std.file : write;

  Database db = openDatabase(":memory:");
  DbContext ctx = DbContext(db, ":memory:", schemaVersion, false);
  RootRepository rootRepo = RootRepository(db);
  rootRepo.addRoot("alpha_1", "/mnt/a1");
  rootRepo.addRoot("alpha_2", "/mnt/a2");
  rootRepo.addRoot("beta", "/mnt/b");

  OutputOptions opts;
  opts.styler.enabled = false;

  TempDir tmp = TempDir("ignore_cmd");
  const string ignoreFile = tmp.subPath("ignores.txt");
  write(ignoreFile, "*~\n#*#\n*~\n\n  build/  \n");

  // Invalid usages
  assert(handleIgnoreCommand(ctx, ["ignore"], opts) == 1);
  assert(handleIgnoreCommand(ctx, ["ignore", ""], opts) == 1);
  assert(
    handleIgnoreCommand(ctx, ["ignore", "a", "b", "c"], opts) == 1
  );
  assert(
    handleIgnoreCommand(ctx, ["ignore", "missing%", ignoreFile], opts) == 1
  );
  assert(
    handleIgnoreCommand(
      ctx, ["ignore", "alpha%", tmp.subPath("no_such.txt")], opts
    ) == 1
  );

  // Read-only context blocks updates and deletes, allows listing
  DbContext roCtx = DbContext(db, ":memory:", 0, true);
  assert(
    handleIgnoreCommand(roCtx, ["ignore", "alpha%", ignoreFile], opts) == 1
  );
  assert(handleIgnoreCommand(roCtx, ["ignore", "alpha%"], opts) == 0);
  assert(
    handleIgnoreDeleteCommand(roCtx, ["ignore-delete", "alpha%"], opts) == 1
  );

  // Add patterns to multiple roots via pattern
  assert(
    handleIgnoreCommand(ctx, ["ignore", "alpha%", ignoreFile], opts) == 0
  );

  Root a1;
  Root a2;
  Root b;
  assert(rootRepo.findByName("alpha_1", a1));
  assert(rootRepo.findByName("alpha_2", a2));
  assert(rootRepo.findByName("beta", b));

  assert(rootRepo.listIgnorePatterns(a1.id) == ["*~", "#*#", "build/"]);
  assert(rootRepo.listIgnorePatterns(a2.id) == ["*~", "#*#", "build/"]);
  assert(rootRepo.listIgnorePatterns(b.id).length == 0);

  // Verify output of printIgnoreLists, applyIgnoreUpdate, deleteIgnoreLists
  const listOut = captureOutput((File f) {
    printIgnoreLists(rootRepo, [a1, b], f);
  });
  assert(listOut.canFind("alpha_1 (3):"));
  assert(listOut.canFind("  *~"));
  assert(listOut.canFind("  #*#"));
  assert(listOut.canFind("  build/"));
  assert(listOut.canFind("beta: (no ignore patterns)"));

  const addOut = captureOutput((File f) {
    applyIgnoreUpdate(
      rootRepo,
      IgnoreUpdateRequest([a1], ["*~", "*.tmp"]),
      f
    );
  });
  assert(addOut.canFind("Updated ignore list for root 'alpha_1' (added 1):"));
  assert(addOut.canFind("  + *.tmp"));
  assert(!addOut.canFind("  + *~"));

  const delOut = captureOutput((File f) {
    deleteIgnoreLists(rootRepo, [a1, b], f);
  });
  assert(
    delOut.canFind("Deleted ignore list for root 'alpha_1' (removed 4):")
  );
  assert(delOut.canFind("  - *~"));
  assert(delOut.canFind("  - *.tmp"));
  assert(delOut.canFind("Root 'beta' has no ignore patterns to delete."));

  // Test handleIgnoreDeleteCommand via CLI entry
  assert(
    handleIgnoreDeleteCommand(ctx, ["ignore-delete"], opts) == 1
  );
  assert(
    handleIgnoreDeleteCommand(ctx, ["ignore-delete", ""], opts) == 1
  );
  assert(
    handleIgnoreDeleteCommand(ctx, ["ignore-delete", "missing"], opts) == 1
  );
  assert(
    handleIgnoreDeleteCommand(ctx, ["ignore-delete", "alpha%"], opts) == 0
  );
  assert(rootRepo.listIgnorePatterns(a2.id).length == 0);
}
