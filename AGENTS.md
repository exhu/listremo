- This is a D project that is compiled with ldc2. Use dub to build and test.
- Ignore tilda backup files (e.g. `app.d~`) and emacs autosave (e.g. `#app.d#`)
- Do not add absolute paths (e.g. BAD /home/user/...) to sources or md files,
  use relative paths instead (GOOD ../spec/plan1.md).
- Follow custom D code style in codestyle.md
- In documentation (e.g. *.md) files keep line length 80 columns max.
- Write agent skills in D and run them with rdmd.
- Increment schemaVersion in source/orglistremo/db/schema_version.d and update
  migrateDatabase in source/orglistremo/db/connection.d when changing sql
  tables.
- Increment appVersion in source/orglistremo/app_version.d after introducing
  changes or bug fixes.
- Update CHANGELOG.md with a brief description of new features or changes when
  introducing changes.
