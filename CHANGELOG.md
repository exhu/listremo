# Changelog

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
