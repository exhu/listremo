# Code Review & Improvement Plan: `source/orglistremo`

Scope: all 18 modules (~7.5k lines incl. tests) under `source/orglistremo`.
Focus: (1) duplicated code that can move into shared modules, (2) common
mistakes / latent bugs, (3) confusing code. Findings are ordered by priority
inside each section; a phased plan is at the end.

Line numbers refer to the state of the tree at review time.

---

## 1. Summary

| Area                  | Findings | Highest impact                            |
|-----------------------|---------:|-------------------------------------------|
| Bugs / risky code     |       16 | Backup copies a live WAL DB file          |
| Duplication           |       11 | `repo.d` SQL builders, CLI arg parsing    |
| Confusing code        |       15 | LIKE escaping names, legacy filter fields |

Hotspots by size: `app.d` (1778 lines, ~640 of them tests), `db/repo.d`
(1348), `output/html.d` (852, ~190 lines of CSS emitted via `writeln`).

---

## 2. Bugs and risky code (fix first)

### B1. Backup copies the raw SQLite file (high)
[backup.d#L64-L86](source/orglistremo/db/backup.d#L64-L86) uses
`std.file.copy` on an **open** database that runs in WAL mode
([connection.d#L75-L80](source/orglistremo/db/connection.d#L75-L80)).
Committed pages may still live in `*.db-wal`, and a concurrent `sync` from
another process can be writing. The backup can be stale or corrupt.

Fix: use `VACUUM INTO '<path>'` (SQLite >= 3.27) through the open connection,
or the SQLite online backup API. Both produce a consistent snapshot.

### B2. `escapeHtml` throws on non-UTF-8 file names (high)
[html.d#L247-L272](source/orglistremo/output/html.d#L247-L272) iterates with
`foreach (dchar c; s)`. Linux file names are arbitrary bytes; invalid UTF-8
raises `UTFException` and aborts the whole HTML report. All escaped chars are
ASCII, so iterate over `char` (or `ubyte`) instead. Audit other `dchar`
decoding paths (`std.format` width padding) for the same issue.

### B3. User input validated with `assert` (high)
`RootRepository.addRoot` / `setPath`
([repo.d#L40-L41](source/orglistremo/db/repo.d#L40-L41),
[repo.d#L111](source/orglistremo/db/repo.d#L111)) assert on empty values
that come straight from the CLI (`listremo root add "" /x`). Debug builds
crash with `AssertError`, release builds silently insert an empty root.

Related gaps in [app.d#L401-L458](source/orglistremo/app.d#L401-L458):
- Root path is stored verbatim; a relative path breaks `sync` as soon as the
  working directory changes. Normalize with `absolutePath` /
  `buildNormalizedPath`.
- Root names containing `:` can never be addressed by `TargetSpec.parse`;
  names with `%`/`*`/`?`/`[` need escaping. Validate names on `add`.

Fix: validate in the CLI layer and throw/return errors; keep `assert` only for
programmer invariants.

### B4. Parallel sync error handling (medium)
[app.d#L637-L656](source/orglistremo/app.d#L637-L656):
- `openDatabaseChecked` inside `pool.parallel` can throw; the exception
  escapes `handleSyncCommand` and reaches `main` as an uncaught stack trace.
- The per-thread DB result's `isReadOnly` is ignored.
- `"Syncing root ..."` / `"Done: ..."` lines from workers interleave on stdout
  without a lock.

Fix: wrap the body in `try/catch`, check `isReadOnly`, serialize console
output via the existing mutex (or buffer per root and print on completion).

### B5. `sync --all` runs an aggregate over the whole `entries` table (medium)
[app.d#L560-L563](source/orglistremo/app.d#L560-L563) calls
`rootRepo.listRoots()` (SUM/COUNT over all entries) only to collect `Root`s.
Use `findByPattern("%")`.

### B6. `flushBatch` swallows exceptions silently (medium)
[scanner.d#L190-L200](source/orglistremo/sync/scanner.d#L190-L200) catches
`Exception` without recording anything. A persistent DB error (disk full,
lock timeout) is invisible until the final save. At minimum record a
`SyncIssue` or log once. Also document that batches are committed before
stale-entry deletion, so an aborted sync leaves a mixed state (new rows +
stale rows, `last_sync` unchanged).

### B7. CLI option inconsistencies (low)
- `--progress-interval` error text says "positive integer", but `0` is
  accepted ([app.d#L489-L504](source/orglistremo/app.d#L489-L504)).
- `-j/--jobs` is silently ignored without `--all`
  ([app.d#L601](source/orglistremo/app.d#L601)).
- Error wording differs for the same condition: "Root '%s' not registered."
  (sync) vs "Root '%s' not found." (list/dup/unique/import).

### B8. Migration leaves connection in an odd state (low)
[repo_migration.d#L20-L24](source/orglistremo/db/repo_migration.d#L20-L24)
turns `query_only` OFF before `BEGIN`; on failure it is not restored. After a
successful migrate the session never gets `applyWritePragmas` (WAL,
`synchronous`), because that function is private to `connection.d`.

### B9. Import TOCTOU (low)
[importer.d#L117-L126](source/orglistremo/importer.d#L117-L126) looks up
existing roots **before** `BEGIN IMMEDIATE`. A concurrent `root add` can make
`insertImportedRoot` fail on `UNIQUE`. Move the classification inside the
transaction.

### B10. `PRAGMA table_info` on every root query (low)
`hasFreeSpaceColumn`
([repo.d#L270-L278](source/orglistremo/db/repo.d#L270-L278))
runs for each `findBy*` / `listRoots` call. Cache it once per
`RootRepository` (or derive it from the schema version in `DbContext`).

### B11. Non-Posix build is half-supported (low)
`console.d` imports `core.sys.posix.*` unconditionally
([console.d#L65](source/orglistremo/output/console.d#L65),
[#L202](source/orglistremo/output/console.d#L202),
[#L395](source/orglistremo/output/console.d#L395)), while `repo_locks.d` and
`scanner.d` carefully use `version (Posix)`. Pick one: declare Posix-only, or
guard consistently (see D7).

### B12. Unit tests use fixed temp directory names (low)
`buildPath(tempDir(), "listremo_..._test")` in 10 places
(app, importer, scanner, hasher, connection). Two concurrent `dub test` runs
delete each other's fixtures. Use unique names (PID + counter) via a helper
(see D11).

### B13. `formatUnixTime(<=0)` prints "never" for file mtimes (low)
[units.d#L20-L25](source/orglistremo/output/units.d#L20-L25) is shared by
"last sync" and entry `mtime`. A file with mtime 0 or pre-1970 shows "never".
Split into `formatLastSync` (nullable semantics) and `formatUnixTime`.

### B14. LIKE `_` semantics differ between options (low)
`escapeLikePattern` escapes `_` (literal) for root/sub-path patterns, but
`--hash` is bound raw
([repo.d#L502-L504](source/orglistremo/db/repo.d#L502-L504)),
so `_` is a wildcard there (the tests rely on it). Document or unify.

### B15. Fragile double binding in hash queries (low)
`bindDuplicateOrUniqueParams`
([repo.d#L902-L909](source/orglistremo/db/repo.d#L902-L909)) binds the same
filter twice, relying on outer/inner SQL having identical placeholder order.
Add a comment, or use a CTE (`WITH scope AS (...)`) so filters appear once.

### B16. Console column alignment counts bytes (cosmetic)
`format("%-18s", name)` pads by code units; non-ASCII names misalign the
table ([console.d#L242-L270](source/orglistremo/output/console.d#L242-L270)).

---

## 3. Duplicated code: candidates for shared modules

### D1. CLI context: new `cli/context.d`
`DbContext` and `printReadOnlyError` live in `app.d` and are imported by
`importer.d`, which `app.d` imports back: a **cyclic import**. The read-only
check is copy-pasted 5 times
([app.d#L369-L384](source/orglistremo/app.d#L369-L384),
[app.d#L538-L541](source/orglistremo/app.d#L538-L541),
[importer.d#L193-L196](source/orglistremo/importer.d#L193-L196)).

Move to `cli/context.d`:
```d
struct DbContext { ... }
bool requireWritable(in DbContext ctx); // prints error, returns false
```

### D2. CLI argument helpers: new `cli/args.d`
Five hand-written loops repeat the same skeleton: "missing value for X",
"unknown flag", `to!uint` with try/catch, enum-from-string:
`parseSyncArgs`, `parseListArgs`, `parseDuplicateOrUniqueArgs`,
`parseMigrateArgs` (app.d) and `parseImportArgs` (importer.d); plus
`parseTypeFilter`, `parseSortField`, and the format/color checks in
`buildOutputOptions`.

Proposal:
```d
struct ArgCursor {            // wraps args + index
  bool next(out string arg);
  bool takeValue(string flag, out string value);   // prints "Missing value"
  bool takeUint(string flag, out uint value);      // prints "Invalid value"
}
bool isFlag(string arg);
bool parseChoice(E)(string flag, string val, out E result,
                    in string[E] names);           // "Valid values: ..."
```
Alternative: use `std.getopt` per subcommand (already used for globals) and
keep custom code only for the "target before `--hash`" rule.

### D3. Root pattern resolution and error reporting
"No roots match pattern / Root not found" logic appears 4 times
([app.d#L551-L577](source/orglistremo/app.d#L551-L577),
[app.d#L966-L986](source/orglistremo/app.d#L966-L986),
[importer.d#L71-L95](source/orglistremo/importer.d#L71-L95)).
De-duplicating by id is repeated in `handleListCommand` (entries) and
`resolveImportSourceRoots` (roots).

Add to `cli/roots.d` (or `cli/context.d`):
```d
bool resolveRoots(ref RootRepository repo, in string[] patterns,
                  bool useGlob, out Root[] roots, string dbLabel = null);
void reportNoRootMatch(string pattern, bool useGlob, string dbLabel = null);
```

### D4. Backup-before-write
Identical block in migrate and import
([app.d#L846-L854](source/orglistremo/app.d#L846-L854),
[importer.d#L230-L238](source/orglistremo/importer.d#L230-L238)) ->
`bool backupIfRequested(in DbContext, bool noBackup, string action, opts)`.
The interactive `promptBackupPath` belongs to the CLI layer, not `db/`.

### D5. Pattern utilities: new `orglistremo/pattern.d`
Pattern helpers are split between `model.d` (`hasPatternWildcard`,
`hasGlobWildcard`, `unescapePatternEscapes`) and `repo.d`
(`escapeLikePattern`, `escapeLike`). The ternary
`useGlob ? hasGlobWildcard(x) : hasPatternWildcard(x)` is repeated 5 times
([app.d#L977](source/orglistremo/app.d#L977),
[repo.d#L443](source/orglistremo/db/repo.d#L443),
[repo.d#L534](source/orglistremo/db/repo.d#L534),
[repo.d#L808](source/orglistremo/db/repo.d#L808),
[repo.d#L881](source/orglistremo/db/repo.d#L881)).

Move all of them to `pattern.d` and add
`bool isWildcard(string s, bool useGlob)`. Optionally a small
`struct NamePattern { string text; bool glob; }` with `sqlOp()` and
`bindValue()` removes most `if (useGlob)` branches in `repo.d`.

### D6. SQL helpers inside `db/` (largest win)
1. **Two near-identical `listEntries` overloads**
   ([repo.d#L423-L602](source/orglistremo/db/repo.d#L423-L602), ~180 lines)
   re-implement sub-path SQL/binding that already exists as
   `buildSubpathSql` / `bindSubpath`
   ([repo.d#L803-L900](source/orglistremo/db/repo.d#L803-L900)).
   Replace both with one private `queryEntries(rootClause, bindRoot, filter)`
   plus `typeFilterSql(prefix)` and `orderBySql(sort, multiRoot)`.
2. Entry column list `e.id, e.root_id, r.name, ...` is written 3 times
   ([repo.d#L428](source/orglistremo/db/repo.d#L428),
   [#L514](source/orglistremo/db/repo.d#L514),
   [#L715](source/orglistremo/db/repo.d#L715)) -> `enum entrySelectSql`.
3. Root `SELECT ... %s FROM roots` with the `freeCol` dance is repeated in
   `findByName`, `findById`, `findByPattern`, `findByGlob`
   ([repo.d#L119-L223](source/orglistremo/db/repo.d#L119-L223)) ->
   `Root[] selectRoots(string where, scope void delegate(ref Statement))`.
4. Nullable binds (`hasLastSync`, `hasFreeSpace`) duplicated in
   `insertImportedRoot` / `updateImportedRoot`
   ([repo.d#L66-L98](source/orglistremo/db/repo.d#L66-L98)) ->
   `bindNullable(stmt, idx, bool has, T value)`.
5. `UPDATE roots SET last_sync ...` in both `RootRepository.updateLastSync`
   and `EntryRepository.saveSyncEntries`
   ([repo.d#L159-L181](source/orglistremo/db/repo.d#L159-L181),
   [repo.d#L403-L418](source/orglistremo/db/repo.d#L403-L418)).
6. Transaction boilerplate `BEGIN IMMEDIATE / scope(failure) ROLLBACK /
   COMMIT` appears 6 times (repo.d x2, repo_locks.d x2, repo_migration.d,
   importer.d) -> `db/transaction.d`:
   ```d
   void withTransaction(ref Database db, scope void delegate() body);
   ```
   Also makes accidental nesting (e.g. calling `upsertEntriesBatch` inside
   `executeImportRoots`) detectable in one place.
7. "Does table X exist" query repeated 3 times
   ([connection.d#L52-L59](source/orglistremo/db/connection.d#L52-L59),
   [migration#L138](source/orglistremo/db/repo_migration.d#L138-L142),
   [migration#L155](source/orglistremo/db/repo_migration.d#L155-L159)),
   plus a column check in `hasFreeSpaceColumn` ->
   `db/internal/schema.d`: `tableExists`, `columnExists`.
8. Lock row read duplicated in `acquireLock` and `getLock`
   ([repo_locks.d#L50-L67](source/orglistremo/db/repo_locks.d#L50-L67),
   [repo_locks.d#L102-L121](source/orglistremo/db/repo_locks.d#L102-L121)).
9. `PRAGMA busy_timeout` formatting in `connection.d` and `importer.d`
   (`openSourceDatabase`) -> expose `applyBusyTimeout(db, ms)` or add a
   read-only open function to `connection.d`.

### D7. OS helpers: new `internal/os.d`
Platform code is scattered: `isPidAlive` (repo_locks.d), `getDeviceFreeSpace`
(scanner.d), `isatty` + `getTerminalWidth` (console.d), and `std.socket`
imported just for `Socket.hostName` (app.d). Gather them in one module with a
single `version (Posix)` split (also fixes B11).

### D8. Output layer
1. `formatHash` is **identical** in
   [console.d#L377-L382](source/orglistremo/output/console.d#L377-L382) and
   [html.d#L404-L409](source/orglistremo/output/html.d#L404-L409), with
   identical tests -> move to `units.d`.
2. File/dir/size counting duplicated
   ([html.d#L79-L89](source/orglistremo/output/html.d#L79-L89),
   [html.d#L205-L215](source/orglistremo/output/html.d#L205-L215));
   "wasted copies" stats duplicated
   ([console.d#L325-L333](source/orglistremo/output/console.d#L325-L333),
   [html.d#L128-L136](source/orglistremo/output/html.d#L128-L136)) ->
   `EntryStats countEntries(in Entry[])`,
   `DuplicateStats summarize(in DuplicateGroup[])` in `model.d` or
   `output/stats.d`.
3. HTML page header with Expand/Collapse toolbar copied 3 times
   ([html.d#L91-L107](source/orglistremo/output/html.d#L91-L107),
   [#L138-L154](source/orglistremo/output/html.d#L138-L154),
   [#L217-L233](source/orglistremo/output/html.d#L217-L233)) ->
   `writePageHeader(out, title, badge, bool toolbar)`.
4. HTML node metadata assignment copied 3 times
   ([html.d#L337-L379](source/orglistremo/output/html.d#L337-L379)) ->
   `HtmlTreeNode.setMeta(in Entry)`. `renderTreeRoot` and
   `renderDirectoryNode` differ only in label and indentation.
5. ~190 lines of CSS + JS emitted line by line
   ([html.d#L525-L741](source/orglistremo/output/html.d#L525-L741)). Per
   `codestyle.md` move to `assets/orglistremo/report.css` / `report.js` and
   `import()` them in `internal/assets.d`.
6. `formatter.d` has four copies of the same 3-way `if/else` dispatch. Use an
   `OutputWriter` interface (console/csv/html implementations) or a template;
   it also unifies the CSV signatures that currently omit `options`.
7. "`if (opts.format == OutputFormat.console) writefln(...)`" occurs ~12
   times (app.d, backup.d, importer.d) -> `opts.isConsole` and
   `void info(Args...)(in OutputOptions, string fmt, Args)`.
8. `formatEntryPath` (console) re-implements `Entry.fullPath` with styling.
9. Type labels `"D"/"F"`, `"DIR"/"FILE"` repeated in csv/console/html.
10. Unused imports: `formatDuration`, `formatIso8601` in `html.d`;
    `formatDuration` in `console.d`. Console tests re-test `units.d`
    functions
    ([console.d#L409-L414](source/orglistremo/output/console.d#L409-L414)).

### D9. Sync scanner / entry construction
1. Child rel-path join computed twice
   ([scanner.d#L230-L232](source/orglistremo/sync/scanner.d#L230-L232),
   [#L263-L265](source/orglistremo/sync/scanner.d#L263-L265)) ->
   `joinRelPath(parent, name)`.
2. `SyncProgress` built field by field 4 times
   ([scanner.d#L134-L139](source/orglistremo/sync/scanner.d#L134-L139),
   [#L212-L218](source/orglistremo/sync/scanner.d#L212-L218),
   [#L310-L318](source/orglistremo/sync/scanner.d#L310-L318),
   [#L329-L336](source/orglistremo/sync/scanner.d#L329-L336)) ->
   `SyncProgress makeProgress(SyncPhase, string path)` on `ScannerContext`.
3. Batch-flush condition copied
   ([#L300-L303](source/orglistremo/sync/scanner.d#L300-L303),
   [#L383-L386](source/orglistremo/sync/scanner.d#L383-L386)) ->
   `appendEntry(Entry)`.
4. `Entry` is filled manually in the scanner and constructed with 10
   positional arguments ~60 times in tests
   (`Entry(0, id, "r", "a.txt", ".", "a.txt", false, 10, 1000, "h")`).
   Add a factory in `model.d` that derives `name` and `parentPath` from
   `relPath`; that also replaces `findLastSlash`
   ([scanner.d#L391-L398](source/orglistremo/sync/scanner.d#L391-L398)) and
   `TargetSpec.findColon`
   ([model.d#L112-L119](source/orglistremo/model.d#L112-L119)),
   both of which re-implement `std.string.lastIndexOf` / `indexOf`.
5. Issue text `"Failed to %s '%s': %s"` with the isDir ternary appears twice
   in `syncSingleRoot` ([app.d#L759-L787](source/orglistremo/app.d#L759-L787))
   -> `string SyncIssue.describe() const`.

### D10. Importer counting
Added file/dir counting duplicated in `importNewRoot` and
`processExistingRoot`
([importer.d#L345-L354](source/orglistremo/importer.d#L345-L354),
[#L383-L392](source/orglistremo/importer.d#L383-L392)) ->
`countNewEntries(entries, existingPaths, ref summary)`.

### D11. Test support: new `internal/testutil.d` (`version (unittest)`)
- Temp dir create/cleanup with `scope (exit)` copied ~10 times, sometimes
  with `chmod -R 755` -> `struct TempDir { this(string tag); string path; }`
  with unique names (fixes B12).
- Legacy v0 schema creation copied 4 times (app.d, importer.d,
  connection.d, repo_migration.d) -> `createLegacyV0Db(path)`.
- "Read a `File.tmpfile` back into a string" copied 3 times (importer, html,
  console) -> `string captureOutput(scope void delegate(File))`.

---

## 4. Confusing code

- **C1** [repo.d#L934-L972](source/orglistremo/db/repo.d#L934-L972):
  `escapeLikePattern` vs `escapeLike` -- the names don't say which one keeps
  `%` as a wildcard. Rename to `userPatternToLike` / `escapeLikeLiteral` and
  add doc comments.
- **C2** [repo.d#L23-L32](source/orglistremo/db/repo.d#L23-L32):
  `HashQueryFilter` keeps legacy `hasRoot/rootId/rootPattern/subpath` next to
  `targets`; the CLI only uses `targets`, and `resolveHashQueryFilter`
  resets an `out` parameter field by field. Drop the legacy fields (used by
  tests only) or document precedence.
- **C3** [repo.d#L612-L639](source/orglistremo/db/repo.d#L612-L639):
  `groupDuplicates` is a pure function inside a repository, with its group
  init block duplicated. Make it a free function in `model.d`.
- **C4** [hasher.d#L42-L69](source/orglistremo/sync/hasher.d#L42-L69):
  `hashDirectory` sorts the caller's array in place and returns results via
  `out` params. Return a struct; document the mutation.
- **C5** Magic hash `"0"` for empty files/dirs in hasher, repo SQL
  (`sha256 != '0'`) and both `formatHash` copies. Add
  `enum emptyHash = "0";` to `model.d`.
- **C6** Overloads instead of default args (codestyle prefers defaults):
  test-only `syncRoot(db, root, bool, cb)`; two `ConsoleProgressReporter`
  constructors; `listEntries(long)` vs `listEntries(string)` mean different
  things. Use defaults; rename to `listEntriesByRootId` /
  `listEntriesByPattern`.
- **C7** Dead or alias API: `breakLock == releaseLock`, `getLock`
  (tests only), `ConsoleProgressReporter.finish()`, `onProgress` vs
  `update`; `row.length > 5` is always true in `readRootRow`.
- **C8** Layering: `db/backup.d` prompts the user and depends on
  `output.console`; `output.console` depends on `sync.scanner`; UI enums
  (`OutputFormat`, `ColorMode`) live in `model.d`. Introduce
  `output/options.d` and `sync/progress.d`; move prompting to the CLI.
- **C9** [connection.d#L6](source/orglistremo/db/connection.d#L6):
  `public import` violates codestyle; `repo_migration.d` is not a
  repository. Rename to `migration.d` and import it directly.
- **C10** Functions over 50 lines in `app.d`: `printUsage` (~90),
  `syncSingleRoot` (~110), `handleSyncCommand` (~80), `parseSyncArgs`
  (~65). Usage becomes one string constant; split sync into
  lock / run / report steps.
- **C11** [scanner.d#L185](source/orglistremo/sync/scanner.d#L185):
  `batchSize` default duplicated from `SyncOptions`; `entryRepo is null`
  checks although it is always set. Single default; non-null invariant.
- **C12** [scanner.d#L378](source/orglistremo/sync/scanner.d#L378):
  `stats.totalSize` is accumulated per file, then overwritten with the root
  directory size. Keep one source of truth.
- **C13** [app.d#L615-L686](source/orglistremo/app.d#L615-L686):
  `runParallelSync(in Root[])` vs `runSequentialSync(ref Root[])`; the
  result is split between a return value and an `out bool`. Same signature,
  return a `struct SyncRunResult`.
- **C14** `console.d`: `options.styler.header(format("%-18s", ...))`
  repeated per column. Add a small column/table helper.
- **C15** [importer.d#L5](source/orglistremo/importer.d#L5): `importer` is a
  CLI command module at package root that imports `app`. Move it to
  `cli/import_cmd.d`.

---

## 5. Target module layout

```
source/orglistremo/
  app.d                 main, global options, dispatch only
  app_version.d
  config.d
  model.d               Root, Entry (+factory), DuplicateGroup, stats,
                        emptyHash, groupDuplicates
  pattern.d             wildcard detection, LIKE escaping (D5)
  cli/
    package.d
    context.d           DbContext, requireWritable, backupIfRequested
    args.d              ArgCursor, parseChoice (D2)
    roots.d             resolveRoots, reportNoRootMatch (D3)
    root_cmd.d          root add/remove/set-path/list
    sync_cmd.d          sync (sequential/parallel, locks)
    query_cmd.d         list, duplicates, unique
    migrate_cmd.d
    import_cmd.d        former importer.d
    usage.d             usage text
  db/
    connection.d
    transaction.d       withTransaction (D6.6)
    migration.d         former repo_migration.d
    repo.d              RootRepository, EntryRepository
    repo_locks.d
    backup.d            VACUUM INTO, no prompting
    schema_version.d
    internal/sql.d      column lists, bindNullable, subpath/type SQL
    internal/schema.d   tableExists, columnExists
  sync/
    progress.d          SyncPhase, SyncProgress, SyncIssue
    scanner.d
    hasher.d
  output/
    options.d           OutputOptions, OutputFormat, ColorMode, Styler
    formatter.d         OutputWriter dispatch
    console.d  csv.d  html.d  units.d
  internal/
    os.d                pid, hostname, statvfs, tty (D7)
    assets.d            report.css / report.js imports
    testutil.d          version(unittest) helpers (D11)
```

---

## 6. Phased plan

Each phase should build and pass `dub test --compiler=ldc2` on its own. Per
`AGENTS.md`: bump `appVersion` and add a `CHANGELOG.md` entry for each phase
that changes behavior. No SQL table changes are proposed, so `schemaVersion`
stays the same.

### Phase 1: correctness fixes (behavior changes)
- [ ] B1 backup via `VACUUM INTO`
- [ ] B2 byte-wise `escapeHtml`
- [ ] B3 validate root name/path in CLI, absolute paths, remove input asserts
- [ ] B4 parallel sync: catch, check read-only, serialize output
- [ ] B5 `findByPattern("%")` for `sync --all`
- [ ] B6 record flush failures
- [ ] B7 message/validation consistency
- [ ] B13 split `formatUnixTime` / last-sync formatting

### Phase 2: low-risk extractions (no behavior change)
- [ ] D11 `internal/testutil.d` (unique temp dirs, legacy DB, captureOutput)
- [ ] D5 `pattern.d` + `isWildcard`; C1 renames
- [ ] D7 `internal/os.d` (+ B11)
- [ ] D6.6 `db/transaction.d`, D6.7 `db/internal/schema.d`
- [ ] D8.1, D8.2, D8.10 `formatHash`, stats helpers, unused imports
- [ ] C5 `emptyHash` constant

### Phase 3: `repo.d` consolidation
- [ ] D6.1 to D6.5, D6.8, D6.9; B10 cache column check; B15 comment or CTE
- [ ] C2 trim `HashQueryFilter`; C3 move `groupDuplicates`
- [ ] C6 rename `listEntries` overloads

### Phase 4: CLI split
- [ ] D1 `cli/context.d` (removes app/importer cycle)
- [ ] D2 `cli/args.d`, port all `parse*Args`
- [ ] D3, D4 root resolution and backup helpers
- [ ] Split `app.d` into `cli/*_cmd.d`; C10, C13, C15
- [ ] B9 import classification inside the transaction

### Phase 5: output and sync cleanup
- [ ] D8.3 to D8.9 HTML header, assets, `OutputWriter`, `info` helper
- [ ] D9 scanner helpers and `Entry` factory; port tests to the factory
- [ ] D10 importer counting
- [ ] C4, C7, C8, C9, C11, C12, C14

### Verification per phase
- `dub build --compiler=ldc2` and `dub test --compiler=ldc2`
- `rdmd --compiler=ldc2`
  `.agents/skills/check-line-length/scripts/check_line_length.d`
- Manual smoke test: `root add`, `sync`, `list --html`, `duplicates --csv`,
  `migrate` on a v0 database, `import` with `--no-update`.
