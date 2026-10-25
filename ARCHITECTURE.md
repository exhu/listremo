# Architecture Map

## 1. System Overview & Tech Stack
- `listremo` is a CLI tool to catalog, hash, and query files split across
  multiple offline storage roots (external drives, network mounts).
- It follows a layered CLI pipeline architecture: command routing and output
  formatting wrap dedicated sync/hashing and SQLite persistence layers.
- Core technologies: D (compiled with LDC2), DUB package manager, `d2sqlite3`
  for SQLite persistence, and cryptographic hashing via SHA-256 and Merkle
  trees.

## 2. Source Tree & Module Responsibilities
- `source/orglistremo/`:
  - `app.d`: Main entry point, CLI routing, and DB connection lifecycle.
  - `model.d`: Core domain types (`Root`, `Entry`, `EntryType`, summaries).
  - `config.d`: Resolution of database path and default directory creation.
  - `pattern.d`: Wildcard matching (SQL `LIKE`, glob syntax).
- `source/orglistremo/cli/`: CLI subcommand parsing, options, and dispatch.
  - `context.d`: Database execution context (`DbContext`, `requireWritable`).
  - `root_cmd.d`: Storage root management (`add`, `remove`, `set-path`, `list`).
  - `ignore_cmd.d`: Per-root ignore glob list management (`ignore`,
    `ignore-delete`).
  - `sync_cmd.d`: Synchronization orchestration and concurrent worker pools.
  - `query_cmd.d`: Catalog browsing and queries (`list`, `duplicates`,
    `unique`).
  - `import_cmd.d`: Inter-catalog database root import and merging.
  - `migrate_cmd.d`: Schema migration command execution.
- `source/orglistremo/sync/`: Filesystem traversal and cryptographic hashing.
  - `scanner.d`: Directory recursion, mtime/size checks, dry-run, and staged
    syncing.
  - `hasher.d`: Streaming SHA-256 file hashing and Merkle directory hashing.
  - `progress.d`: Progress reporting types and error event accumulation.
- `source/orglistremo/db/`: SQLite persistence, schema management, and locks.
  - `connection.d`: Connection initialization, WAL pragmas, and version checks.
  - `migration.d`: Schema migration steps and version table management.
  - `repo.d`: Repositories for roots (`RootRepository`) and entries
    (`EntryRepository`).
  - `repo_locks.d`: Cooperative host/PID concurrency lock table management.
  - `backup.d`: Atomic SQLite snapshot creation via `VACUUM INTO`.
- `source/orglistremo/output/`: Presentation and output formatting.
  - `options.d`: Output options (`OutputOptions`, `OutputFormat`, `ColorMode`).
  - `console.d`: ANSI colorized table formatting and progress rendering.
  - `csv.d`: RFC 4180 compliant CSV stream generation.
  - `html.d`: Standalone interactive HTML report generation.
- `source/orglistremo/internal/`: Internal utilities and platform support.
  - `assets.d`: Inlined CSS/JS report assets compiled via `-Jassets`.
  - `os.d`: Platform OS abstractions (free disk space, hostname, PID alive).
  - `testutil.d`: Unittest helpers and collision-free temporary directories.
- `assets/orglistremo/`: External CSS and JS assets embedded at compile time.

## 3. Core Data & Execution Flow
- Catalog Queries (`list`, `duplicates`, `unique`):
  `CLI args` -> `app.runApp` -> `openDatabaseChecked` -> `cli/query_cmd.d` ->
  `repo.d (SQL query)` -> `output (console/csv/html)` -> `stdout`.
- Sync Execution (`sync`):
  `CLI args` -> `cli/sync_cmd.d` -> `writeDatabaseBackup (VACUUM INTO)` ->
  `SyncLockRepository.acquireLock` -> `sync/scanner.d` ->
  `sync/hasher.d (SHA-256 / Merkle)` -> `EntryRepository.stageBatch` ->
  `EntryRepository.commitSync` (atomic live swap & stale deletion) ->
  `SyncLockRepository.releaseLock`.
- Database Migration (`migrate`):
  `CLI args` -> `cli/migrate_cmd.d` -> `writeDatabaseBackup (VACUUM INTO)` ->
  `db/migration.d (runMigrationSteps in transaction)` -> `applyWritePragmas`.
- Cross-Database Import (`import`):
  `CLI args` -> `cli/import_cmd.d` -> `validateSchema` ->
  `writeDatabaseBackup` -> `upsertEntriesBatch (transaction)` -> `summary`.

## 4. Architectural Boundaries & Invariants
- State & Persistence: All persistent state resides in SQLite. Read-only
  databases (`query_only = ON`) are enforced if schema version mismatches.
- Database Concurrency: `openWorkerDatabase` must be used for background worker
  threads; all connections enforce `PRAGMA foreign_keys = ON` and
  `busy_timeout`.
- Sync Atomicity: Scanned files are buffered in temporary staging tables. Live
  catalog records are never updated in-place incrementally; updates and stale
  row deletions occur atomically inside a single transaction upon scan success.
- Hashing Invariants: Empty files and empty directories hash to `"0"`.
  Directory hashes are deterministic Merkle roots formed from child names and
  hashes.
- Target Syntax: Root names must not contain `:` (separator for `root:/path`).
  Paths stored in the database are normalized relative paths with forward
  slashes and no leading slash.
- Dependency Layering: CLI modules depend on `sync`, `db`, and `output`. `db`
  and `sync` do not depend on `cli`. Output formats depend only on `model` and
  `output/options.d`.
- Error Handling: CLI commands trap expected exceptions, report errors to
  `stderr`, and return non-zero exit codes. Rollback handlers (`scope(failure)`)
  clean up locks and staging tables.

## 5. Development & Verification Commands
- Build release binary:
  `dub build -b release --compiler=ldc2`
- Build debug binary:
  `dub build --compiler=ldc2`
- Run unit test suite:
  `dub test --compiler=ldc2`
- Verify 80-column line limit:
  `rdmd --compiler=ldc2 \`
  `  .agents/skills/check-line-length/scripts/check_line_length.d \`
  `  ARCHITECTURE.md`
- Run empirical challenge tests:
  `rdmd -I=source \`
  `  -I=$HOME/.dub/packages/d2sqlite3/1.0.0/d2sqlite3/source \`
  `  -J=assets -L=-lsqlite3 --compiler=ldc2 tests/empirical_m1_challenge.d`
