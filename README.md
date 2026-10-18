# listremo

A command-line tool to catalog and query offline files split across multiple
drives (referred to as storage roots, which may also be network or cloud
storage mounts).

`listremo` maintains a persistent SQLite catalog of indexed files and
directories, computes cryptographic hashes, detects duplicate and unique
entries across drives or within subtrees, and formats output as readable
console tables or RFC 4180 CSV streams.

The application answers key questions about cataloged storage:
- What storage roots exist? (`listremo root list`)
- What files and directories live on a root or subtree, including their
  sizes and modification dates? (`listremo list <target>`)
- What duplicate files or directories exist within a specific root or subtree?
  (`listremo duplicates <target>`)
- What duplicate files or directories exist across all storage roots?
  (`listremo duplicates`)
- What files or directories are unique across all storage roots?
  (`listremo unique`)
- What files or directories are unique within a specific root?
  (`listremo unique <target>`)

## Features

- Storage root management:
  - Register storage roots with a unique name and mount path.
  - Update root mount paths (`set-path`).
  - Remove registered roots and their cataloged entries (`remove`).
  - List registered roots with total file count, directory count, and size.
- Filesystem synchronization:
  - Recursive scanning of storage roots.
  - Incremental sync: detects unchanged files by size and modification
    timestamp to reuse existing hashes without re-reading file contents.
  - Force re-hashing support with `--force-hash`.
  - Synchronize an individual root or all roots at once (`--all`).
- SHA-256 and Merkle directory hashing:
  - Streaming SHA-256 calculation for file contents (empty files hash as "0").
  - Deterministic Merkle tree hashing for directories based on sorted child
    entry names and hashes (empty directories hash as "0").
- Catalog browsing and filtering:
  - Query entries by root name (`root`) or scoped subtree (`root:/subpath`).
  - Filter entries by type: files, directories, or all entries.
  - Sort output by path, file size, or modification date.
  - Command alias `files` for `list`.
- Duplicate and unique detection:
  - Find duplicate files or directories across all roots or scoped to a target.
  - Find unique files or directories across all roots or scoped to a target.
  - Filter by entry type: files, directories, or all.
  - Option to ignore empty files and empty directories (`--skip-empty`).
- Output formatting:
  - Colorized ANSI console table output with auto-detection for terminals.
  - Compact 8-character hashes by default, or full 64-character SHA-256
    hashes via `--full-hash`.
  - Machine-readable RFC 4180 compliant CSV export (`--csv` or `--format csv`).
- Database and storage:
  - SQLite database backend with Write-Ahead Logging (WAL) and foreign keys.
  - Configurable database path via `--db <path>`, `LISTREMO_DB` environment
    variable, or default XDG data path (`~/.local/share/listremo/listremo.db`).

## CLI Usage

### Global Options

- `--db <path>`: Path to SQLite database file.
- `--format <console|csv>`: Output format (default: `console`).
- `--csv`: Shorthand for `--format csv`.
- `--color <auto|always|never>`: Control ANSI color rendering.
- `--full-hash`: Display full 64-character SHA-256 hashes in console output.

### Commands

- `listremo root add <name> <path>`: Register a new storage root.
- `listremo root remove <name>`: Remove a root and its entries.
- `listremo root set-path <name> <path>`: Update the mount path of a root.
- `listremo root list`: List all registered storage roots and summary stats.
- `listremo sync <name> [--force-hash]`: Synchronize a specific storage root.
- `listremo sync --all [--force-hash]`: Synchronize all storage roots.
- `listremo list <target> [--type file|dir|all] [--sort path|size|mtime]`:
  List cataloged entries (alias: `files`). Target format is `<root>` or
  `<root>:/<subpath>`.
- `listremo duplicates [<target>] [--type file|dir|all] [--skip-empty]`:
  Find duplicate files or directories across all roots or within `<target>`.
- `listremo unique [<target>] [--type file|dir|all] [--skip-empty]`:
  Find unique files or directories across all roots or within `<target>`.

## Building from Source

### Prerequisites

Building `listremo` requires:

- D compiler: LDC (LLVM D Compiler) version 1.42.0 (current version).
- D package manager: DUB (bundled with official LDC releases).
- C linker: `gcc` or `clang` (invoked by `ldc2` as the system linker driver).
- SQLite 3 development library and headers: `libsqlite3-dev`.

Note: `curl`, `tar`, and `xz-utils` are helper tools for downloading and
unpacking the pre-built LDC release archive. `make` is not used by `dub`,
though Debian's `build-essential` package includes it alongside `gcc`.

### Where to Download Fresh LDC2

Official binary releases of LDC for Linux are available at:

- GitHub Releases: https://github.com/ldc-developers/ldc/releases
- Official D Downloads: https://dlang.org/download.html

The current version of LDC used by this project is `1.42.0`.

### Debian / Ubuntu Build Instructions

1. Install required system packages:

   ```bash
   sudo apt update
   sudo apt install -y build-essential libsqlite3-dev curl tar xz-utils
   ```

2. Download and unpack LDC 1.42.0:

   ```bash
   LDC_URL="https://github.com/ldc-developers/ldc/releases/download"
   LDC_PKG="v1.42.0/ldc2-1.42.0-linux-x86_64.tar.xz"
   curl -LO "$LDC_URL/$LDC_PKG"
   tar -xf ldc2-1.42.0-linux-x86_64.tar.xz
   export PATH="$PWD/ldc2-1.42.0-linux-x86_64/bin:$PATH"
   ```

   Verify compiler and package manager availability:

   ```bash
   ldc2 --version
   dub --version
   ```

3. Compile `listremo`:

   From the project root directory, run:

   ```bash
   dub build -b release --compiler=ldc2
   ```

   This produces the executable `./listremo`.

4. Run tests (optional):

   ```bash
   dub test --compiler=ldc2
   ```

## License

This project is licensed under the GNU General Public License v3.0 or later.
See the [LICENSE](LICENSE) file for full license terms.
