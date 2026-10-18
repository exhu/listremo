# Code Review & Refactoring Instructions (`listremo`)

Refactor `source/orglistremo/` to fix CLI, query, and formatting bugs, remove
duplication, and comply with `codestyle.md`.

## 1. `source/orglistremo/app.d` — CLI Behavior & Bug Fixes

1. **Avoid opening/creating the database on `help`:**
   - Check `args[1] == "help"` before calling `resolveDbPath` and
     `openDatabase` in `main` so `listremo help` never touches the filesystem
     or fails on an invalid `--db` path.
2. **Validate global option values:**
   - Reject unknown `--format` values (only `"console"` and `"csv"` are valid)
     with an error to `stderr` and exit code `1`.
   - Reject unknown `--color` values (only `"auto"`, `"always"`, and `"never"`
     are valid) with an error to `stderr` and exit code `1`.
3. **Reject unknown flags and validate subcommand options:**
   - In `sync`, `list` (`files`), `duplicates`, and `unique`, do not silently
     ignore unknown flags (arguments starting with `-`) or flags missing their
     required value (e.g. trailing `--type` or `--sort`). Print an error to
     `stderr` and return `1`.
   - Validate `--type` values (`all`, `file`, `dir`) and `--sort` values
     (`path`, `size`, `mtime`). Return exit code `1` with a descriptive message
     on `stderr` for unrecognized values.
   - Ensure unknown global flags passed before the subcommand are caught and
     reported clearly rather than leaking into subcommands and being ignored.
4. **Prevent conflicting `sync` arguments:**
   - In `handleSyncCommand`, reject passing both a `<name>` and `--all`
     simultaneously with a usage error on `stderr` and exit code `1`.

## 2. Code Style Compliance (`codestyle.md`)

1. **Module visibility (`private:` section):**
   - Place all internal helper structs and functions (`printUsage`,
     `handleRootCommand`, `handleSyncCommand`, `handleListCommand`,
     `handleDuplicatesCommand`, `handleUniqueCommand`, and any new helpers)
     under a single `private:` section below `main`.
2. **Function length limit (<= 50 lines):**
   - Split functions exceeding 50 lines (`main`, `handleRootCommand`,
     `handleSyncCommand`, `handleListCommand`, `handleDuplicatesCommand`,
     `handleUniqueCommand`) into smaller, single-purpose helper functions.
3. **Function parameter count (<= 3 parameters):**
   - Introduce a small POD struct (e.g. `CliContext` or `OutputOptions`) to
     bundle shared output configuration (`OutputFormat fmt`, `Styler styler`,
     `bool fullHash`) and pass it as `in` to command handlers so no handler
     exceeds 3 parameters.
4. **Explicit types & `const` for local variables:**
   - Avoid `auto` when the return type is not obvious from the right-hand side
     (e.g. `rootRepo.listRoots()`, `entryRepo.listEntries(...)`,
     `entryRepo.groupDuplicates(...)`).
   - Remove the unused `auto r =` binding from `getopt(...)`.
   - Mark local variables `const` whenever they are not mutated after
     initialization.
5. **Line length limit (<= 80 columns):**
   - Keep all lines in `source/orglistremo/app.d` at 80 columns or fewer.

## 3. Maintainability & Testability

1. **Deduplicate `duplicates` and `unique` command handlers:**
   - Extract shared helpers for parsing `[<target>] [--type ...] [--skip-empty]`
     and resolving an optional `TargetSpec` against `RootRepository`.
2. **Narrow `version (unittest)` exclusion:**
   - Only exclude `main` under `version (unittest)` so that all command
     handlers and option-parsing helpers are compiled during `dub test` and can
     be unit-tested directly.
3. **Remove unused imports:**
   - Remove unused `defaultGetoptPrinter` and `GetoptResult` from `std.getopt`,
     and unused `stdout` from `std.stdio`.

## 4. `source/orglistremo/config.d` & `source/orglistremo/model.d`

1. **Remove unused imports:**
   - In `source/orglistremo/config.d`, remove unused `isDir` from `std.file`
     import (or verify `isDir(dir)` when `exists(dir)` is true in
     `ensureDbDirectory`).
   - In `source/orglistremo/model.d`, remove unused `canFind` from
     `std.algorithm.searching` import.

## 5. `source/orglistremo/db/connection.d` & `source/orglistremo/db/repo.d`

1. **Fix empty file vs. empty directory collision in duplicates/unique:**
   - Both empty files (`is_dir = 0`) and empty directories (`is_dir = 1`) use
     `sha256 = "0"`. When `typeFilter == EntryType.all` (without
     `--skip-empty`), `GROUP BY sha256` and `groupDuplicates` currently merge
     empty files and empty directories into the same group.
   - Group by both `(is_dir, sha256)` in `listDuplicates` and `listUnique`
     (and order by `e.size DESC, e.is_dir, e.sha256, r.name, e.rel_path ASC`),
     and check both `entries[i].sha256 == currentGroup.sha256` and
     `entries[i].isDir == currentGroup.isDir` in `groupDuplicates`.
2. **Exclude the synthetic root entry (`.`) from `duplicates` and `unique`:**
   - `syncRoot` stores an entry with `rel_path = '.'` for the root directory
     itself. `RootRepository.listRoots` already excludes `e.rel_path != '.'`
     when counting directories, but `listDuplicates` and `listUnique` do not,
     causing `root:/` to appear as a duplicate or unique directory when
     `--type dir` or `--type all` is used. Filter out `rel_path != '.'` in
     `listDuplicates` and `listUnique`.
