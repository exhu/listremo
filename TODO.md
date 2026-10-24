- fix what is in reviews/2026-10-24-merged-plan-gemini-4-argon-2af79c7.md
 Tip
  │ Since executing all 5 phases is a multi-step effort across the codebase, you can use /teamwork to have multiple agents
  │ execute independent workstreams, or /goal to run the phased refactoring and verification end-to-end.

  ### What to do when your 5h quota resets:

  Whenever you are ready to continue with the remaining phases (Phase 3: Database Consolidation, Phase 4: CLI Modularization,
  Phase 5: Output/Assets/Codestyle), simply send:

    /teamwork implement plan @reviews/2026-10-24-merged-plan-gemini-4-argon-2af79c7.md starting from Phase 3

  or

    Continue implementing the plan starting from Phase 3

  Your repository is completely clean, stable, and ready to pick up right where it left off.


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
