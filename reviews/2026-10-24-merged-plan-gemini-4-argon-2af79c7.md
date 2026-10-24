# Merged Code Review & Agent Execution Plan: `source/orglistremo`

- **Date:** 2026-10-24
- **Git Branch:** `main`
- **Git Commit:** `2af79c7` (reviews conducted at `a2b14c4` / `2af79c7`)
- **Synthesized By:** Gemini 4 Argon (Medium)
- **Source Reviews:**
  - [opus-review.md](opus-review.md) (`Opus`)
  - [2026-10-24-gemini-4-argon-a2b14c4.md](2026-10-24-gemini-4-argon-a2b14c4.md)
    (`Gemini`)
- **Target Scope:** `source/orglistremo` (18 modules, ~7.5k lines incl. tests)

---

## 1. Executive Summary & Synthesis Notes

Both reviews independently identified the most critical correctness,
concurrency, and maintainability problems in `orglistremo`:
- **Live WAL backup hazard** (`Opus B1`, `Gemini 1.3`)
- **Parallel sync concurrency & unsynchronized output** (`Opus B4`,
  `Gemini 1.4`)
- **Non-atomic batch sync & swallowed flush errors** (`Opus B6`, `Gemini 1.1`)
- **Repeated `PRAGMA table_info` & unindexed `sync --all` aggregate**
  (`Opus B5/B10`, `Gemini 2.1/2.5`)
- **Heavy SQL & CLI duplication** (`Opus D1-D11`, `Gemini 3.1-3.4`)
- **Confusing APIs & `codestyle.md` violations** (`Opus C1-C15`,
  `Gemini 4.1-4.4, 5.1-5.8`)

### Conflict Resolution Between Reviews
1. **`list --hash` argument order (`Opus D2` vs `Gemini 4.2`):**
   `Opus D2` mentions preserving the "target before `--hash`" rule if needed,
   whereas `Gemini 4.2` notes it is an artificial restriction in `parseListArgs`
   because `--hash` takes a single argument. **Resolution:** Keep existing unit
   tests passing; only relax the restriction if the CLI spec and unit tests in
   `app.d` are updated intentionally.
2. **Module layout vs `codestyle.md` (`Opus Section 5` vs `Gemini 5.1-5.2`):**
   `codestyle.md` requires every multi-module subsystem (`cli/`, `db/`,
   `output/`, `sync/`) to include a `package.d` facade without `public import`
   re-exports, and internal symbols to use `package(orglistremo)` rather than
   `public`. The target layout in Section 3 incorporates both.
3. **Atomic sync & stale-entry deletion (`Opus B6` vs `Gemini 1.1, 2.2`):**
   Instead of changing the persistent schema just to track seen paths, use a
   connection-local `TEMP` table (e.g. `temp.seen_paths`) inside a single
   transaction (`withTransaction`) per root sync, or propagate flush errors
   immediately and roll back on failure.

---

## 2. Consolidated Findings Catalog

### 2.1 Buggy & Risky Code

- **BUG-01** (`Opus B1`, `Gemini 1.3`, **High**):
  `source/orglistremo/db/backup.d:64-86` uses `std.file.copy` on a live WAL
  database (`connection.d:75-80`). Uncheckpointed `.db-wal` frames or
  concurrent writers can yield a stale or corrupt backup. Fix with
  `VACUUM INTO ?;`.
- **BUG-02** (`Opus B2`, **High**):
  `source/orglistremo/output/html.d:247-272` (`escapeHtml`) iterates with
  `foreach (dchar c; s)`. Non-UTF-8 Linux filenames throw `UTFException`.
  Iterate `char`/`ubyte` instead.
- **BUG-03** (`Opus B3`, **High**):
  `source/orglistremo/db/repo.d:40-41, 111` & `app.d:401-458` validate CLI
  input with `assert` in `addRoot`/`setPath` (crashes debug builds, ignored in
  release). Relative root paths are not normalized with
  `absolutePath`/`buildNormalizedPath`, and root names with `:` break
  `TargetSpec.parse`.
- **BUG-04** (`Opus B4`, `Gemini 1.4`, **High**):
  `source/orglistremo/app.d:615-660, 688-799` (`runParallelSync`): worker
  threads call `openDatabaseChecked` (re-running `PRAGMA journal_mode = WAL`
  concurrently, risking `SQLITE_BUSY`), ignore `isReadOnly`, let exceptions
  escape `pool.parallel`, and print interleaved multi-line logs without holding
  the console mutex.
- **BUG-05** (`Opus B6`, `Gemini 1.1`, **High**):
  `source/orglistremo/sync/scanner.d:190-200, 300-303, 383-386`: `flushBatch`
  commits partial 1000-entry transactions before `deleteStaleEntries` and
  silently catches `Exception` (allowing `pendingBatch` to grow and retrying on
  every entry). Interrupted syncs leave mixed new + stale entries.
- **BUG-06** (`Gemini 1.2`, **Medium**):
  `source/orglistremo/app.d:1016-1033`: `handleListCommand` queries each
  `TargetSpec` separately and appends to `allEntries`, breaking global
  `--sort size` / `--sort mtime` order across multiple targets.
