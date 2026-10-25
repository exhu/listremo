- support new feature: ignore list per root (does not depend on root source path)
it's a list of glob patterns relative to source root directory that filter what is not included in `sync`,
e.g. when `sync` command is performed the source paths that match the glob
are not scanned and not added to database,
after `sync` is performed app must list which existing directories (or if glob
matches only files and not their parent dirs, then files) where ignored.
To implement this add a new command `ignore <root-name-pattern> [ignore-list-file]`
(root name pattern is handled the same as for `root list` command, the command must
update ignore list to multiple roots if they match a pattern, and display which roots' ignore patterns were updated).
The command accepts a text file where each line describes one glob pattern. Only unique patterns
from the file are added. No duplicate ignore glob patterns for the root must be stored in a database.
When the command is run without `ignore-list-file` argument it displays current
glob list for the roots matching `<root-name-pattern>` (root name, it's ignore list).
Add `ignore-delete <root-name-pattern>` command to clear ignore list for the matching roots, display which
roots' lists were deleted. Update README.md describing the new commands.
Example usage: given a root named `MYROOT` with source path `/mnt/myroot` and
an ignore glob pattern `*~` the following directory tree: `/mnt/myroot/abc.d /mnt/myroot/abc.d~` is
synced as containing only one file `/mnt/myroot/abc.d`


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
