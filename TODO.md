- make `list`, `duplicates`, `unique` commands accept not only one but many patterns,
e.g. `listremo list disks% copies:/disks` will display items matching
first pattern, then items matching the second pattern;
`listremo duplicates disks% copies:/disks` will display only those
two or more items from both patterns that have the same hash value;
`listremo unique disks% copies:/disks` will display only those
items from both patterns that have unique hash value.

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
