- review source code
- manually test
- bug: during sync characters from previous path are left if the current path string is shorter
e.g. `| a/b/c (23%)3%)` instead of clean `| a/b/c (23%)`
- forbid multiple processes from reusing the same database for write?
- schema version into db, migration options (sync disk takes a lot of time to waste already collected sha)
- [x] display progress while syncing
