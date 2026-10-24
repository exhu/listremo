# Code Review and Improvement Plan: `source/orglistremo`

- **Date:** 2026-10-24
- **Git Branch:** `main`
- **Git Commit:** `a2b14c4` (`a2b14c4e88f7f1f57d6d4af31a38493c7a6d8026`)
- **Reviewer Model:** Gemini 4 Argon (Medium)
- **Target Scope:** `source/orglistremo`

---

## 1. Buggy Code Findings

### 1.1 Non-Atomic Incremental Sync (`sync/scanner.d`, `db/repo.d`)
- **Location:** `source/orglistremo/sync/scanner.d:190-200`,
  `source/orglistremo/sync/scanner.d:300-303`,
  `source/orglistremo/sync/scanner.d:383-386`,
  `source/orglistremo/db/repo.d:361-371`
- **Problem:** During `ScannerContext.scanDir`, `flushBatch()` calls
  `entryRepo.upsertEntriesBatch(rootId, pendingBatch)` every `batchSize` (1000)
  entries. Each `upsertEntriesBatch` opens and commits its own transaction
  (`BEGIN IMMEDIATE; ... COMMIT;`) before the scan finishes and before
  `deleteStaleEntries` runs in `saveSyncEntries`.
  1. If a sync is interrupted (Ctrl-C, I/O error, exception) after one or more
     batches have flushed, the database is left in a half-updated state with new
     and modified entries committed, stale entries still present, and
     `last_sync` not updated.
  2. When `flushBatch()` fails, `catch (Exception)` silently swallows the error
     and allows `pendingBatch` to grow unboundedly, retrying on every subsequent
     file and directory.
- **Improvement Plan:** Wrap the entire root sync write phase in a single
  transaction, or stage scanned entries into a temporary table and swap at the
  end when updating `roots.last_sync`.

### 1.2 Multi-Target `list` Breaks Global Sorting (`app.d`)
- **Location:** `source/orglistremo/app.d:1016-1033`
- **Problem:** In `handleListCommand`, each `TargetSpec` in `specs` is queried
  separately via `entryRepo.listEntries(spec.rootName, filter)` and appended to
  `allEntries`. When a user passes multiple targets (e.g.
  `listremo list root1 root2 --sort size` or `--sort mtime`), each target batch
  is sorted internally, but `allEntries` is never sorted after concatenation.
- **Improvement Plan:** Either execute a single multi-target SQL query (like
  `HashQueryFilter.targets` does for `duplicates`/`unique`) with a single
  `ORDER BY` clause, or sort `allEntries` in memory according to
  `listArgs.sortField` before calling `outputEntries`.

### 1.3 Unsafe Raw File Copy for Live WAL Database Backup (`db/backup.d`)
- **Location:** `source/orglistremo/db/backup.d:64-86`,
  `source/orglistremo/app.d:846-854`,
  `source/orglistremo/importer.d:230-238`
- **Problem:** `writeDatabaseBackup` uses `std.file.copy(dbPath, backupPath)`
  while `ctx.db` is already open in WAL mode (`PRAGMA journal_mode = WAL`).
  Copying only the `.db` file without checkpointing or copying `.db-wal` can
  produce an outdated or corrupted backup if uncheckpointed WAL frames exist or
  another process writes concurrently.
- **Improvement Plan:** Use SQLite's `VACUUM INTO ?;` or the SQLite Online
  Backup API via the open `Database` handle, or run
  `PRAGMA wal_checkpoint(TRUNCATE);` before copying.

### 1.4 Parallel Sync (`sync --all -j N`) Concurrency Hazards (`app.d`)
- **Location:** `source/orglistremo/app.d:615-660`,
  `source/orglistremo/app.d:688-799`
- **Problem:**
  1. Each worker task in `runParallelSync` calls `openDatabaseChecked`, which
     executes `PRAGMA journal_mode = WAL;` and schema queries concurrently on
     the same database file. Concurrent `PRAGMA journal_mode` executions can
     trigger `SQLITE_BUSY` despite `busy_timeout`.
  2. Each worker calls `syncSingleRoot`, which writes multi-line status and
     error messages to `stdout` and `stderr` without synchronization across
     threads, interleaving console output.
