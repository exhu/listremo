/**
 * CLI subsystem facade for orglistremo.
 *
 * Consumers should import the specific first-level modules (`args`, `context`,
 * `roots`, `usage`, `root_cmd`, `sync_cmd`, `query_cmd`, `migrate_cmd`,
 * `import_cmd`) explicitly per `codestyle.md`.
 */
module orglistremo.cli;

version (unittest) {
  import orglistremo.cli.args;
  import orglistremo.cli.context;
  import orglistremo.cli.import_cmd;
  import orglistremo.cli.migrate_cmd;
  import orglistremo.cli.query_cmd;
  import orglistremo.cli.root_cmd;
  import orglistremo.cli.roots;
  import orglistremo.cli.sync_cmd;
  import orglistremo.cli.usage;
}
