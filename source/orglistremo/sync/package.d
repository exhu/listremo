/**
 * Sync subsystem facade for orglistremo.
 *
 * Consumers should import the specific first-level modules (`hasher`,
 * `progress`, `scanner`) explicitly per `codestyle.md`.
 */
module orglistremo.sync;

version (unittest) {
  import orglistremo.sync.hasher;
  import orglistremo.sync.progress;
  import orglistremo.sync.scanner;
}
