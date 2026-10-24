/**
 * Database subsystem facade for orglistremo.
 *
 * Consumers should import the specific first-level modules (`connection`,
 * `migration`, `repo`, `repo_locks`, `backup`, `transaction`, `schema_version`)
 * explicitly per `codestyle.md`.
 */
module orglistremo.db;

version (unittest) {
  import orglistremo.db.backup;
  import orglistremo.db.connection;
  import orglistremo.db.internal.schema;
  import orglistremo.db.internal.sql;
  import orglistremo.db.migration;
  import orglistremo.db.repo;
  import orglistremo.db.repo_locks;
  import orglistremo.db.schema_version;
  import orglistremo.db.transaction;
}