3. **Deduplicate `listDuplicates` and `listUnique`:**
   - `listDuplicates` and `listUnique` in `source/orglistremo/db/repo.d` are
     nearly identical except for `HAVING COUNT(*) > 1` vs `HAVING COUNT(*) = 1`.
     Extract a shared private helper method.
   - Replace the fragile `replacePrefix` substring replacement with a helper
     that builds the `WHERE` filter string using a table alias prefix parameter
     (`"e."` vs `""`).
4. **Reduce function length (<= 50 lines) and parameter count (<= 3):**
   - Split `EntryRepository.saveSyncEntries` (78 lines) into smaller private
     helpers (e.g. `deleteStaleEntries` and `upsertEntries`).
   - Keep `EntryRepository.listEntries` within 50 lines.
   - Introduce filter structs (e.g. `ListEntriesFilter` and `HashQueryFilter`)
     passed as `in` so `listEntries`, `listDuplicates`, `listUnique`, and
     `bindDuplicateOrUniqueParams` take at most 3 parameters.
5. **Remove unused imports and follow `const` / explicit type rules:**
   - Remove unused `import std.format : format;` in `listEntries`.
   - In `source/orglistremo/db/connection.d` and `source/orglistremo/db/repo.d`
     unit tests, replace `auto` with `const` (or explicit types when mutated)
     for non-obvious return values.

## 6. `source/orglistremo/sync/scanner.d` & `source/orglistremo/sync/hasher.d`

1. **Split `syncRoot` and `scanDirRecursive` (<= 50 lines per function):**
   - In `source/orglistremo/sync/scanner.d`, `syncRoot` is 110 lines and its
     nested `scanDirRecursive` is 84 lines. Extract file-entry scanning and
     directory-entry building into smaller private functions (or a private
     scanner helper struct) so every function is 50 lines or fewer.
2. **Remove dead assignment in `scanDirRecursive`:**
   - Remove line 101
     (`dirEntry.parentPath = (relPath == ".") ? null : relPath;`) which is
     immediately overwritten by lines 108-116.
3. **Clean up temporary file in `hasher.d` unit test:**
   - In `source/orglistremo/sync/hasher.d`, add a `scope (exit)` block in the
     `unittest` to remove `tmpFile` (`listremo_hasher_test.txt`) after testing.
4. **Prefer `const` over `auto`:**
   - In `scanner.d`, use `const` for `cachedMap`, `entries`, and
     `entriesAfterDel`.

## 7. `source/orglistremo/output/` (`formatter.d`, `console.d`, `csv.d`)

1. **Fix ANSI color escape codes breaking console table alignment:**
   - In `source/orglistremo/output/console.d`, `printConsoleRoots` and
     `printConsoleEntries` pass ANSI-styled strings (`styler.header(...)`,
     `styler.root(...)`, `styler.dir(...)`, `styler.date(...)`,
     `styler.size(...)`) into `writefln` width specifiers like `%-18s` or `%8s`.
   - Phobos counts invisible ANSI escape bytes toward the field width, causing
     misaligned columns whenever colors are enabled.
   - Pad/format plain strings to their target column width first (e.g.
     `format("%-18s", name)`), and apply `styler.*` methods after padding.
2. **Style root names in console entry paths per specification:**
   - Per `spec/plan1.md` (Section 7.1), root names in `<root_name>:/<rel_path>`
     should be styled with `styler.root(...)` (bold magenta) and directories
     with `styler.dir(...)` (bold blue with trailing `/`).
   - Extract a shared helper `formatEntryPath(in Entry e, in Styler styler)` in
     `console.d` and use it in both `printConsoleEntries` and
     `printConsoleDuplicates`.
3. **Respect `Root.hasLastSync` when formatting root sync timestamps:**
   - In `console.d` (`printConsoleRoots`) and `csv.d` (`printCsvRoots`), check
     `s.root.hasLastSync` (or pass it to the formatter) rather than relying
     solely on `lastSync <= 0`.
4. **Reduce parameter counts (<= 3) and deduplicate CSV row output:**
   - Bundle `(OutputFormat format, Styler styler, bool fullHash)` into an
     `OutputOptions` struct (shared with `app.d`) so `outputRoots`,
     `outputEntries`, `outputDuplicates`, `outputUnique`, and the
     `printConsole*` functions take at most 3 parameters.
   - Mark slice parameters (`in RootSummary[]`, `in Entry[]`,
     `in DuplicateGroup[]`) and `in Styler` as `in` where applicable.
   - In `source/orglistremo/output/csv.d`, extract a shared private helper for
     writing the `"sha256,size,type,root,full_path,rel_path,mtime"` header and
     rows used by both `printCsvDuplicates` and `printCsvUnique`.
   - Place module-internal helper functions in `console.d` and `csv.d` under a
     `private:` section.
5. **Expand output unit tests:**
   - Add unit tests in `console.d` and `csv.d` verifying `printConsole*` (both
     with `styler.enabled = false` and `styler.enabled = true`) and `printCsv*`
     using an in-memory/temporary `File` stream.

## 8. Verification Steps

1. Run the line-length checker skill across all source and spec files:
   ```bash
   rdmd --compiler=ldc2 \
     .agents/skills/check-line-length/scripts/check_line_length.d \
     source/ spec/review1.md
   ```
2. Build and run unit tests with `ldc2`:
   ```bash
   dub test --compiler=ldc2
   dub build --compiler=ldc2
   ```