- **BUG-07** (`Gemini 1.5`, **Medium**):
  `source/orglistremo/db/repo_locks.d:83-96` & `app.d:739-741`:
  `releaseLock(rootId)` deletes by `root_id` without checking `pid` and
  `hostname`. If Process A's lock was broken via `--break-lock` by Process B,
  Process A's `scope (exit)` deletes Process B's active lock.
- **BUG-08** (`Gemini 1.6`, `Opus B16`, **Medium**):
  `source/orglistremo/output/console.d:184-191, 242-270, 384-392`:
  `truncatePathLeft` slices UTF-8 strings by byte index
  (`path[$ - (maxLen - 3) .. $]`), which can split multi-byte code points and
  produce invalid UTF-8; `format("%-18s")` pads by byte count rather than
  display columns.
- **BUG-09** (`Gemini 1.8`, **Medium**):
  `source/orglistremo/sync/scanner.d:80-91`: `isDiskDirEmpty` catches all
  `Exception`s (masking permission errors as "not empty") and ignores symlinks
  (`if (!entry.isSymlink)`), treating a symlink-only root as an empty root
  error.
- **BUG-10** (`Opus B8`, **Low**):
  `source/orglistremo/db/repo_migration.d:20-24`: `migrateDatabase` sets
  `PRAGMA query_only = OFF` before `BEGIN`, never restores it on failure, and
  never applies `applyWritePragmas` after succeeding.
- **BUG-11** (`Opus B9`, **Low**):
  `source/orglistremo/importer.d:117-126`: `executeImportRoots` classifies
  existing vs new roots before `BEGIN IMMEDIATE` (TOCTOU race with concurrent
  `root add`).
- **BUG-12** (`Opus B7`, **Low**):
  `source/orglistremo/app.d:489-504, 601`: `--progress-interval 0` is accepted
  despite error text saying "positive integer"; `-j/--jobs` is silently ignored
  without `--all`; "Root '%s' not registered." vs "not found." wording is
  inconsistent.
- **BUG-13** (`Opus B11`, `Gemini 1.7`, **Low**):
  `source/orglistremo/output/console.d:65, 202, 395`: Unconditional
  `core.sys.posix.*` imports without `version (Posix)` guards.
- **BUG-14** (`Opus B12`, **Low**):
  Fixed temp directory names in 10 unit tests
  (`buildPath(tempDir(), "listremo_..._test")`) collide under parallel test
  execution.
- **BUG-15** (`Opus B13`, **Low**):
  `source/orglistremo/output/units.d:20-25`: `formatUnixTime(<= 0)` returns
  `"never"`, which is wrong for file `mtime` values at or before epoch. Split
  `formatLastSync` from `formatUnixTime`.
- **BUG-16** (`Opus B14, B15`, **Low**):
  `source/orglistremo/db/repo.d:502-504, 902-909`: `--hash` binds raw `LIKE`
  patterns (`_` is wildcard) while path patterns escape `_`;
  `bindDuplicateOrUniqueParams` binds filters twice assuming identical
  outer/inner SQL placeholder order (use CTE or document).

### 2.2 Slow Code Findings

- **PERF-01** (`Opus B5`, `Gemini 2.5`):
  `source/orglistremo/app.d:560-563` & `db/repo.d:225-265`: `sync --all` calls
  `rootRepo.listRoots()`, running an unindexed `SUM`/`COUNT` join across all
  `entries` just to get root metadata. Use `findByPattern("%")` in `sync --all`.
- **PERF-02** (`Opus B10`, `Gemini 2.1`):
  `source/orglistremo/db/repo.d:270-278`: `hasFreeSpaceColumn` runs
  `PRAGMA table_info(roots)` on every `findBy*` and `listRoots` call. Cache the
  result per `RootRepository` instance.
- **PERF-03** (`Gemini 2.2`):
  `source/orglistremo/db/repo.d:644-673`: `deleteStaleEntries` loads all
  `rel_path` strings for a root into D memory and runs per-row `DELETE`
  statements. Replace with a set-based SQL delete using a `TEMP` table of seen
  paths/IDs.
- **PERF-04** (`Gemini 2.3`):
  `source/orglistremo/importer.d:341-343, 380-395`: `import` loads all source
  `Entry[]` structs into D memory and re-inserts row by row. Optimize via
  batched/streaming copy or `ATTACH DATABASE`.
- **PERF-05** (`Gemini 2.4`):
  `source/orglistremo/db/repo.d:934-972`, `model.d:146-160`,
  `output/csv.d:84-107`: Escaping helpers (`escapeLikePattern`, `escapeLike`,
  `unescapePatternEscapes`, `escapeCsvField`) concatenate char-by-char
  (`res ~= c`). Fast-path when no special chars exist and use `appender!string`.

### 2.3 Duplicated Code Findings

- **DUP-01** (`Opus D1`):
  `app.d` <-> `importer.d` cyclic import for `DbContext` and
  `printReadOnlyError` (repeated 5 times). Extract `cli/context.d` with
  `requireWritable`.
- **DUP-02** (`Opus D2`):
  5 hand-written CLI option loops (`parseSyncArgs`, `parseListArgs`,
  `parseDuplicateOrUniqueArgs`, `parseMigrateArgs`, `parseImportArgs`) + enum
  parsers. Extract `cli/args.d` (`ArgCursor`, `parseChoice`).
