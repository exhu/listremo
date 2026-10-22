- add filter options e.g. to display items matching by name via glob pattern, sha256 (using only
  what sqlite can help with) to `list` command:
  extend `list` command to support options `--glob`, `--hash`.
  `--glob` option makes `list` match by sqlite GLOB operator instead of LIKE (support escaping
  and syntax which sqlite supports natively for GLOB).
  `--hash` accepts hash pattern after it, the pattern is the same as sqlite LIKE supports,
  target path is optional and must be passed before `--hash` parameter.
  Document syntax in usage help (`--help`), also document `root:/path` syntax
  for `list` command there.

- separate app: support thumbnailer as external app to gradually or
selectively add thumbnails, e.g. list a path to rescan adding missing or
regenerating outdated (or forced) thumbnails, it's a good idea to have a
separate db for this.

SQLite's internal performance threshold typically dictates that BLOBs under
~100 KB are read faster from SQLite than from individual filesystem calls. If
your thumbnails are high-resolution (e.g., 512px–1024px WebP/JPEG exceeding
100–200 KB each), storing them as loose files on disk and saving only relative
paths in thumbs.db may yield better performance.

- review source code (partially done)

- backlog: display tree list as xml?
