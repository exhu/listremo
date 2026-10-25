# Changelog

## 0.18.0

- Added `--dry-run` option to `sync` command to scan storage roots and display
  paths that would be synced (new or modified files and directories) along with
  ignored paths without calculating hashes or modifying the database.

## 0.17.0

- Added per-root ignore list support (`root_ignores` table, schema v4) storing
  unique relative glob patterns per storage root.
- Added `listremo ignore <root-name-pattern> [ignore-list-file]` command to
  display current ignore lists or append unique glob patterns from a file and
  report added patterns per root.
- Added `listremo ignore-delete <root-name-pattern>` command to clear ignore
  lists for matching roots and report removed patterns.
- Updated `sync` to skip directories and files matching root ignore globs and
  list ignored paths upon completion.
- Updated `import` to copy ignore patterns for newly imported roots and merge
  unique ignore patterns into existing roots.

## 0.16.0

- Replaced multiple overloads of `backupIfRequested()` in `cli/context.d` with
  the `BackupRequestBuilder` pattern.
- Included borrowed `Database*` pointer in `BackupRequest` to avoid copying
  database connection handles, and consolidated backup execution into a
  single `backupIfRequested(in BackupRequest req)` function.
- Standardized backup prompt handling across `migrate`, `sync`, and `import`
  CLI commands.

## 0.15.0

- Added database backup snapshot flow to `sync` command matching `migrate` and
  `import`, creating an atomic `VACUUM INTO` backup before sync execution.
- Added `--no-backup` CLI option to `sync` to bypass the interactive backup
  prompt when syncing on-disk databases.

## 0.14.0

- Externalized HTML report CSS and JavaScript into `assets/orglistremo/`
  (`report.css`, `report.js`) embedded at compile time via
  `source/orglistremo/internal/assets.d`.
- Cleaned up `output/` subsystem (`html.d`, `console.d`, `formatter.d`),
  extracting `writePageHeader`, `writeTreePageHeader`, `HtmlTreeNode.setMeta`,
  and `dispatchFormat`, and added `output/package.d`.
- Cleaned up `sync/` subsystem (`hasher.d`, `scanner.d`), returning
  `DirectoryHashResult` from `hashDirectory`, extracting `ScannerContext`
  helpers (`joinRelPath`, `makeProgress`, `appendEntry`), and added
  `sync/package.d`.
- Completed full `codestyle.md` audit across all `source/orglistremo/` modules
  (<= 50 lines per function, <= 3 parameters per function, methods before
  fields, explicit types, and 80-column limit).

## 0.13.0

- Extracted cross-cutting output options (`OutputFormat`, `ColorMode`,
  `OutputOptions`, `Styler`, `info`) into `output/options.d` and sync progress
  structures (`SyncPhase`, `SyncProgress`, `SyncIssue` with `describe`) into
  `sync/progress.d` to resolve subsystem layering inversions.
- Created `cli/` subsystem (`cli/package.d`) with shared CLI helpers:
  `cli/context.d` (`DbContext`, `requireWritable`, `promptBackupPath`,
  `backupIfRequested`), `cli/args.d` (`ArgCursor`, `isFlag`, `parseChoice`),
  `cli/roots.d` (`resolveRoots`, `reportNoRootMatch`), and `cli/usage.d`
  (`usageText`, `printUsage`), breaking the cyclic dependency with `app.d` and
  removing interactive I/O from `db/backup.d`.
- Decomposed `app.d` subcommands into `cli/root_cmd.d`, `cli/sync_cmd.d`
  (unifying `SyncRunResult`, `SyncRunConfig`, and splitting `syncSingleRoot`
  into lock, scan, and reporting helpers), `cli/query_cmd.d`, and
  `cli/migrate_cmd.d`.
- Moved `importer.d` to `cli/import_cmd.d`, grouped import state into
  `ImportContext`, deduplicated `countNewEntries`, clarified update summary
  counters (`updatedFiles`, `updatedDirs`, `removedEntries`), and batched entry
  writes via `upsertEntriesBatch`.

## 0.12.0

- Consolidated database transaction management via `withTransaction` in
  `db/transaction.d` across repositories, schema migrations, and root imports.
- Extracted schema existence helpers (`tableExists`, `columnExists`) into
  `db/internal/schema.d` and SQL query/binding helpers (`entrySelectSql`,
  `bindNullable`, `buildSubpathSql`, `bindSubpath`) into `db/internal/sql.d`.
- Renamed `db/repo_migration.d` to `db/migration.d`, added `db/package.d`
  subsystem facade, and removed `public import` re-export from `connection.d`.
