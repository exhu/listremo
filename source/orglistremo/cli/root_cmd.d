module orglistremo.cli.root_cmd;

import orglistremo.cli.context : DbContext, requireWritable;
import orglistremo.db.repo : RootRepository;
import orglistremo.output.formatter : outputRoots;
import orglistremo.output.options : info, OutputOptions;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath;
import std.stdio : stderr, writefln, writeln;

package(orglistremo):

int handleRootCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (args.length < 2) {
    stderr.writeln("Usage: listremo root <add|remove|set-path|list>");
    return 1;
  }
  RootRepository rootRepo = RootRepository(ctx.db);
  const string action = args[1];

  switch (action) {
    case "add":
      if (!requireWritable(ctx)) {
        return 1;
      }
      return handleRootAdd(rootRepo, args, opts);
    case "remove":
      if (!requireWritable(ctx)) {
        return 1;
      }
      return handleRootRemove(rootRepo, args, opts);
    case "set-path":
      if (!requireWritable(ctx)) {
        return 1;
      }
      return handleRootSetPath(rootRepo, args, opts);
    case "list":
      return handleRootList(rootRepo, args, opts);
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
  const string name = args[2];
  if (name.length == 0) {
    stderr.writeln("Error: Root name cannot be empty.");
    return 1;
  }
  import std.algorithm.searching : canFind;
  if (name.canFind(':')) {
    stderr.writeln("Error: Root name cannot contain ':'.");
    return 1;
  }
  const string rawPath = args[3];
  if (rawPath.length == 0) {
    stderr.writeln("Error: Root path cannot be empty.");
    return 1;
  }
  const string normPath = buildNormalizedPath(absolutePath(rawPath));
  try {
    rootRepo.addRoot(name, normPath);
    info(opts, format("Registered root '%s' -> '%s'", name, normPath));
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
    info(
      opts,
      format("Removed root '%s' and cataloged entries.", args[2])
    );
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
  const string name = args[2];
  if (name.length == 0) {
    stderr.writeln("Error: Root name cannot be empty.");
    return 1;
  }
  const string rawPath = args[3];
  if (rawPath.length == 0) {
    stderr.writeln("Error: Root path cannot be empty.");
    return 1;
  }
  const string normPath = buildNormalizedPath(absolutePath(rawPath));
  if (rootRepo.setPath(name, normPath)) {
    info(opts, format("Updated path for '%s' -> '%s'", name, normPath));
    return 0;
  }
  stderr.writefln("Error: Root '%s' not found.", name);
  return 1;
}

int handleRootList(
  ref RootRepository rootRepo,
  string[] args,
  in OutputOptions opts
) {
  if (args.length > 3) {
    stderr.writeln("Usage: listremo root list [pattern]");
    return 1;
  }
  const string pattern = args.length == 3 ? args[2] : null;
  const summaries = rootRepo.listRoots(pattern);
  outputRoots(summaries, opts);
  return 0;
}

unittest {
  import d2sqlite3 : Database;
  import orglistremo.db.connection : openDatabase;
  import orglistremo.db.schema_version : schemaVersion;
  import orglistremo.model : Root;

  Database db = openDatabase(":memory:");
  DbContext ctx = DbContext(db, ":memory:", schemaVersion, false);
  OutputOptions testOpts;
  testOpts.styler.enabled = false;

  assert(
    handleRootCommand(ctx, ["root", "add", "r1", "/mnt/r1"], testOpts) == 0
  );
  assert(handleRootCommand(ctx, ["root", "list"], testOpts) == 0);
  assert(
    handleRootCommand(
      ctx, ["root", "set-path", "r1", "/mnt/new"], testOpts
    ) == 0
  );
  assert(handleRootCommand(ctx, ["root", "remove", "r1"], testOpts) == 0);

  // Validation & normalization tests
  assert(
    handleRootCommand(ctx, ["root", "add", "bad:name", "/mnt"], testOpts) == 1
  );
  assert(
    handleRootCommand(ctx, ["root", "add", "", "/mnt"], testOpts) == 1
  );
  assert(
    handleRootCommand(ctx, ["root", "add", "valid", ""], testOpts) == 1
  );
  assert(
    handleRootCommand(ctx, ["root", "set-path", "", "/mnt"], testOpts) == 1
  );
  assert(
    handleRootCommand(ctx, ["root", "set-path", "r1", ""], testOpts) == 1
  );
  assert(
    handleRootCommand(
      ctx, ["root", "add", "norm_root", "./custom_rel"], testOpts
    ) == 0
  );
  Root normCheck;
  assert(RootRepository(ctx.db).findByName("norm_root", normCheck));
  assert(normCheck.path == buildNormalizedPath(absolutePath("./custom_rel")));
}
