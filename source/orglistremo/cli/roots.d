module orglistremo.cli.roots;

import orglistremo.db.repo : RootRepository;
import orglistremo.model : Root;
import orglistremo.pattern : isWildcard;
import std.stdio : stderr, writefln;

package(orglistremo):

struct RootLookupOptions {
  bool useGlob = false;
  string dbLabel = null;
}

void reportNoRootMatch(
  string pattern,
  bool useGlob = false,
  string dbLabel = null
) {
  const string suffix = dbLabel.length > 0 ? " in '" ~ dbLabel ~ "'" : "";
  if (isWildcard(pattern, useGlob)) {
    stderr.writefln("Error: No roots match pattern '%s'%s.", pattern, suffix);
  } else {
    stderr.writefln("Error: Root '%s' not found%s.", pattern, suffix);
  }
}

bool resolveRoots(
  ref RootRepository rootRepo,
  string pattern,
  out Root[] matched,
  in RootLookupOptions opts = RootLookupOptions.init
) {
  matched = opts.useGlob
    ? rootRepo.findByGlob(pattern)
    : rootRepo.findByPattern(pattern);
  if (matched.length > 0) {
    return true;
  }
  reportNoRootMatch(pattern, opts.useGlob, opts.dbLabel);
  return false;
}

bool resolveRoots(
  ref RootRepository rootRepo,
  in string[] patterns,
  out Root[] matched,
  in RootLookupOptions opts = RootLookupOptions.init
) {
  if (patterns.length == 0) {
    const string wildcard = opts.useGlob ? "*" : "%";
    matched = opts.useGlob
      ? rootRepo.findByGlob(wildcard)
      : rootRepo.findByPattern(wildcard);
    return true;
  }

  bool[long] seenIds;
  foreach (pattern; patterns) {
    Root[] found;
    if (!resolveRoots(rootRepo, pattern, found, opts)) {
      return false;
    }
    foreach (ref r; found) {
      if (r.id !in seenIds) {
        seenIds[r.id] = true;
        matched ~= r;
      }
    }
  }
  return true;
}

unittest {
  import d2sqlite3 : Database;
  import orglistremo.db.connection : openDatabase;

  Database db = openDatabase(":memory:");
  RootRepository rootRepo = RootRepository(db);
  rootRepo.addRoot("alpha_1", "/mnt/a1");
  rootRepo.addRoot("alpha_2", "/mnt/a2");
  rootRepo.addRoot("beta", "/mnt/b");

  Root[] matched;
  assert(resolveRoots(rootRepo, "alpha%", matched));
  assert(matched.length == 2);

  Root[] deduped;
  assert(resolveRoots(rootRepo, ["alpha%", "alpha_1", "beta"], deduped));
  assert(deduped.length == 3);

  Root[] missing;
  assert(!resolveRoots(rootRepo, "missing", missing));
  assert(!resolveRoots(rootRepo, "missing%", missing));
}
