- fix what is in reviews/2026-10-24-merged-plan-gemini-4-argon-2af79c7.md
 Tip
  │ Since executing all 5 phases is a multi-step effort across the codebase, you can use /teamwork to have multiple agents
  │ execute independent workstreams, or /goal to run the phased refactoring and verification end-to-end.


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