- **Improvement Plan:** Open worker connections with a lightweight helper that
  only sets `PRAGMA foreign_keys = ON;` and `PRAGMA busy_timeout` (since WAL and
  schema version were already verified on the main connection), and guard
  `stdout`/`stderr` output in `syncSingleRoot` with the shared mutex.

### 1.5 Lock Ownership Not Verified on Release (`db/repo_locks.d`, `app.d`)
- **Location:** `source/orglistremo/db/repo_locks.d:83-96`,
  `source/orglistremo/app.d:739-741`
- **Problem:** `releaseLock(long rootId)` executes
  `DELETE FROM sync_locks WHERE root_id = ?;` without checking `pid` or
  `hostname`. If process A's lock is broken via `--break-lock` by process B
  while process A is still running, when process A eventually exits its
  `scope (exit) lockRepo.releaseLock(root.id)` will delete process B's lock.
- **Improvement Plan:** Pass `pid` and `hostname` to `releaseLock` (`WHERE
  root_id = ? AND pid = ? AND hostname = ?`) while keeping `breakLock(rootId)`
  unconditional.

### 1.6 Byte-Based String Slicing and Width Calculation (`output/console.d`)
- **Location:** `source/orglistremo/output/console.d:184-191`,
  `source/orglistremo/output/console.d:384-392`
- **Problem:** `truncatePathLeft` checks `path.length` (UTF-8 byte count) and
  slices `path[$ - (maxLen - 3) .. $]`. If a filename contains multi-byte UTF-8
  characters (e.g. Cyrillic, CJK, accented characters), slicing at an arbitrary
  byte index can split a code point and produce invalid UTF-8 sequences, and
  byte length overestimates visible terminal width.
- **Improvement Plan:** Slice on UTF-8 code point boundaries (e.g. using
  `std.utf.strideBack` or iterating `dchar` ranges) when truncating paths.

### 1.7 Unguarded Posix Imports in `output/console.d`
- **Location:** `source/orglistremo/output/console.d:65`,
  `source/orglistremo/output/console.d:202`,
  `source/orglistremo/output/console.d:395`
- **Problem:** Unlike `db/repo_locks.d` and `sync/scanner.d` which guard Posix
  calls with `version (Posix)`, `output/console.d` unconditionally imports
  `core.sys.posix.unistd` and `core.sys.posix.sys.ioctl`.
- **Improvement Plan:** Wrap Posix `isatty` and `ioctl` calls in
  `version (Posix)` blocks with a fallback for non-Posix platforms.

### 1.8 `isDiskDirEmpty` Masks Permission Errors (`sync/scanner.d`)
- **Location:** `source/orglistremo/sync/scanner.d:80-91`
- **Problem:** `isDiskDirEmpty` catches all `Exception`s and returns `false`
  (meaning "not empty"). Also, it skips symlinks (`if (!entry.isSymlink)`), so a
  directory containing only symlinks is treated as empty and triggers the
  empty-root fatal error if the database previously had entries.
- **Improvement Plan:** Return `false` on any directory entry (including
  symlinks) or let `scanDir` surface root directory read errors directly instead
  of swallowing exceptions in `isDiskDirEmpty`.

---

## 2. Slow Code Findings

### 2.1 Repeated `PRAGMA table_info(roots)` Queries (`db/repo.d`)
- **Location:** `source/orglistremo/db/repo.d:122, 142, 186, 207, 228, 270-278`
- **Problem:** `RootRepository.hasFreeSpaceColumn()` executes
  `PRAGMA table_info(roots);` on every single call to `findByName`, `findById`,
  `findByPattern`, `findByGlob`, and `listRoots`. During `list`, `duplicates`,
  `unique`, or `import` with multiple targets/roots, this metadata query is
  executed repeatedly.
- **Improvement Plan:** Cache the boolean result on `RootRepository` (e.g. a
  3-state enum `unknown`, `present`, `absent`) so `PRAGMA table_info(roots)` is
  queried at most once per `RootRepository` instance.

### 2.2 Per-Row Stale Entry Deletion (`db/repo.d`)
- **Location:** `source/orglistremo/db/repo.d:644-673`
- **Problem:** `deleteStaleEntries` loads all `rel_path` strings for `root_id`
  into a D array and prepares a per-row `DELETE` statement. For a root with
  hundreds of thousands of entries, building a full in-memory hash table of
  strings and executing individual `DELETE` statements is slow and memory-heavy.
