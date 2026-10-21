- display tree list as xml, html with collapsible tree
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
