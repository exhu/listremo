module orglistremo.db.internal.schema;

import d2sqlite3 : Database, ResultRange, Row, Statement;

package(orglistremo):

bool tableExists(ref Database db, string tableName) {
  Statement stmt = db.prepare(`
    SELECT 1 FROM sqlite_master
    WHERE type = 'table' AND name = ?
    LIMIT 1;
  `);
  stmt.bind(1, tableName);
  ResultRange results = stmt.execute();
  return !results.empty;
}

bool columnExists(
  ref Database db,
  string tableName,
  string columnName
) {
  import std.format : format;

  Statement stmt = db.prepare(
    format("PRAGMA table_info(%s);", tableName)
  );
  ResultRange results = stmt.execute();
  foreach (Row row; results) {
    if (row.peek!string(1) == columnName) {
      return true;
    }
  }
  return false;
}