- **DUP-03** (`Opus D3`):
  Root pattern lookup + "No roots match pattern" error reporting repeated 4
  times; ID deduplication repeated twice. Extract `cli/roots.d`.
- **DUP-04** (`Opus D4`):
  Backup-before-write block duplicated in `migrate` (`app.d:846-854`) and
  `import` (`importer.d:230-238`). Move interactive prompt out of `db/backup.d`
  into CLI (`backupIfRequested`).
- **DUP-05** (`Opus D5`):
  Pattern wildcard/escape helpers split across `model.d` and `db/repo.d`;
  `useGlob ? hasGlobWildcard(x) : hasPatternWildcard(x)` repeated 5 times.
  Extract `pattern.d` (`isWildcard`, `NamePattern`).
- **DUP-06** (`Opus D6`, `Gemini 3.1, 3.4`):
  `db/repo.d` & `db/` SQL duplication:
  1. Two 90-line `listEntries` overloads duplicating `buildSubpathSql` and
     `bindSubpath`.
  2. 3 copies of entry column list (`entrySelectSql`).
  3. 4 root `SELECT` methods with `freeCol` formatting (`selectRoots`).
  4. Nullable bindings (`bindNullable`).
  5. Duplicated `UPDATE roots SET last_sync` (`updateLastSync` vs
     `saveSyncEntries`).
  6. 6 copies of `BEGIN IMMEDIATE / scope(failure) ROLLBACK / COMMIT`
     (`db/transaction.d`).
  7. 3 copies of `sqlite_master` table existence check (`db/internal/schema.d`).
  8. Duplicated lock row read in `repo_locks.d`.
  9. Duplicated `PRAGMA busy_timeout` setup.
- **DUP-07** (`Opus D7`):
  Scattered Posix calls (`isPidAlive`, `getDeviceFreeSpace`, `isatty`,
  `getTerminalWidth`, `Socket.hostName`). Consolidate into `internal/os.d`.
- **DUP-08** (`Opus D8`, `Gemini 3.2, 3.3`):
  Output layer duplication:
  1. Identical `formatHash` in `console.d` and `html.d` -> move to `units.d`.
  2. Duplicated entry & duplicate group counting -> `EntryStats` /
     `DuplicateStats`.
  3. 3x HTML page header + Expand/Collapse toolbar.
  4. 3x `HtmlTreeNode` meta assignment.
  5. ~190 lines of inline CSS/JS `writeln` -> `assets/orglistremo/`.
  6. 4x 3-way format dispatch in `formatter.d`.
  7. 12x `if (opts.format == OutputFormat.console) writefln(...)`.
  8. `formatEntryPath` vs `Entry.fullPath`.
  9. Type label constants (`"D"/"F"`, `"DIR"/"FILE"`).
  10. Unused imports & duplicate unit tests in `console.d`.
- **DUP-09** (`Opus D9`):
  Scanner & model helpers: child `relPath` join (2x), `SyncProgress`
  construction (4x), batch flush check (2x), 10-arg `Entry(...)` construction
  in ~60 tests + custom `findLastSlash`/`findColon` (use
  `lastIndexOf`/`indexOf` + `Entry` factory), `SyncIssue.describe()`.
- **DUP-10** (`Opus D10`):
  `source/orglistremo/importer.d:345-354, 383-392`: Duplicated added file/dir
  loop in `importNewRoot` and `processExistingRoot`.
- **DUP-11** (`Opus D11`):
  Test boilerplate: 10x temp dir setup/teardown, 4x legacy v0 DB creation, 3x
  `File.tmpfile` output capture. Extract `internal/testutil.d`.

### 2.4 Confusing Code Findings

- **CONF-01** (`Opus C1`):
  `db/repo.d:934-972`: Rename `escapeLikePattern` -> `userPatternToLike` and
  `escapeLike` -> `escapeLikeLiteral` with doc comments.
- **CONF-02** (`Opus C2`, `Gemini 4.1`):
  `db/repo.d:23-32`: `HashQueryFilter` has dead legacy fields (`hasRoot`,
  `rootId`, `rootPattern`, `subpath`) ignored whenever `targets` is non-empty.
  Remove legacy fields and use `targets` everywhere.
- **CONF-03** (`Opus C3`):
  `db/repo.d:612-639`: `groupDuplicates` is a pure function on
  `EntryRepository` with duplicated group init logic. Move to `model.d`.
- **CONF-04** (`Opus C4`):
  `sync/hasher.d:42-69`: `hashDirectory` mutates caller's slice in-place (sorts
  it) and uses `out` params. Return a struct and document sorting.
- **CONF-05** (`Opus C5`):
  Magic `"0"` empty hash literal scattered across `hasher.d`, `repo.d`,
  `console.d`, `html.d`. Define `enum emptyHash = "0";` in `model.d`.
- **CONF-06** (`Opus C6`, `Gemini 4.4`):
  Overloads instead of default parameters or distinct names: remove test-only
  `syncRoot` overload in `scanner.d:158-168`; merge `ConsoleProgressReporter`
  ctors using default arg; rename `listEntries(long)` / `listEntries(string)`
  to `listEntriesByRootId` / `listEntriesByPattern`.
