# `listremo` Implementation Plan (`plan1.md`)

## 1. Overview

`listremo` is a command-line tool written in **D** (compiled with `ldc2`) using **SQLite3** to catalog and query files and directories across multiple offline/removable or remote storage roots.

It allows users to:
1. Register, list, update, and remove named storage roots (`roots`).
2. Synchronize (scan & hash) a storage root on request into a local SQLite database.
3. Compute and store SHA-256 hashes for both regular files and directories (bottom-up Merkle tree).
4. Query roots, files/directories, duplicates (per-root or across all roots), and unique entries (per-root or across all roots).
5. Output results as either **coloured console tables/trees** or **RFC 4180 CSV**.

---

## 2. Build System & Dependencies

- **Compiler**: `ldc2` (D language, standard Phobos library).
- **Build Configuration**: `dub.json` (using `dub build --compiler=ldc2`).
- **External Libraries**:
  - **SQLite3**: Use Phobos built-in C bindings (`etc.c.sqlite3`) linked against system `libsqlite3` (`"libs": ["sqlite3"]` in `dub.json`), wrapped in a lightweight, safe RAII D struct layer (`Database`, `Statement`). No third-party DUB dependencies required, keeping builds fast, offline-friendly, and reproducible.
  - **SHA-256**: Phobos `std.digest.sha` (`SHA256`).
  - **CLI Parsing**: Phobos `std.getopt`.
  - **Filesystem Traversal**: Phobos `std.file`, `std.path`, `std.datetime`.

---

## 3. Project Structure

```text
listremo/
├── dub.json
├── README.md
├── spec/
│   └── plan1.md
└── source/
    ├── app.d               # Entry point, subcommand routing, global CLI flags
    ├── config.d            # DB path resolution (--db, LISTREMO_DB, XDG default)
    ├── db/
    │   ├── connection.d    # RAII wrapper over etc.c.sqlite3 + schema migrations
    │   └── repo.d          # Typed queries for roots, entries, duplicates, uniques
    ├── model.d             # Domain structs: Root, Entry, EntryType, DuplicateGroup
    ├── sync/
    │   ├── scanner.d       # Filesystem walk, incremental diffing, bottom-up dir hashing
    │   └── hasher.d        # Streaming file SHA-256 & Merkle directory SHA-256
    └── output/
        ├── formatter.d     # Output interface & format selector (console vs csv)
        ├── console.d       # ANSI coloured terminal output (auto-detects TTY / --color)
        └── csv.d           # Standard CSV serializer with proper escaping
```

---

## 4. Database Schema (SQLite3)

Default database location:
1. `--db <path>` CLI option if provided.
2. `LISTREMO_DB` environment variable if set.
3. `$XDG_DATA_HOME/listremo/listremo.db` (fallback: `~/.local/share/listremo/listremo.db`).

### Pragmas
On connection open:
```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
```

### Tables

```sql
CREATE TABLE IF NOT EXISTS roots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,      -- User-friendly alias (e.g. "backup_hdd_1")
    path        TEXT NOT NULL,             -- Canonical mount/directory path on disk
    created_at  INTEGER NOT NULL,          -- Unix timestamp (seconds)
    last_sync   INTEGER                    -- Unix timestamp of last successful sync (NULL if never synced)
);

CREATE TABLE IF NOT EXISTS entries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    root_id     INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
    rel_path    TEXT NOT NULL,             -- Path relative to root (e.g. "photos/2025/img.jpg", "." for root itself)
    parent_path TEXT,                      -- Relative path of parent directory (NULL for ".")
    name        TEXT NOT NULL,             -- Base filename or directory name
    is_dir      INTEGER NOT NULL,          -- 0 = regular file, 1 = directory
    size        INTEGER NOT NULL,          -- File size in bytes; for directories: recursive sum of file sizes
    mtime       INTEGER NOT NULL,          -- Last modification time (Unix timestamp in seconds)
    sha256      TEXT NOT NULL,             -- 64-char lowercase hex SHA-256, or "0" for empty file / empty directory
    UNIQUE(root_id, rel_path)
);

CREATE INDEX IF NOT EXISTS idx_entries_root_id ON entries(root_id);
CREATE INDEX IF NOT EXISTS idx_entries_sha256 ON entries(sha256);
CREATE INDEX IF NOT EXISTS idx_entries_root_sha256 ON entries(root_id, sha256);
CREATE INDEX IF NOT EXISTS idx_entries_is_dir_sha256 ON entries(is_dir, sha256);
```

