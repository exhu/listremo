# `listremo` Implementation Progress

Tracking document for `listremo` milestone execution as defined in
`spec/plan1.md`.

---

## Status Dashboard

| Milestone | Description | Status |
| :--- | :--- | :--- |
| **Milestone 1** | Scaffolding & Database Layer | Completed |
| **Milestone 2** | Hashing Engine & Root Synchronization | Completed |
| **Milestone 3** | Target Specifier Parsing & Query Engine | Completed |
| **Milestone 4** | Output Formatters, CLI Wiring & Verification | Completed |

---

## Milestone 1: Project Scaffolding & Database Layer

- **Goal**: Setup `dub.json`, define data models under `orglistremo`, implement
  SQLite connection with WAL and foreign key pragmas, create schema and root
  repository, and verify using unit tests against `:memory:` database.
- **Tasks**:
  - [x] Create `dub.json` with `d2sqlite3` dependency (~>1.0.0).
  - [x] Implement `source/orglistremo/config.d` (database path resolution).
  - [x] Implement `source/orglistremo/model.d` (domain structs & enums).
  - [x] Implement `source/orglistremo/db/connection.d` (pragmas & migrations).
  - [x] Implement `source/orglistremo/db/repo.d` (root repository & CRUD).
  - [x] Add unit tests and verify with `dub test --compiler=ldc2`.
  - [x] Verify line lengths with `check-line-length` skill.

---

## Milestone 2: Hashing Engine & Root Synchronization

- **Goal**: Implement streaming SHA-256 for files (with `"0"` for empty files),
  bottom-up Merkle directory hashing (with `"0"` for empty dirs), and
  incremental filesystem synchronization with transaction safety.
- **Tasks**:
  - [x] Implement `source/orglistremo/sync/hasher.d` (file & dir hashing).
  - [x] Implement entry CRUD and diffing in `source/orglistremo/db/repo.d`.
  - [x] Implement `source/orglistremo/sync/scanner.d` (FS traversal & sync).
  - [x] Unit tests for hasher (empty files, empty dirs, Merkle consistency).
  - [x] Integration tests syncing temporary directory fixtures.
  - [x] Verify line lengths with `check-line-length` skill.

---

## Milestone 3: Target Specifier Parsing & Query Engine

- **Goal**: Implement target specifier parsing (`<root_name>` and
  `<root_name>:/<subpath>`), subtree queries with LIKE escaping, single-root
  and cross-root duplicates, unique entry queries, and `--skip-empty` support.
- **Tasks**:
  - [x] Implement and test `TargetSpec` parsing edge cases.
  - [x] Verify `listEntries` subtree prefix filtering.
  - [x] Verify `listDuplicates` (intra-root, cross-root, `--skip-empty`).
  - [x] Verify `listUnique` (intra-root, cross-root, `--skip-empty`).
  - [x] Add comprehensive unit tests in `repo.d` covering all combinations.
  - [x] Verify line lengths with `check-line-length` skill.

---

## Milestone 4: Output Formatters, CLI Wiring & Verification

- **Goal**: Implement ANSI console output with alignment and TTY detection,
  RFC 4180 CSV serializer, CLI subcommand dispatcher in `app.d`, and
  end-to-end integration tests.
- **Tasks**:
  - [x] Implement `source/orglistremo/output/formatter.d`.
  - [x] Implement `source/orglistremo/output/console.d` (colors & alignment).
  - [x] Implement `source/orglistremo/output/csv.d` (RFC 4180 CSV).
  - [x] Implement CLI subcommand routing in `source/orglistremo/app.d`.
  - [x] End-to-end integration tests for all subcommands and flags.
  - [x] Verify line lengths with `check-line-length` skill.

---

## Verification Summary

- **Unit Test Suite**: 8 modules passed (`dub test --compiler=ldc2`).
- **CLI Commands Verified**:
  - `root add`, `root list`, `root set-path`, `root remove`
  - `sync <name>`, `sync --all`, incremental caching and `--force-hash`
  - `list <target>`, `files <target>`, subtree filtering, `--type`, `--sort`
  - `duplicates [<target>]`, `--skip-empty`, cross-root and single-root
  - `unique [<target>]`, `--skip-empty`, cross-root and single-root
  - Output formats: ANSI colored console and strict RFC 4180 CSV (`--csv`)
- **Code Style & Line Length**:
  All files in `source/` and `spec/` adhere to `codestyle.md` and the 80-column
  line limit verified via the `check-line-length` skill.
