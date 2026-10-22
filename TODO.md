- add `import` command that accepts extra database file name whose data to import.
Command works only if schema versions are the same for both databases.
Command should write a backup like it does for `migrate` command (and no-backup option), and only then
import new roots, and their files, then update existing roots only if the
imported ones have more recent synchronization date.
Implement `--no-update` option that skips update, and allows only new roots being added.
Note the fields that need to be unique for the existing table cannot be copied from the imported database
as is, e.g. new ids will be needed. Implement import command in a separate D module.
Display summary on finish: report which new roots were imported, which were updated, which were not updated
because older sync date or skipped via --no-update option. Also print summary on how many new files and dirs
were added. Display how much time the import process has taken.

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