---

## 5. Hashing Specification

### 5.1 File Hashing
- **Empty File (`size == 0`)**:
  - If a regular file has `size == 0`, its `sha256` is `"0"` (no disk read or SHA-256 calculation required).
- **Non-Empty File (`size > 0`)**:
  - Read file in chunks (e.g., 1 MiB buffer) using `std.stdio.File.byChunk` and feed into `SHA256`.
  - Store lowercase 64-character hexadecimal string via `toHexString!(LetterCase.lower)`.
- **Incremental Sync Optimization**:
  - Prior to scanning a root, load existing file metadata (`rel_path -> {size, mtime, sha256}`) for that `root_id` into an in-memory hash map.
  - If an existing file entry (`is_dir == 0`) has identical `size` and `mtime` (and `--force-hash` is not set), reuse the stored `sha256` without re-reading the file contents.
  - Otherwise, compute the file's SHA-256 from disk (or `"0"` if `size == 0`).

### 5.2 Directory Hashing & Size
- Computed **bottom-up** (post-order traversal: deepest subdirectories first, up to the root).
- **Empty Directory**:
  - If a directory contains no files and no subdirectories, its `sha256` is `"0"` and its `size` is `0`.
- **Non-Empty Directory**:
  - Collect all immediate children (files and subdirectories) of the directory.
  - Sort immediate children deterministically by `name` (lexicographical UTF-8 byte order).
  - Compute SHA-256 over the concatenation of records for each child:
    ```text
    "<type>:<name>:<child_sha256>\n"
    ```
    where `<type>` is `"D"` for a directory or `"F"` for a file, `<name>` is the child's base name, and `<child_sha256>` is the child's computed `sha256` (which is `"0"` for empty files or empty subdirectories).
  - Because each child directory's `sha256` already encodes its own subtree's names and hashes, this Merkle construction guarantees that a directory hash depends on all file and directory names and hashes in its entire subtree.
  - Directory `size` is the sum of `size` of all immediate children (which equals the total recursive byte size of all files under that directory).

### 5.3 Symlinks & Special Files
- By default, skip symlinks (or log a warning) and special device/socket/FIFO files so cyclic symlinks or broken offline targets do not break synchronization.

---

## 6. CLI Command Design & Path Formatting

### Path Representation & Target Specifier (`<root_name>:/<rel_path>`)
When referring to remote/cataloged entries in CLI arguments and query outputs (`list`/`files`, `duplicates`, `unique`), the **full path** is always formatted relative to `root_name`, never the local mount path (`roots.path`) it was synced from:
- Format: `<root_name>:/<rel_path>` (or `<root_name>:/` for the root directory `.` itself).
- Example: `backup_hdd_1:/photos/2025/img.jpg`.
- Target specifier parsing:
  - `<root_name>` or `<root_name>:` or `<root_name>:/` refers to the entire root `<root_name>`.
  - `<root_name>:/<subpath>` (or `<root_name>:<subpath>`, stripping leading/trailing `/`) refers to `<subpath>` and everything below it on `<root_name>`.
- The local mount path is only used during `sync` and shown in `root list`.

### Global Options
- `--db <path>`: Override SQLite database path.
- `--format <console|csv>` (or `--csv` shorthand): Select output format (default: `console`).
- `--color <auto|always|never>`: Control ANSI colors in console mode (default: `auto`, checks `isatty`).

### Subcommands