- **CONF-07** (`Opus C7`):
  Dead/redundant code: `ConsoleProgressReporter.finish()`, `onProgress` vs
  `update` alias, redundant `row.length > 5` check in `readRootRow`. Note: keep
  `breakLock` distinct from `releaseLock` once `releaseLock` checks
  `pid`/`hostname` (`BUG-07`).
- **CONF-08** (`Opus C8`):
  Layering inversions: `db/backup.d` prompts user and imports `output.console`;
  `output.console` imports `sync.scanner`; `OutputFormat`/`ColorMode` live in
  `model.d`. Extract `output/options.d` and `sync/progress.d`.
- **CONF-09** (`Opus C9`, `Gemini 5.1`):
  `db/connection.d:6` has `public import orglistremo.db.repo_migration`. Rename
  `repo_migration.d` to `migration.d` and remove `public import`.
- **CONF-10** (`Opus C11, C12`):
  `sync/scanner.d`: `batchSize` default duplicated from `SyncOptions`;
  redundant `entryRepo is null` checks; `stats.totalSize` accumulated per file
  then overwritten with root dir size at line 378.
- **CONF-11** (`Opus C13`):
  `app.d:615-686`: `runParallelSync` vs `runSequentialSync` have asymmetric
  signatures and return results via return value + `out bool`. Unify with
  `SyncRunResult`.
- **CONF-12** (`Gemini 4.3`):
  `importer.d:380-396`: `processExistingRoot` replaces all root entries on
  update but only reports `"New entries added: X files, Y dirs"`, hiding
  replaced/removed counts. Clarify summary counters/labels.

### 2.5 Codestyle Violations (`codestyle.md`)

- **STYLE-01** (`Gemini 5.1`):
  **Subsystem `package.d` facades & no public re-exports**
  (`codestyle.md:78-87`): Add `package.d` to multi-module subsystems (`db/`,
  `output/`, `sync/`, `cli/`) and remove `public import` from
  `db/connection.d:6`.
- **STYLE-02** (`Gemini 5.2`):
  **Visibility & `internal/` boundaries** (`codestyle.md:90-97`): Use
  `package(orglistremo):` instead of implicit `public` for internal modules;
  make `userPatternToLike`/`escapeLikeLiteral` `private`; move OS bindings into
  `internal/os.d`.
- **STYLE-03** (`Gemini 5.3`):
  **Visibility order & methods before fields** (`codestyle.md:108-112, 136`):
  Declare `public` before `private`, and methods before fields in `Styler`,
  `ConsoleProgressReporter`, `RootRepository`, `EntryRepository`,
  `HtmlTreeNode`, and `ScannerContext`.
- **STYLE-04** (`Opus C10`, `Gemini 5.4`):
  **50-line function limit** (`codestyle.md:126-128`): Split functions >50
  lines: `writeHtmlStyles` (187L), `syncSingleRoot` (112L), `listEntries`
  (94L/85L), `printUsage` (93L), `handleSyncCommand` (81L),
  `printHtmlDuplicates` (76L), `parseSyncArgs` (65L), `syncRoot` (64L),
  `printHtmlRoots` (59L), `parseListArgs` (52L), `buildFilterSql` (52L).
- **STYLE-05** (`Opus D8.5`, `Gemini 5.5`):
  **Embedded static assets** (`codestyle.md:47-56`): Move inline CSS/JS from
  `output/html.d:525-741` to `assets/orglistremo/report.css` and
  `assets/orglistremo/report.js`, loaded via `import(...)` in
  `source/orglistremo/internal/assets.d` (configure `stringImportPaths "assets"`
  in `dub.sdl`).
- **STYLE-06** (`Gemini 5.6`):
  **Max 3 function parameters** (`codestyle.md:150-151`): Introduce parameter
  structs where functions exceed 3 arguments (`saveSyncEntries`,
  `updateLastSync`, `acquireLock`, `insertVersionRow`, `importer.d` helpers,
  `runParallelSync`/`runSequentialSync`).
- **STYLE-07** (`Gemini 5.7`):
  **Explicit types over `auto`** (`codestyle.md:61-68`): Replace `auto` with
  explicit types (`Database`, `Statement`, `ResultRange`, `Row`,
  `Appender!string`) in `app.d`, `db/repo.d`, `db/repo_locks.d`,
  `output/html.d`.
- **STYLE-08** (`Gemini 5.8`):
  **`const` on non-mutated locals and fields** (`codestyle.md:45, 59`): Mark
  immutable locals (`trees`, `parts` in `html.d`) and config fields (`rootId`,
  `rootName`, `forceHash`, `batchSize` in `ScannerContext`) `const`.

---

## 3. Target Module Architecture

