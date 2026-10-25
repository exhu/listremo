- This is a D project that is compiled with ldc2. Use dub to build and test.
- Ignore tilda backup files (e.g. `app.d~`) and emacs autosave (e.g. `#app.d#`)
- Do not add absolute paths (e.g. BAD /home/user/...) to sources or md files,
  use relative paths instead (GOOD ../spec/plan1.md).
- Follow custom D code style in `codestyle.md`
- In documentation (e.g. *.md) files keep line length 80 columns max.
- Write agent skills in D and run them with rdmd.
- Increment schemaVersion in source/orglistremo/db/schema_version.d and update
  migrateDatabase in source/orglistremo/db/connection.d when changing sql
  tables.
- Increment appVersion in source/orglistremo/app_version.d after introducing
  changes or bug fixes.
- Update CHANGELOG.md with a brief description of new features or changes when
  introducing changes.
- When asked to review code produce improvement plan as markdown file with
unique name in `reviews` directory (e.g. `<date><model_name_version><short git
hash>.md`), do not overwrite any existing file. Review plan must mention current
git hash and branch of working copy, the LLM model which performed the review,
and any confusing, duplicated, buggy, slow code findings, and codestyle
violations.
- Architecture & codebase map is maintained in `ARCHITECTURE.md`, keep it
  updated when introducing changes to code.
- Read `ARCHITECTURE.md` before running wide directory searches (`find`, `grep`,
  etc.) to locate entry points and understand module boundaries, e.g. before
  developing new feature, refactoring.
- **Prevent Bloat:** Keep `ARCHITECTURE.md` under 150 lines. Document high-level
  directories, critical boundary files, data flows, and non-negotiable
  conventions only. Do not list individual helper files, standard tests, or
  implementation details.
- Ignore `prompts` , `reviews`, `archived-docs` directories if they are not mentioned
in the prompt explicitly.