- **Improvement Plan:** Add a `last_seen_sync` generation/timestamp column or a
  temporary table of seen paths/IDs and delete stale rows in a single set-based
  SQL query.

### 2.3 Full In-Memory Entry Copy During `import` (`importer.d`, `db/repo.d`)
- **Location:** `source/orglistremo/importer.d:341-343`,
  `source/orglistremo/importer.d:380-395`,
  `source/orglistremo/db/repo.d:352-359`
- **Problem:** `importNewRoot` and `processExistingRoot` load the entire
  `Entry[]` array of each source root into D memory via
  `srcEntryRepo.listEntries` and re-insert rows one by one. For existing roots,
  `getEntryPathsSet` also loads all destination `rel_path` strings into an
  associative array.
- **Improvement Plan:** Use SQLite `ATTACH DATABASE` to copy entries and compute
  diff counts directly inside SQLite (`INSERT INTO entries SELECT ... FROM
  src.entries WHERE root_id = ?`), avoiding materializing all rows in memory.

### 2.4 Quadratic/Repeated String Concatenation in Escaping Helpers
- **Location:** `source/orglistremo/db/repo.d:934-972`,
  `source/orglistremo/model.d:146-160`,
  `source/orglistremo/output/csv.d:84-107`
- **Problem:** `escapeLikePattern`, `escapeLike`, `unescapePatternEscapes`, and
  `escapeCsvField` append characters one-by-one using `res ~= c;` in a loop
  instead of returning the original slice when no special characters are present
  or using `std.array.appender`.
- **Improvement Plan:** Fast-path the common case where no escaping is needed by
  returning the input slice `s` directly, and use `appender!string` when
  allocating an escaped string.

### 2.5 Unindexed Aggregate Scan in `listRoots` (`db/repo.d`)
- **Location:** `source/orglistremo/db/repo.d:225-265`,
  `source/orglistremo/db/repo_migration.d:119-135`
- **Problem:** `listRoots` joins `roots` with `entries` and computes
  `SUM(CASE WHEN e.is_dir = 0 THEN e.size ELSE 0 END)`. Because there is no
  covering index on `entries(root_id, is_dir, size, rel_path)` and the root's
  own `'.'` directory entry already stores the root's `totalSize`
  (`scanner.d:378`), SQLite has to scan all entry rows of every root just to
  list roots or run `sync --all` without a pattern (`app.d:560`).
- **Improvement Plan:** In `handleSyncCommand` (`app.d:560`), call
  `rootRepo.findByPattern("%")` instead of `rootRepo.listRoots()` so
  `sync --all` does not aggregate all entries before syncing. For `listRoots`,
  consider a covering index or storing summary counts.

---

## 3. Duplicated Code Findings

### 3.1 Duplicated `listEntries` Overloads and Subpath Binding (`db/repo.d`)
- **Location:** `source/orglistremo/db/repo.d:423-507` vs
  `source/orglistremo/db/repo.d:509-602`, and
  `source/orglistremo/db/repo.d:803-823, 875-900`
- **Problem:** The two `EntryRepository.listEntries` overloads (by `long rootId`
  and by `string rootPattern`) duplicate ~80 lines of identical SQL filter
  construction, subpath wildcard detection, `ORDER BY` selection, and parameter
  binding. Moreover, subpath SQL construction and binding are already
  implemented in `buildSubpathSql` and `bindSubpath` at lines 803-900.
- **Improvement Plan:** Unify both `listEntries` overloads into a single private
  implementation that reuses `buildSubpathSql` and `bindSubpath`.

### 3.2 Duplicated `formatHash` Function (`output/console.d`, `output/html.d`)
- **Location:** `source/orglistremo/output/console.d:377-382` and
  `source/orglistremo/output/html.d:404-409`
- **Problem:** Identical `formatHash(string h, bool fullHash)` functions are
  defined privately in both `console.d` and `html.d`.
- **Improvement Plan:** Move `formatHash` into
  `source/orglistremo/output/units.d` and import it in both `console.d` and
  `html.d`.

### 3.3 Duplicated Entry Stats & Toolbar Rendering in `output/html.d`
- **Location:** `source/orglistremo/output/html.d:79-116` (`printHtmlEntries`)
  and `source/orglistremo/output/html.d:205-242` (`printHtmlUnique`)