```text
assets/orglistremo/
  report.css
  report.js
source/orglistremo/
  app.d                 main(), global options, top-level command dispatch
  app_version.d         appVersion constant
  config.d              environment & default paths
  model.d               Root, Entry (+factory), TargetSpec, DuplicateGroup,
                        EntryStats, DuplicateStats, emptyHash, groupDuplicates
  pattern.d             wildcard checks, NamePattern, LIKE/GLOB escaping
  cli/
    package.d           CLI subsystem facade
    context.d           DbContext, requireWritable, backupIfRequested
    args.d              ArgCursor, isFlag, parseChoice
    roots.d             resolveRoots, reportNoRootMatch
    root_cmd.d          root add/remove/set-path/list
    sync_cmd.d          sync command (sequential/parallel, lock lifecycle)
    query_cmd.d         list, duplicates, unique commands
    migrate_cmd.d       migrate command
    import_cmd.d        import command (formerly importer.d)
    usage.d             usage string constants
  db/
    package.d           DB subsystem facade
    connection.d        openDatabaseChecked, openWorkerDatabase, pragmas
    transaction.d       withTransaction helper
    migration.d         migrateDatabase (formerly repo_migration.d)
    repo.d              RootRepository, EntryRepository
    repo_locks.d        LockRepository (with owner-verified releaseLock)
    backup.d            VACUUM INTO snapshot backup (no CLI prompts)
    schema_version.d    schemaVersion constant
    internal/
      sql.d             entrySelectSql, bindNullable, subpath/type SQL helpers
      schema.d          tableExists, columnExists
  sync/
    package.d           Sync subsystem facade
    progress.d          SyncPhase, SyncProgress, SyncIssue
    scanner.d           syncRoot, ScannerContext
    hasher.d            hashFile, hashDirectory (returns DirectoryHashResult)
  output/
    package.d           Output subsystem facade
    options.d           OutputOptions, OutputFormat, ColorMode, Styler, info()
    formatter.d         OutputWriter / unified format dispatch
    console.d           console tables & progress reporter
    csv.d               CSV rendering
    html.d              HTML tree rendering
    units.d             formatBytes, formatUnixTime, formatLastSync, formatHash
  internal/
    os.d                Posix/fallback: pid, hostname, statvfs, isatty, ioctl
    assets.d            string imports for report.css and report.js
    testutil.d          version(unittest): TempDir, createLegacyV0Db,
                        captureOutput
```

---

## 4. Step-by-Step Agent Execution Plan

### Mandatory Rules for Executing Agents (`AGENTS.md` & `codestyle.md`)
- Use `ldc2` for all builds and tests (`dub build --compiler=ldc2`,
  `dub test --compiler=ldc2`).
- Keep all lines in `*.d` and `*.md` files at **80 columns max**. Verify after
  every phase with:
  ```bash
  rdmd --compiler=ldc2 \
    .agents/skills/check-line-length/scripts/check_line_length.d
  ```
- Never put absolute paths in source or markdown files; use relative paths.
- Increment `appVersion` in `source/orglistremo/app_version.d` and update
  `CHANGELOG.md` after each phase that introduces changes or bug fixes.
- If any phase alters persistent SQLite tables or indexes, increment
  `schemaVersion` in `source/orglistremo/db/schema_version.d` and update
  `migrateDatabase` in `source/orglistremo/db/connection.d` (or `migration.d`).

---

### Phase 1: Critical Bug, Concurrency & Data-Safety Fixes
**Goal:** Fix all high/medium correctness bugs before structural refactoring.

1. **Safe WAL Database Backup (`BUG-01`)**
   - In `source/orglistremo/db/backup.d`, update `writeDatabaseBackup` to take
     an open `ref Database` (or open read-only if needed), remove any existing
     destination file if overwriting, and execute `VACUUM INTO ?;` with the
     target backup path bound as a parameter.
   - Add a unit test verifying backup consistency while WAL frames are active.

2. **Byte-Safe HTML Escaping & UTF-8 Console Truncation (`BUG-02`, `BUG-08`)**
   - In `source/orglistremo/output/html.d` (`escapeHtml`), iterate over
     `char c` (or `ubyte`) instead of `dchar` so arbitrary non-UTF-8 byte
     sequences in filenames do not throw `UTFException`.
   - In `source/orglistremo/output/console.d` (`truncatePathLeft`), slice on
     valid UTF-8 code-point boundaries instead of raw byte indices.
   - Add unit tests for invalid UTF-8 bytes in `escapeHtml` and multi-byte UTF-8
     filenames in `truncatePathLeft`.

3. **CLI Root Validation & Path Normalization (`BUG-03`, `BUG-12`)**
   - In `source/orglistremo/db/repo.d` (`addRoot`, `setPath`), replace user
     input `assert` checks with `enforce` / explicit validation errors.
   - In `source/orglistremo/app.d` (`handleRootAdd`, `handleRootSetPath`):
     - Reject empty root names or root names containing `:` (which break
       `TargetSpec.parse`).
     - Normalize paths via `absolutePath` and `buildNormalizedPath` before
       storing.
   - In `source/orglistremo/app.d` (`parseSyncArgs`):
     - Reject `--progress-interval 0` (must be `>= 1`).
     - Warn or error when `-j/--jobs` is passed without `--all`.
     - Standardize root lookup error messages to `"Root '%s' not found."`.

4. **Parallel Sync Safety & Lock Ownership (`BUG-04`, `BUG-07`, `PERF-01`)**
   - In `source/orglistremo/db/connection.d`, add a lightweight worker-thread
     connection helper (`openWorkerDatabase`) that sets `PRAGMA foreign_keys =
     ON` and `PRAGMA busy_timeout` without re-running `PRAGMA journal_mode =
     WAL` or schema checks.
   - In `source/orglistremo/app.d` (`runParallelSync` / `syncSingleRoot`):
     - Wrap the `pool.parallel` loop body in `try / catch (Exception e)` so
       worker exceptions are recorded as sync failures instead of crashing.
     - Synchronize console status/error output across workers using the shared
       `Mutex`.
   - In `source/orglistremo/app.d:560`, replace `rootRepo.listRoots()` with
     `rootRepo.findByPattern("%")` for `sync --all`.
   - In `source/orglistremo/db/repo_locks.d`, change `releaseLock` to verify
     ownership (`DELETE FROM sync_locks WHERE root_id = ? AND pid = ? AND
     hostname = ?`), keeping `breakLock(rootId)` unconditional.

