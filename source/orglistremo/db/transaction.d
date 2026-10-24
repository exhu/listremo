module orglistremo.db.transaction;

import d2sqlite3 : Database;

package(orglistremo) void withTransaction(
  ref Database db,
  scope void delegate() action
) {
  db.execute("BEGIN IMMEDIATE;");
  scope (failure) {
    db.execute("ROLLBACK;");
  }
  action();
  db.execute("COMMIT;");
}