- **Problem:** Both functions have nearly identical loops to count files, dirs,
  and `totalSize`, followed by identical toolbar HTML with Expand All / Collapse
  All buttons and tree rendering loops.
- **Improvement Plan:** Extract a shared helper `renderHtmlEntryTreePage` or
  `writeExpandCollapseToolbar(File outStream, string badgeText)`.

### 3.4 Duplicated `last_sync` / `free_space` Update SQL (`db/repo.d`)
- **Location:** `source/orglistremo/db/repo.d:159-181`
  (`RootRepository.updateLastSync`) and `source/orglistremo/db/repo.d:403-418`
  (`EntryRepository.saveSyncEntries`)
- **Problem:** `saveSyncEntries` duplicates the exact `if (hasFreeSpace)`
  `UPDATE roots SET last_sync = ...` logic from `RootRepository.updateLastSync`.
- **Improvement Plan:** Reuse a single shared helper or call
  `RootRepository(db).updateLastSync(...)` inside `saveSyncEntries`.

---

## 4. Confusing Code Findings

### 4.1 Dead Legacy Fields on `HashQueryFilter` (`db/repo.d`)
- **Location:** `source/orglistremo/db/repo.d:23-32`,
  `source/orglistremo/db/repo.d:751-784`,
  `source/orglistremo/app.d:1066-1090`
- **Problem:** `HashQueryFilter` has both `targets` (`TargetSpec[]`) and single
  target fields (`hasRoot`, `rootId`, `rootPattern`, `subpath`). Production code
  in `resolveHashQueryFilter` (`app.d:1066-1090`) only ever populates `targets`.
  When `targets.length > 0`, `buildFilterSql` and `bindFilters` return early and
  completely ignore `hasRoot`, `rootId`, `rootPattern`, and `subpath`. Those
  four fields are only used in unit tests in `db/repo.d`.
- **Improvement Plan:** Remove `hasRoot`, `rootId`, `rootPattern`, and `subpath`
  from `HashQueryFilter`, represent all target filters via `TargetSpec[]
  targets`, and update the `db/repo.d` unit tests to pass `targets`.

### 4.2 Artificial Argument Order Restriction on `list --hash` (`app.d`)
- **Location:** `source/orglistremo/app.d:945-951`
- **Problem:** `parseListArgs` rejects targets placed after `--hash <pattern>`
  (e.g., `listremo list --hash abc% myroot`), printing `"Target path must be
  passed before --hash"`. Since `--hash` consumes exactly one argument
  (`args[++i]`), there is no ambiguity in allowing targets after `--hash`.
- **Improvement Plan:** Remove the `if (parsed.hasHash)` error check on
  positional arguments in `parseListArgs` unless required by CLI spec.

### 4.3 Misleading `addedFiles` / `addedDirs` Count on Update (`importer.d`)
- **Location:** `source/orglistremo/importer.d:380-396`
- **Problem:** When `processExistingRoot` updates an existing root, it counts
  entries whose `relPath` was not in `existingPaths` and adds them to
  `summary.addedFiles` and `summary.addedDirs`, then calls `replaceRootEntries`
  which deletes all old entries and inserts `srcEntries`. If an updated root
  deleted 100 files and added 1, the summary reports `New entries added: 1
  files, 0 dirs` without mentioning removed or replaced entries.
- **Improvement Plan:** Clarify the summary label or track updated/removed entry
  counts alongside newly added paths.

### 4.4 Redundant `syncRoot` Overload (`sync/scanner.d`)
- **Location:** `source/orglistremo/sync/scanner.d:158-168`
- **Problem:** The second `syncRoot(ref Database db, const ref Root root, bool
  forceHash, SyncProgressCallback onProgress = null)` overload is never used by
  application code (which uses `SyncOptions`) and exists only for older tests in
  `scanner.d`.
- **Improvement Plan:** Migrate the three test calls in `scanner.d` to use
  `SyncOptions` and remove the redundant overload.

---

## 5. Codestyle Violations (`codestyle.md`)

### 5.1 Missing `package.d` Domain Facades & Public Re-exports
- **Rule:** *"Each functional subsystem must live in its own directory
  containing a `package.d` if there are more than one module in the subsystem...
  do not use public reexports, first-level modules inside the package are the
  public interface."* (`codestyle.md:78-87`)