5. **Atomic Sync Staging, Set-Based Stale Deletion & Scanner Fixes
   (`BUG-05`, `BUG-09`, `PERF-03`)**
   - In `source/orglistremo/sync/scanner.d`:
     - In `isDiskDirEmpty`, do not ignore symlinks (`entry.isSymlink` counts as
       a directory entry) and do not silently mask root read exceptions.
     - In `flushBatch`, do not silently swallow exceptions: record a fatal
       `SyncIssue` / abort the scan cleanly.
   - In `source/orglistremo/db/repo.d` and `scanner.d`:
     - Ensure partial batches are not left committed on an aborted sync, and
       replace per-row `deleteStaleEntries` with a set-based SQL query (e.g.
       using a `TEMP` table of seen `rel_path` values within the sync
       transaction).

6. **Multi-Target `list` Sorting & Epoch Time Formatting (`BUG-06`, `BUG-15`)**
   - In `source/orglistremo/app.d` (`handleListCommand`), sort `allEntries`
     globally according to `listArgs.sortField` when multiple targets are
     queried (or run a single multi-target query).
   - In `source/orglistremo/output/units.d`, split `formatLastSync(long ts,
     bool hasLastSync)` (returns `"never"` when `!hasLastSync`) from
     `formatUnixTime(long ts)` (formats any valid Unix timestamp including `0`).

7. **Migration Pragmas & Import TOCTOU (`BUG-10`, `BUG-11`)**
   - In `source/orglistremo/db/repo_migration.d`, restore `query_only` on
     failure (`scope (failure)`) and apply write pragmas on success.
   - In `source/orglistremo/importer.d` (`executeImportRoots`), move existing
     root classification inside the `BEGIN IMMEDIATE` transaction.

8. **Phase 1 Verification & Version Bump**
   - Run `dub test --compiler=ldc2` and the line-length check skill.
   - Increment `appVersion` in `source/orglistremo/app_version.d` and document
     Phase 1 fixes in `CHANGELOG.md`.

---

### Phase 2: Shared Internal Utilities, Pattern Module & Test Infrastructure
**Goal:** Extract low-risk cross-cutting utilities and eliminate test collisions
and Posix portability issues.

1. **Test Utilities (`DUP-11`, `BUG-14`)**
   - Create `source/orglistremo/internal/testutil.d` (`version (unittest)`):
     - `struct TempDir` generating unique directory names using PID + atomic
       counter and cleaning up on destruction (handling read-only permissions).
     - `void createLegacyV0Db(string dbPath)`.
     - `string captureOutput(scope void delegate(File) writer)`.
   - Refactor existing unit tests in `app.d`, `importer.d`, `scanner.d`,
     `hasher.d`, `connection.d`, `repo_migration.d`, `console.d`, and `html.d`
     to use `TempDir`, `createLegacyV0Db`, and `captureOutput`.

2. **OS Abstraction Module (`DUP-07`, `BUG-13`, `STYLE-02`)**
   - Create `source/orglistremo/internal/os.d` with `package(orglistremo):`
     visibility and proper `version (Posix)` / `else` blocks:
     - `bool isPidAlive(int pid)` (from `db/repo_locks.d`)
     - `Nullable!long getDeviceFreeSpace(string path)` (from `sync/scanner.d`)
     - `bool isStdoutTty()` and `uint getTerminalWidth(int fd)` (from
       `output/console.d`)
     - `string getLocalHostName()` (replacing `std.socket` in `app.d`)
   - Remove direct `core.sys.posix.*` and `std.socket` imports from domain
     modules.

3. **Pattern & Escaping Module (`DUP-05`, `CONF-01`, `PERF-05`, `BUG-16`)**
   - Create `source/orglistremo/pattern.d` (`package(orglistremo):`):
     - Move `hasPatternWildcard`, `hasGlobWildcard`, `unescapePatternEscapes`
       from `model.d`.
     - Move and rename `escapeLikePattern` -> `userPatternToLike` and
       `escapeLike` -> `escapeLikeLiteral` from `db/repo.d`.
     - Add `bool isWildcard(string s, bool useGlob)` and `struct NamePattern`.
     - Optimize `userPatternToLike`, `escapeLikeLiteral`,
       `unescapePatternEscapes`, and `escapeCsvField` (`output/csv.d`) to return
       the input slice when no special characters are present and use
       `appender!string` otherwise.