#### 1. Manage Roots
```bash
# Add a new storage root
listremo root add <name> <path>

# Remove a storage root and all its cataloged entries
listremo root remove <name>

# Update mount path of an existing root (if mounted elsewhere later)
listremo root set-path <name> <new_path>

# List all registered roots (answers: "what roots there are?")
listremo root list
```
- `root list` displays: `name`, `path` (configured sync mount path), `last_sync` (formatted timestamp or `never`), `file_count`, `dir_count`, `total_size`.

#### 2. Synchronize a Root
```bash
# Synchronize one root or all roots (if reachable)
listremo sync <name> [--force-hash]
listremo sync --all [--force-hash]
```
- Verifies that the root's `path` exists and is a directory (ensuring an unmounted path isn't accidentally synced as empty).
- Traverses the filesystem, reuses unchanged file hashes unless `--force-hash` is given, assigns `"0"` to empty files and empty directories, computes non-empty directory hashes bottom-up, and updates the root's entries inside a single SQLite transaction (`BEGIN IMMEDIATE ... COMMIT`).
- Removes stale database entries for that root that no longer exist on disk.
- Updates `roots.last_sync`.

#### 3. List Files & Directories on a Root (or Subpath)
Answers: *"what files and directories (full path) live on a root, their size, modification date?"*
```bash
# List entire root
listremo list <root_name> [--type <all|file|dir>] [--sort <path|size|mtime>]

# List only a specific directory/file and its subtree
listremo list <root_name>:/<relative-path> [--type <all|file|dir>] [--sort <path|size|mtime>]
```
*(Note: `listremo files` is supported as an alias for `listremo list`.)*
- **Subtree Filtering**:
  - When `<root_name>` (or `<root_name>:/`) is given: returns all entries for `root_id`.
  - When `<root_name>:/<subpath>` is given (normalized to `subpath` without leading/trailing `/`): filters SQL query with:
    ```sql
    WHERE e.root_id = :root_id
      AND (e.rel_path = :subpath OR e.rel_path LIKE :subpath_prefix ESCAPE '\')
    ```
    where `:subpath_prefix` is `escapeLike(subpath) ~ "/%"`.
- Outputs: `full_path` (`<root_name>:/<rel_path>`), `type` (`F`/`D`), `size`, `mtime` (ISO-8601 `YYYY-MM-DD HH:MM:SS`), `sha256`.

#### 4. List Duplicates
Answers:
- *"what duplicate files are within the root?"*
- *"what duplicate files are across all roots?"*
```bash
# Duplicates across all roots
listremo duplicates [--type <file|dir|all>] [--skip-empty]

# Duplicates within a single root (or optional subpath root_name:/relative-path)
listremo duplicates <root_name>[:/<relative-path>] [--type <file|dir|all>] [--skip-empty]
```
- Default `--type` is `file` (can also query `dir` or `all`).
- `--skip-empty`: When passed, excludes zero-length entries (`size == 0` / `sha256 == "0"`).
- **Query Logic**:
  - **Within a root (`<root_name>`)**:
    Finds all entries in `<root_name>` (and optional `<subpath>`) where `sha256` appears `> 1` time within that scope:
    ```sql
    SELECT e.id, r.name AS root_name, e.rel_path, e.is_dir, e.size, e.mtime, e.sha256
    FROM entries e
    JOIN roots r ON r.id = e.root_id
    WHERE e.root_id = :root_id
      AND (:type_filter = -1 OR e.is_dir = :type_filter)
      AND (:skip_empty = 0 OR (e.size > 0 AND e.sha256 != '0'))
      AND e.sha256 IN (
          SELECT sha256 FROM entries
          WHERE root_id = :root_id
            AND (:type_filter = -1 OR is_dir = :type_filter)
            AND (:skip_empty = 0 OR (size > 0 AND sha256 != '0'))
          GROUP BY sha256
          HAVING COUNT(*) > 1
      )
    ORDER BY e.size DESC, e.sha256, r.name, e.rel_path;
    ```
  - **Across all roots**:
    Same query without `root_id = :root_id` filter, finding all entries whose `sha256` has `COUNT(*) > 1` across the entire database.

