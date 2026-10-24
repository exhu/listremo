module orglistremo.db.transaction;

import d2sqlite3 : Database;
import d2sqlite3.sqlite3 : sqlite3_get_autocommit;

package(orglistremo) void withTransaction(
  ref Database db,
  scope void delegate() action
) {
  if (sqlite3_get_autocommit(db.handle) == 0) {
    action();
    return;
  }
  db.execute("BEGIN IMMEDIATE;");
  scope (failure) {
    db.execute("ROLLBACK;");
  }
  action();
  db.execute("COMMIT;");
}