4. **Model & Output Constants (`CONF-03`, `CONF-05`, `DUP-08.1`, `DUP-08.2`)**
   - In `source/orglistremo/model.d`:
     - Add `enum emptyHash = "0";` and replace magic `"0"` literals across
       `hasher.d`, `repo.d`, `console.d`, and `html.d`.
     - Move `groupDuplicates` from `EntryRepository` into `model.d`.
     - Add `EntryStats countEntries(in Entry[] entries)` and
       `DuplicateStats summarizeDuplicates(in DuplicateGroup[] groups)`.
     - Add an `Entry` factory helper (`makeEntry`) that derives `name` and
       `parentPath` from `relPath` using `std.string.lastIndexOf`, and replace
       `TargetSpec.findColon` with `std.string.indexOf` (`DUP-09.4`).
   - In `source/orglistremo/output/units.d`:
     - Move `formatHash(string h, bool fullHash)` from `console.d` and `html.d`
       into `units.d`.

5. **Phase 2 Verification & Version Bump**
   - Run `dub test --compiler=ldc2` and the line-length check skill.
   - Increment `appVersion` and update `CHANGELOG.md`.

---

### Phase 3: Database Layer Consolidation (`source/orglistremo/db/`)
**Goal:** Eliminate SQL duplication, cache metadata checks, and enforce
`codestyle.md` rules in `db/`.

1. **Transaction & Schema Helpers (`DUP-06.6`, `DUP-06.7`, `CONF-09`,
   `STYLE-01`)**
   - Create `source/orglistremo/db/transaction.d` with
     `void withTransaction(ref Database db, scope void delegate() body)` and use
     it across `repo.d`, `repo_locks.d`, `migration.d`, and `importer.d`.
   - Create `source/orglistremo/db/internal/schema.d` with `tableExists` and
     `columnExists`.
   - Rename `source/orglistremo/db/repo_migration.d` to
     `source/orglistremo/db/migration.d` and remove `public import` from
     `connection.d`.
   - Create `source/orglistremo/db/package.d` as the subsystem facade.

2. **`RootRepository` Cleanup (`PERF-02`, `DUP-06.3`, `DUP-06.4`, `DUP-06.5`)**
   - Cache `hasFreeSpaceColumn` in `RootRepository` using a 3-state enum so
     `PRAGMA table_info(roots)` runs at most once per instance.
   - Extract `private Root[] selectRoots(string whereClause, scope void
     delegate(ref Statement) bind)` to deduplicate `findByName`, `findById`,
     `findByPattern`, and `findByGlob`.
   - Extract `bindNullable` in `source/orglistremo/db/internal/sql.d` for
     `insertImportedRoot` / `updateImportedRoot`.
   - Reuse `RootRepository(db).updateLastSync(...)` inside
     `EntryRepository.saveSyncEntries`.

3. **`EntryRepository` & Query Consolidation (`DUP-06.1`, `DUP-06.2`,
   `CONF-02`, `CONF-06`, `BUG-16`)**
   - Remove dead legacy fields (`hasRoot`, `rootId`, `rootPattern`, `subpath`)
     from `HashQueryFilter`; express all target filters through
     `TargetSpec[] targets` and update `db/repo.d` unit tests.
   - Rename `listEntries(long, ...)` to `listEntriesByRootId` and
     `listEntries(string, ...)` to `listEntriesByPattern` (keeping a deprecated
     alias only if needed during transition), backed by a single private
     `queryEntries` helper that reuses `buildSubpathSql` and `bindSubpath`.
   - Extract `enum entrySelectSql` into `db/internal/sql.d`.
   - Refactor `findDuplicateEntries` and `findUniqueEntries` to use a SQL CTE
     (`WITH scoped_entries AS (...)`) or clearly document dual parameter binding
     in `bindDuplicateOrUniqueParams`.
   - Deduplicate lock row reading in `source/orglistremo/db/repo_locks.d`
     (`readLockRow`).

4. **Codestyle Pass on `db/` (`STYLE-02`, `STYLE-03`, `STYLE-04`, `STYLE-06`,
   `STYLE-07`)**
   - Apply `package(orglistremo):`, place methods before fields in
     `RootRepository`, `EntryRepository`, and `LockRepository`, replace
     non-obvious `auto` with `Statement`/`ResultRange`/`Row`, keep all functions
     <= 50 lines, and group >3 parameters into structs (`SyncSaveParams`,
     `LockRequest`, `VersionRow`).

5. **Phase 3 Verification & Version Bump**
   - Run `dub test --compiler=ldc2` and the line-length check skill.
   - Increment `appVersion` and update `CHANGELOG.md`.

---

### Phase 4: CLI Modularization & Importer Cleanup (`source/orglistremo/cli/`)
**Goal:** Break up the 1778-line `app.d` monolith, resolve the `app` <->
`importer` cyclic import, and unify CLI argument parsing.

1. **Extract Layering Types (`CONF-08`)**
   - Create `source/orglistremo/output/options.d` (`OutputFormat`, `ColorMode`,
     `OutputOptions`, `Styler`, and `info(...)` console print helper).
   - Create `source/orglistremo/sync/progress.d` (`SyncPhase`, `SyncProgress`,
     `SyncIssue` with `string describe() const`).

2. **Create Shared CLI Helpers (`DUP-01`, `DUP-02`, `DUP-03`, `DUP-04`)**
   - Create `source/orglistremo/cli/context.d`: `DbContext`,
     `requireWritable(in DbContext)`, and `backupIfRequested(...)` (moving
     `promptBackupPath` out of `db/backup.d`).
   - Create `source/orglistremo/cli/args.d`: `ArgCursor`, `isFlag`, and
     `parseChoice` for subcommand flag parsing.
   - Create `source/orglistremo/cli/roots.d`: `resolveRoots` and
     `reportNoRootMatch`.
   - Create `source/orglistremo/cli/usage.d`: single multi-line usage string
     constant (`printUsage` under 50 lines).

