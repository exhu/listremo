- support `%` as a glob pattern for root names and paths in `sync` and `list`
  commands: e.g. `%` matches all, `abc%` matches all root names or paths
  prefixed with `abc` etc. so the behaviour is the same as `LIKE` operator in
  sqlite).

  When passed a pattern to `sync` it proceeds only if one root matches, however
  `sync --all [pattern]` to sync all roots that match the pattern (the pattern
  is optional),
  and `root list [pattern]` (lists only roots which name is matching the pattern),
  `list <target_pattern>` (this must support multiple roots if prefix does not
  include `:` root and path separator).

- add filter options e.g. to display items matching by name, sha256 (using only
  what sqlite can help with)
- separate app: support thumbnailer as external app to gradually or selectively add
thumbnails, e.g. list a path to rescan adding missing or regenerating outdated
(or forced) thumbnails, it's a good idea to have a separate db for this.

SQLite's internal performance threshold typically dictates that BLOBs under ~100
KB are read faster from SQLite than from individual filesystem calls. If your
thumbnails are high-resolution (e.g., 512px–1024px WebP/JPEG exceeding 100–200
KB each), storing them as loose files on disk and saving only relative paths in
thumbs.db may yield better performance.

- review source code
- manually test

- backlog: display tree list as xml?
