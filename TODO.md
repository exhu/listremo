- review source code
- manually test
- bug: during sync characters from previous path are left if the current path string is shorter
e.g. `| a/b/c (23%)3%)` instead of clean `| a/b/c (23%)`
- schema version into db, migration options (sync disk takes a lot of time to
waste already collected sha) when db schema version is different from app's one
work in read-only mode, display a warning. Refuse to do sync. Add migration
command, save a copy of old db before migration (do not overwrite existing
files, keep asking user to provide a name of a backup file until the file with
proposed name does not exist. Proposed name:
"\<old-db-name\>-backup-\<integer-number\>.db", where integer-number is
incremented until there's no such file in the proposed path), add a flag to
force ignore saving a backup).
- add free space to root data
- display total time in the end
- forbid multiple processes from reusing the same database for write?