#### 5. List Unique Files
Answers:
- *"what are unique files across all roots?"*
- *"what are unique files in a root?"*
```bash
# Unique across all roots (files that have only 1 copy across all roots)
listremo unique [--type <file|dir|all>] [--skip-empty]

# Unique within a root (files in <root_name> that have only 1 copy inside <root_name>)
listremo unique <root_name>[:/<relative-path>] [--type <file|dir|all>] [--skip-empty]
```
- Default `--type` is `file`.
- **Query Logic**:
  - **Within a root (`<root_name>`)**:
    Entries in `<root_name>` whose `sha256` occurs exactly once (`HAVING COUNT(*) = 1`) within `<root_name>`.
  - **Across all roots**:
    Entries across the database whose `sha256` occurs exactly once (`HAVING COUNT(*) = 1`) across all roots combined.

---

## 7. Output Formats

### 7.1 Coloured Console Output (`--format console`)
- Uses ANSI escape codes when stdout is a TTY (or `--color=always`):
  - **Headers**: Bold Cyan
  - **Root Names**: Bold Magenta (in `<root_name>:/<rel_path>`)
  - **Directories**: Bold Blue (with trailing `/`)
  - **File Sizes**: Human-readable (`1.24 GiB`, `450 KiB`) in Yellow/Green
  - **Hashes**: Dim/Gray (truncated to 12 chars by default in console mode, `"0"` shown as `0`, or full 64 chars with `--full-hash`)
  - **Duplicate Groups**: Grouped visually by `sha256` + `size`, listing each matching `<root_name>:/<rel_path>` underneath.

### 7.2 CSV Output (`--format csv` or `--csv`)
- Strict RFC 4180 compliance (comma-separated, fields containing commas/quotes/newlines enclosed in double quotes with `""` escaping).
- Machine-friendly raw values:
  - `full_path` is always `<root_name>:/<rel_path>` (never the local sync mount path).
  - `size` in exact bytes (integer).
  - `mtime` in ISO-8601 UTC/local format (`YYYY-MM-DDTHH:MM:SS`).
  - `sha256` always full 64-char hex (or `"0"` for empty files and empty dirs).
- Columns by command:
  - `root list`: `name,path,last_sync,file_count,dir_count,total_size`
  - `list` / `files`: `root,full_path,rel_path,type,size,mtime,sha256`
  - `duplicates` / `unique`: `sha256,size,type,root,full_path,rel_path,mtime`

---

## 8. Implementation Milestones

1. **Milestone 1: Project Scaffolding & SQLite Layer**
   - Create `dub.json` targeting `ldc2`.
   - Implement `source/db/connection.d` (RAII SQLite3 wrapper + schema creation) and `source/model.d`.
   - Unit test database initialization and CRUD operations using in-memory SQLite (`:memory:`).
2. **Milestone 2: Root Management & Sync Engine**
   - Implement `root add`, `root remove`, `root set-path`, `root list`.
   - Implement `source/sync/hasher.d` and `source/sync/scanner.d` (incremental file hashing, `"0"` for empty files and empty directories, bottom-up Merkle directory hashing).
   - Add unit & integration tests with temporary directory trees verifying file hashes, empty file/directory `"0"` hashes, and non-empty directory Merkle hashes.
3. **Milestone 3: Queries (`list`/`files`, `duplicates`, `unique`)**
   - Implement target specifier parser (`<root_name>` and `<root_name>:/<relative-path>`) and SQL queries in `source/db/repo.d` for listing files/dirs (whole root or subtree), duplicates (single root/subtree & all roots, with `--skip-empty`), and uniques (single root/subtree & all roots).
   - Add unit tests covering subtree filtering, single-root and multi-root duplicate/unique scenarios, and `--skip-empty`.
4. **Milestone 4: Console & CSV Formatters + CLI Polish**
   - Implement `source/output/console.d` and `source/output/csv.d` using `<root_name>:/<rel_path>` as `full_path`.
   - Wire all subcommands and flags in `source/app.d`.
   - End-to-end CLI verification.