- Cached `roots.free_space` column detection per `RootRepository` instance and
  deduplicated root queries via `selectRoots` and lock row reading via
  `readLockRow`.
- Consolidated `EntryRepository` listing into `listEntriesByRootId` and
  `listEntriesByPattern` backed by `queryEntries`, refactored duplicate/unique
  queries to use a `WITH scoped_entries` CTE, and removed legacy fields from
  `HashQueryFilter`.
- Enforced `codestyle.md` across `db/` (`package(orglistremo)` visibility,
  methods before fields, explicit `Statement`/`ResultRange`/`Row` types,
  parameter structs, and <= 50-line functions).

## 0.11

- Extracted test helpers into `internal/testutil.d` (`TempDir`,
  `createLegacyV0Db`, `captureOutput`) and eliminated hardcoded temporary
  paths across tests to prevent collisions under parallel execution.
- Centralized POSIX and platform system calls (`isPidAlive`,
  `getDeviceFreeSpace`, `isTty`, `isStdoutTty`, `getTerminalWidth`,
  `getLocalHostName`) into `internal/os.d` scoped to `package(orglistremo)`.
- Created `pattern.d` centralizing wildcard detection, `NamePattern`, and SQL
  `LIKE` escaping with zero-allocation fast paths for clean strings.
- Fixed `_` wildcard escaping in hash search queries (`BUG-16`).
- Consolidated model and formatting helpers in `model.d` and `output/units.d`
  (`emptyHash`, `groupDuplicates`, `countEntries`, `summarizeDuplicates`,
  `makeEntry`, and `formatHash`).

## 0.10

- Hardened database backup against live WAL corruption using SQLite online
  backup (`VACUUM INTO ?;`).
- Fixed HTML escaping in `escapeHtml` to process arbitrary non-UTF-8 filenames
  byte-by-byte without throwing `UnicodeException`.
- Made console path truncation in `truncatePathLeft` byte-safe by slicing on
  valid UTF-8 code point boundaries.
- Fixed directory empty check in `isDiskDirEmpty` to recognize symlinks and
  propagate filesystem access errors.
- Decoupled Unix epoch timestamp formatting from `"never"` sync indicator in
  `formatUnixTime` and introduced `formatLastSync`.
- Added strict CLI root input validation, root name colon rejection, path
  normalization, and option validation for `--progress-interval` and `-j`.
- Enforced thread-safe worker database connections (`openWorkerDatabase`) and
  synchronized console output in parallel sync.
- Added lock release ownership verification ensuring locks are released only by
  matching PID and hostname.
- Ensured global sort order preservation across multiple targets in `list`.
- Fixed migration pragma restoration on failure and applied write pragmas.
- Fixed import TOCTOU race by classifying existing roots inside transaction.

## 0.9

- Added `import` command (`listremo import <db_file> [<root_pattern>...]`) to
  import new storage roots and update existing roots with more recent
  synchronization dates from another database of the same schema version.
- Added `--no-update` and `--no-backup` options to `import`, optional root
  pattern filtering, and a completion summary with added file/dir counts and
  elapsed duration.
- Extracted shared database backup helpers into `orglistremo.db.backup`.

## 0.8

- Added support for specifying multiple target patterns in `list`,
  `duplicates`, and `unique` commands.

## 0.7

- Added target pattern matching (`LIKE` and `--glob`) support to `duplicates`
  and `unique` commands.

## 0.6

- Added `--glob` option for SQLite `GLOB` wildcard matching (`*`, `?`, `[...]`)
  and `--hash <pattern>` option for filtering entries by SHA-256 hash in `list`.

## 0.5

- Added SQLite `LIKE` wildcard pattern matching (`%`) for root names and
  subpaths across `root list`, `sync`, and `list` commands.

## 0.4

- Added standalone HTML output format (`--format html` and `--html`) featuring
  collapsible directory trees.

## 0.3

- Recorded available device free space on storage roots during `sync` and
  displayed free space in `root list` (schema v3).
- Displayed total synchronization duration on finish.

## 0.2

- Added parallel root synchronization (`-j` / `--jobs`), batched database
  writes during scanning, per-root sync locks (`sync_locks` table, schema v2)
  with stale lock detection and `--break-lock`, and configurable
  `--busy-timeout`.

## 0.1

- Initial release with storage root management (`root add`, `remove`,
  `set-path`, `list`), incremental filesystem synchronization (`sync`) with
  streaming SHA-256 file hashes and Merkle directory hashes, progress reporting,
  `list`/`files`, `duplicates`, `unique`, console and RFC 4180 CSV formatters,
  and database schema versioning with `migrate` and backup support (schema v1).