- **Violations:**
  - `source/orglistremo/db/`, `source/orglistremo/output/`, and
    `source/orglistremo/sync/` each contain multiple modules, but none of them
    has a `package.d`.
  - `source/orglistremo/db/connection.d:6` uses a public re-export:
    `public import orglistremo.db.repo_migration : migrateDatabase;`.
- **Improvement Plan:** Remove `public import` from `db/connection.d` (import
  `orglistremo.db.repo_migration` directly where needed) and add domain facade
  `package.d` files if subsystems are intended as domain packages.

### 5.2 Missing `internal/` Subdirectories and `package(orglistremo)` Access
- **Rule:** *"All volatile logic, wire formats, OS bindings, and concrete driver
  classes belong in an `internal/` subdirectory... Do not mark internal symbols
  `public`. Use `package(<root_pkg>)` for symbols shared across the library, or
  file-level `private` for local routines."* (`codestyle.md:90-97`)
- **Violations:**
  - Every module except `app.d` leaves its top-level declarations as implicitly
    `public` instead of `package(orglistremo):`.
  - `source/orglistremo/db/repo.d:934-972` defines `escapeLikePattern` and
    `escapeLike` after the closing brace of `EntryRepository`, making them
    `public` module-level functions instead of `private`.
  - OS bindings (`statvfs` in `sync/scanner.d:55-78`, `kill` in
    `db/repo_locks.d:6-24`, `ioctl`/`isatty` in
    `output/console.d:65, 202, 394`) are placed directly in domain modules
    rather than an `internal/` module.
- **Improvement Plan:** Add `package(orglistremo):` at the top of internal
  modules, move `escapeLikePattern` and `escapeLike` under a module-level
  `private:` section in `db/repo.d`, and move OS-specific bindings into
  `source/orglistremo/internal/`.

### 5.3 Fields Declared Before Methods in Structs and Classes
- **Rule:** *"In a module, class, struct declare public methods and fields
  first, then protected, and then private... Declare methods first, then
  fields."* (`codestyle.md:108-112, 136`)
- **Violations:**
  - `source/orglistremo/output/console.d:13-47` (`Styler` declares field
    `bool enabled;` before methods).
  - `source/orglistremo/output/console.d:56` (`ConsoleProgressReporter` uses
    redundant `public:` label, and in `private:` at lines 126-135 declares
    fields before private methods `renderLine` and `formatProgressLine`).
  - `source/orglistremo/db/repo.d:267-301` (`RootRepository` private section
    declares `Database db;` before `hasFreeSpaceColumn` and `readRootRow`).
  - `source/orglistremo/db/repo.d:641-932` (`EntryRepository` private section
    declares `Database db;` before private methods).
  - `source/orglistremo/output/html.d:276-317` (`HtmlTreeNode` declares fields
    lines 277-285 before `this` and methods lines 287-313).
  - `source/orglistremo/sync/scanner.d:177-389` (`ScannerContext` declares 11
    fields lines 178-188 before methods lines 190-388).
- **Improvement Plan:** Reorder struct and class members so methods precede
  fields within each visibility section.

### 5.4 Functions Exceeding the 50-Line Limit
- **Rule:** *"Split long (>50 lines) or complex functions (which have different
  sematic blocks) into smaller."* (`codestyle.md:126-128`)
- **Violations:**
  - `source/orglistremo/output/html.d:555-741` (`writeHtmlStyles`: 187 lines)
  - `source/orglistremo/app.d:688-799` (`syncSingleRoot`: 112 lines)
  - `source/orglistremo/db/repo.d:509-602` (`listEntries(string, ...)`: 94
    lines)
  - `source/orglistremo/app.d:228-320` (`printUsage`: 93 lines)
  - `source/orglistremo/db/repo.d:423-507` (`listEntries(long, ...)`: 85 lines)
  - `source/orglistremo/app.d:533-613` (`handleSyncCommand`: 81 lines)
  - `source/orglistremo/output/html.d:121-196` (`printHtmlDuplicates`: 76 lines)
  - `source/orglistremo/app.d:460-524` (`parseSyncArgs`: 65 lines)
  - `source/orglistremo/sync/scanner.d:93-156` (`syncRoot`: 64 lines)
  - `source/orglistremo/output/html.d:12-70` (`printHtmlRoots`: 59 lines)
  - `source/orglistremo/app.d:913-964` (`parseListArgs`: 52 lines)
  - `source/orglistremo/db/repo.d:734-785` (`buildFilterSql`: 52 lines)
