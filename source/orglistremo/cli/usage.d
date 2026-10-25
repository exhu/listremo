module orglistremo.cli.usage;

import orglistremo.app_version : appVersion;
import std.stdio : writefln, writeln;

package(orglistremo):

enum usageText =
`Usage: listremo [global options] <command> [arguments...]

Commands:
  root add <name> <path>       Register a new storage root
  root remove <name>           Remove a root and entries
  root set-path <name> <path>  Update mount path of a root
  root list [pattern]          List registered storage roots
  sync <name|pattern> [opts]   Synchronize a storage root
  sync --all [pattern] [opts]  Synchronize matching storage roots
  list [<target>...] [opts]    List files & dirs (alias: files)
  duplicates [<target>...]     Find duplicate files/dirs
  unique [<target>...]         Find unique files/dirs
  import <db> [<pattern>...]   Import roots from another database
  migrate [--no-backup]        Migrate database schema

List Options & Target Syntax:
  <target>...                  One or more target roots / paths:
                                 <root>         e.g. backup
                                 <root>:/<path> e.g. backup:/photos
                                 :/<path>       across all roots
                               Wildcards: % (LIKE) or * (with --glob).
                               Target is optional before --hash.
  --glob                       Match target with SQLite GLOB (*, ?, [...])
  --hash <pattern>             Filter entries by SHA-256 via SQLite LIKE
  --type <all|file|dir>        Filter entry type (default: all)
  --sort <path|size|mtime>     Sort entries (default: path)

Duplicates & Unique Options:
  --glob                       Match target with SQLite GLOB (*, ?, [...])
  --type <all|file|dir>        Filter entry type (default: file)
  --skip-empty                 Skip empty files and directories

Sync Options:
  --no-backup                  Skip saving a database backup
  --force                      Sync when root path is empty but database is not
  --force-hash                 Recompute SHA-256 for all files
  --no-progress                Disable in-place progress display
  --break-lock                 Break active sync lock if present
  -j, --jobs <N>               Parallel sync jobs for --all (def: 1)
  --progress-interval <ms>     Progress refresh interval (ms, def: 1000)

Import Options:
  --no-backup                  Skip saving a database backup
  --no-update                  Only import new roots; skip updates

Migrate Options:
  --no-backup                  Skip saving a database backup

Global Options:
  --db <path>                  SQLite database path
  --format <console|csv|html>  Output format (default: console)
  --csv                        Shorthand for --format csv
  --html                       Shorthand for --format html
  --color <auto|always|never>  Control ANSI colors
  --full-hash                  Show full 64-char hashes
  --busy-timeout <ms>          SQLite busy timeout in ms (def: 60000)`;

void printUsage() {
  writefln("listremo version %s", appVersion);
  writeln(usageText);
}

unittest {
  import std.algorithm.searching : canFind;
  assert(usageText.canFind("Usage: listremo"));
  assert(usageText.canFind("--busy-timeout"));
}