3. **Split Subcommands into `cli/*_cmd.d` (`STYLE-04`, `CONF-11`, `CONF-12`,
   `DUP-10`, `PERF-04`)**
   - `source/orglistremo/cli/root_cmd.d`: `root add`, `remove`, `set-path`,
     `list`.
   - `source/orglistremo/cli/sync_cmd.d`: `handleSyncCommand`,
     `runParallelSync`, `runSequentialSync` (returning unified `SyncRunResult`),
     and `syncSingleRoot` split into lock / scan / report helpers under 50
     lines.
   - `source/orglistremo/cli/query_cmd.d`: `list`, `duplicates`, `unique`.
   - `source/orglistremo/cli/migrate_cmd.d`: `migrate`.
   - `source/orglistremo/cli/import_cmd.d` (moved from `importer.d`):
     - Deduplicate `countNewEntries` (`DUP-10`).
     - Clarify update summary output (`CONF-12`) so replaced/updated roots
       report accurate counts.
     - Group 4-6 parameter helper signatures into `ImportContext` (`STYLE-06`).
     - Optimize entry copying (`PERF-04`) using batched inserts or
       `ATTACH DATABASE`.
   - Create `source/orglistremo/cli/package.d` and slim
     `source/orglistremo/app.d` down to `main()`, global option parsing, and
     command dispatch.

4. **Phase 4 Verification & Version Bump**
   - Run `dub test --compiler=ldc2` and the line-length check skill.
   - Increment `appVersion` and update `CHANGELOG.md`.

---

### Phase 5: Output & Sync Refinement, Embedded Assets & Final Codestyle Audit
**Goal:** Externalize embedded HTML/CSS/JS assets, clean up `output/` and
`sync/` internals, and verify 100% compliance with `codestyle.md`.

1. **Externalize HTML Assets (`DUP-08.5`, `STYLE-05`)**
   - Create `assets/orglistremo/report.css` and `assets/orglistremo/report.js`
     containing the CSS and JS currently emitted via `writeln` in
     `source/orglistremo/output/html.d:525-741`.
   - Add `stringImportPaths "assets"` to `dub.sdl`.
   - Create `source/orglistremo/internal/assets.d` exposing `reportCss` and
     `reportJs` via `import("orglistremo/report.css")` and
     `import("orglistremo/report.js")`.
   - Replace `writeHtmlStyles` / `writeHtmlScript` in `output/html.d` with
     writes of `reportCss` and `reportJs`.

2. **Output Subsystem Cleanup (`DUP-08.3-D8.10`, `CONF-07`, `STYLE-01..08`)**
   - In `source/orglistremo/output/html.d`:
     - Extract `writePageHeader(File outStream, string title, string badgeText,
       bool withToolbar)` to remove the 3 duplicated header/toolbar blocks.
     - Add `HtmlTreeNode.setMeta(in Entry e)` to remove the 3 duplicated
       metadata assignment blocks.
     - Reorder `HtmlTreeNode` methods before fields and mark non-mutated locals
       `const`.
   - In `source/orglistremo/output/console.d`:
     - Remove dead `finish()` and redundant `onProgress` wrapper; merge
       `ConsoleProgressReporter` constructors using default parameters.
     - Reorder methods before fields in `Styler` and `ConsoleProgressReporter`.
     - Remove unused imports and duplicate unit tests already covered in
       `units.d`.
   - In `source/orglistremo/output/formatter.d` and `output/package.d`:
     - Unify format dispatch and add `output/package.d`.

3. **Sync Subsystem Cleanup (`DUP-09`, `CONF-04`, `CONF-06`, `CONF-10`,
   `STYLE-01..08`)**
   - In `source/orglistremo/sync/hasher.d`:
     - Return a `DirectoryHashResult` struct from `hashDirectory` and document
       in-place sorting of the input slice.
   - In `source/orglistremo/sync/scanner.d`:
     - Remove the legacy test-only `syncRoot` overload and update tests in
       `scanner.d` to pass `SyncOptions`.
     - Extract `joinRelPath`, `makeProgress`, and `appendEntry` on
       `ScannerContext`.
     - Keep a single source of truth for `stats.totalSize` and `batchSize`,
       remove redundant `entryRepo is null` checks, mark immutable fields
       `const`, and place methods before fields in `ScannerContext`.
   - Create `source/orglistremo/sync/package.d`.

4. **Final Verification & Smoke Testing**
   - Build and run full test suite:
     ```bash
     dub build --compiler=ldc2
     dub test --compiler=ldc2
     ```
   - Verify 80-column limit across all source and documentation files:
     ```bash
     rdmd --compiler=ldc2 \
       .agents/skills/check-line-length/scripts/check_line_length.d \
       source/ reviews/ CHANGELOG.md
     ```
   - Run end-to-end CLI smoke tests: `root add`, `sync`, `sync --all -j 2`,
     `list --html`, `duplicates --csv`, `migrate` (on legacy v0 DB), and
     `import`.
   - Increment `appVersion` in `source/orglistremo/app_version.d` and finalize
     `CHANGELOG.md`.