- **Improvement Plan:** Decompose each of these functions into focused helpers
  under 50 lines (e.g. split lock acquisition and scan execution in
  `syncSingleRoot`; unify `listEntries`; extract HTML header/table helpers).

### 5.5 Embedded Static Resources (`output/html.d`)
- **Rule:** *"Essencial static resources like fonts, images, shaders, texts, sql
  are embedded into final program via D's import strings if they are small
  (< 200KiB). Default directory for resources is 'assets'. Embedable assets via
  import must be placed into 'assets/<package_name>'... Put string imports into
  'assets.d' or into 'internal/assets.d'."* (`codestyle.md:47-56`)
- **Violation:** `source/orglistremo/output/html.d:542-741` embeds ~200 lines of
  static CSS and JavaScript via procedural `outStream.writeln(...)` statements.
- **Improvement Plan:** Move the static CSS and JS into
  `assets/orglistremo/report.css` (and/or template fragments) and expose them
  via `import("...")` in `source/orglistremo/internal/assets.d`.

### 5.6 Functions with More Than Three Parameters
- **Rule:** *"For more than three arguments consider adding a struct type passed
  as `in` or `ref`, which can be constructed with builder pattern."*
  (`codestyle.md:150-151`)
- **Violations:**
  - `source/orglistremo/db/repo.d:373-392` (`saveSyncEntries`: 5 and 6 params)
  - `source/orglistremo/db/repo.d:159-164` (`updateLastSync`: 4 params)
  - `source/orglistremo/db/repo.d:734-738` (`buildFilterSql`: 3 params, and
    `buildSingleTargetSql` at line 787: 5 params; `bindSingleTarget` at line
    858: 5 params; `bindSubpath` at line 875: 4 params)
  - `source/orglistremo/db/repo_locks.d:38-44` (`acquireLock`: 5 params)
  - `source/orglistremo/db/repo_migration.d:171-176` (`insertVersionRow`: 4
    params)
  - `source/orglistremo/importer.d:58-63, 99-104, 149-154, 290-295, 334-340,
    358-365` (4 to 6 params)
  - `source/orglistremo/app.d:615-621, 662-668` (`runParallelSync` and
    `runSequentialSync`: 5 params)
- **Improvement Plan:** Group related parameters into structs (for example,
  `SyncSaveParams`, `LockRequest`, `VersionRow`, `ImportContext`).

### 5.7 Overuse of `auto` When Type Is Not Obvious on RHS
- **Rule:** *"Use `auto` when declaring types only when it's required by the
  language (e.g. templates, voldemort types) or the type is obvious, e.g.
  `auto myInstance = new MyClass()`."* (`codestyle.md:61-68`)
- **Violations:**
  - `source/orglistremo/app.d:638`:
    `auto threadDb = openDatabaseChecked(...).db;`
  - `source/orglistremo/db/repo.d:44, 59, 83, 104, 112, 125, 145, 166, 174`:
    `auto stmt = db.prepare(...);` and `auto results = stmt.execute();`
  - `source/orglistremo/db/repo_locks.d:58, 113`: `auto row = results.front;`
  - `source/orglistremo/output/html.d:248`: `auto app = appender!string();`
- **Improvement Plan:** Replace `auto` with explicit types (`Database`,
  `Statement`, `ResultRange`, `Row`) where the right-hand side is a function or
  method call rather than a `new Type()` or type constructor.

### 5.8 Missing `const` on Non-Mutated Local Variables and Struct Fields
- **Rule:** *"Prefer declaring local variables and fields const if they are not
  meant to change."* (`codestyle.md:45, 59`)
- **Violations:**
  - `source/orglistremo/output/html.d:112, 185, 238`:
    `HtmlTreeRoot[] trees = buildHtmlTree(...);` (can be `const trees = ...` or
    `const(HtmlTreeRoot)[]`)
  - `source/orglistremo/output/html.d:357`:
    `string[] parts = splitPath(e.relPath);` (can be `const string[] parts`)
  - `source/orglistremo/sync/scanner.d:178-185`: `ScannerContext` fields
    `rootId`, `rootName`, `forceHash`, `batchSize` are never mutated after
    initialization.
- **Improvement Plan:** Mark immutable local variables and configuration fields
  `const`.
