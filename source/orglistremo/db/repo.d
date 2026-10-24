module orglistremo.db.repo;

import d2sqlite3 : Database, ResultRange, Row, SqliteType, Statement;
import orglistremo.db.internal.schema : columnExists;
import orglistremo.db.internal.sql :
  bindNullable, bindSubpath, buildEntrySortSql, buildSubpathSql,
  buildTypeFilterSql, entrySelectSql;
import orglistremo.db.transaction : withTransaction;
import orglistremo.model :
  DuplicateGroup, emptyHash, Entry, EntryType, groupDuplicates, Root,
  RootSummary, SortField, TargetSpec;
import orglistremo.pattern : userPatternToLike;
import std.datetime.systime : Clock;

package(orglistremo):

struct CachedFileEntry {
  ulong size;
  long mtime;
  string sha256;
}

struct SyncSaveParams {
  long rootId;
  long timestamp;
  ulong freeSpace = 0;
  bool hasFreeSpace = false;
}

struct ListEntriesFilter {
  string subpath;
  EntryType typeFilter = EntryType.all;
  SortField sort = SortField.path;
  bool useGlob = false;
  string hashPattern = null;
}

struct HashQueryFilter {
  TargetSpec[] targets;
  EntryType typeFilter = EntryType.file;
  bool skipEmpty = false;
  bool useGlob = false;
}

struct RootRepository {
  this(Database db) {
    this.db = db;
  }

  long addRoot(string name, string path) {
    import std.algorithm.searching : canFind;
    import std.exception : enforce;

    enforce!Exception(name.length > 0, "Root name cannot be empty");
    enforce!Exception(!name.canFind(':'), "Root name cannot contain ':'");
    enforce!Exception(path.length > 0, "Root path cannot be empty");

    const now = Clock.currTime.toUnixTime();
    Statement stmt = db.prepare(`
      INSERT INTO roots (name, path, created_at)
      VALUES (?, ?, ?);
    `);
    stmt.bind(1, name);
    stmt.bind(2, path);
    stmt.bind(3, now);
    stmt.execute();
    return db.lastInsertRowid;
  }

  long insertImportedRoot(in Root srcRoot) {
    import std.algorithm.searching : canFind;
    import std.exception : enforce;

    enforce!Exception(srcRoot.name.length > 0, "Root name cannot be empty");
    enforce!Exception(
      !srcRoot.name.canFind(':'), "Root name cannot contain ':'"
    );
    enforce!Exception(srcRoot.path.length > 0, "Root path cannot be empty");

    Statement stmt = db.prepare(`
      INSERT INTO roots (name, path, created_at, last_sync, free_space)
      VALUES (?, ?, ?, ?, ?);
    `);
    stmt.bind(1, srcRoot.name);
    stmt.bind(2, srcRoot.path);
    stmt.bind(3, srcRoot.createdAt);
    bindNullable(stmt, 4, srcRoot.hasLastSync, srcRoot.lastSync);
    bindNullable(stmt, 5, srcRoot.hasFreeSpace, srcRoot.freeSpace);
    stmt.execute();
    return db.lastInsertRowid;
  }

  void updateImportedRoot(long targetRootId, in Root srcRoot) {
    import std.exception : enforce;

    enforce!Exception(srcRoot.path.length > 0, "Root path cannot be empty");

    Statement stmt = db.prepare(`
      UPDATE roots
      SET path = ?, last_sync = ?, free_space = ?
      WHERE id = ?;
    `);
    stmt.bind(1, srcRoot.path);
    bindNullable(stmt, 2, srcRoot.hasLastSync, srcRoot.lastSync);
    bindNullable(stmt, 3, srcRoot.hasFreeSpace, srcRoot.freeSpace);
    stmt.bind(4, targetRootId);
    stmt.execute();
  }

  bool removeRoot(string name) {
    Statement stmt = db.prepare("DELETE FROM roots WHERE name = ?;");
    stmt.bind(1, name);
    stmt.execute();
    return db.changes > 0;
  }

  bool setPath(string name, string newPath) {
    import std.exception : enforce;

    enforce!Exception(name.length > 0, "Root name cannot be empty");
    enforce!Exception(newPath.length > 0, "New path cannot be empty");
    Statement stmt = db.prepare("UPDATE roots SET path = ? WHERE name = ?;");
    stmt.bind(1, newPath);
    stmt.bind(2, name);
    stmt.execute();
    return db.changes > 0;
  }

  bool findByName(string name, out Root root) {
    Root[] found = selectRoots("WHERE name = ?", (ref Statement stmt) {
      stmt.bind(1, name);
    });
    if (found.length == 0) {
      return false;
    }
    root = found[0];
    return true;
  }

  bool findById(long id, out Root root) {
    Root[] found = selectRoots("WHERE id = ?", (ref Statement stmt) {
      stmt.bind(1, id);
    });
    if (found.length == 0) {
      return false;
    }
    root = found[0];
    return true;
  }

  void updateLastSync(in SyncSaveParams params) {
    if (params.hasFreeSpace) {
      Statement stmt = db.prepare(
        "UPDATE roots SET last_sync = ?, free_space = ? WHERE id = ?;"
      );
      stmt.bind(1, params.timestamp);
      stmt.bind(2, params.freeSpace);
      stmt.bind(3, params.rootId);
      stmt.execute();
    } else {
      Statement stmt = db.prepare(
        "UPDATE roots SET last_sync = ? WHERE id = ?;"
      );
      stmt.bind(1, params.timestamp);
      stmt.bind(2, params.rootId);
      stmt.execute();
    }
  }

  void updateLastSync(
    long rootId,
    long timestamp,
    ulong freeSpace = 0,
    bool hasFreeSpace = false
  ) {
    updateLastSync(
      SyncSaveParams(rootId, timestamp, freeSpace, hasFreeSpace)
    );
  }

  Root[] findByPattern(string pattern) {
    return selectRoots(
      "WHERE name LIKE ? ESCAPE '\\' ORDER BY name",
      (ref Statement stmt) {
        stmt.bind(1, userPatternToLike(pattern));
      }
    );
  }

  Root[] findByGlob(string pattern) {
    return selectRoots(
      "WHERE name GLOB ? ORDER BY name",
      (ref Statement stmt) {
        stmt.bind(1, pattern);
      }
    );
  }

  RootSummary[] listRoots(string pattern = null) {
    import std.format : format;

    const freeCol = hasFreeSpaceColumn()
      ? "r.free_space"
      : "NULL AS free_space";
    string sql = format(`
      SELECT
        r.id, r.name, r.path, r.created_at, r.last_sync, %s,
        COALESCE(SUM(CASE WHEN e.is_dir = 0 THEN 1 ELSE 0 END), 0)
          AS file_count,
        COALESCE(SUM(
          CASE WHEN e.is_dir = 1 AND e.rel_path != '.' THEN 1 ELSE 0 END
        ), 0) AS dir_count,
        COALESCE(SUM(CASE WHEN e.is_dir = 0 THEN e.size ELSE 0 END), 0)
          AS total_size
      FROM roots r
      LEFT JOIN entries e ON e.root_id = r.id
    `, freeCol);

    if (pattern.length > 0) {
      sql ~= " WHERE r.name LIKE ? ESCAPE '\\'";
    }
    sql ~= " GROUP BY r.id ORDER BY r.name;";

    Statement stmt = db.prepare(sql);
    if (pattern.length > 0) {
      stmt.bind(1, userPatternToLike(pattern));
    }
    RootSummary[] summaries;
    ResultRange results = stmt.execute();
    foreach (Row row; results) {
      RootSummary summary;
      summary.root = readRootRow(row);
      summary.fileCount = row.peek!ulong(6);
      summary.dirCount = row.peek!ulong(7);
      summary.totalSize = row.peek!ulong(8);
      summaries ~= summary;
    }
    return summaries;
  }

private:
  enum ColumnCache : byte {
    unknown,
    absent,
    present
  }

  Root[] selectRoots(
    string whereClause,
    scope void delegate(ref Statement) bind = null
  ) {
    import std.format : format;

    const freeCol = hasFreeSpaceColumn()
      ? "free_space"
      : "NULL AS free_space";
    Statement stmt = db.prepare(format(`
      SELECT id, name, path, created_at, last_sync, %s
      FROM roots
      %s;
    `, freeCol, whereClause));
    if (bind !is null) {
      bind(stmt);
    }
    Root[] roots;
    ResultRange results = stmt.execute();
    foreach (Row row; results) {
      roots ~= readRootRow(row);
    }
    return roots;
  }

  bool hasFreeSpaceColumn() {
    if (freeSpaceCache == ColumnCache.unknown) {
      const exists = columnExists(db, "roots", "free_space");
      freeSpaceCache = exists ? ColumnCache.present : ColumnCache.absent;
    }
    return freeSpaceCache == ColumnCache.present;
  }

  static Root readRootRow(Row row) {
    Root r;
    r.id = row.peek!long(0);
    r.name = row.peek!string(1);
    r.path = row.peek!string(2);
    r.createdAt = row.peek!long(3);
    if (row[4].type != SqliteType.NULL) {
      r.lastSync = row[4].as!long;
      r.hasLastSync = true;
    } else {
      r.lastSync = 0;
      r.hasLastSync = false;
    }
    if (row[5].type != SqliteType.NULL) {
      r.freeSpace = row[5].as!ulong;
      r.hasFreeSpace = true;
    } else {
      r.freeSpace = 0;
      r.hasFreeSpace = false;
    }
    return r;
  }

  Database db;
  ColumnCache freeSpaceCache = ColumnCache.unknown;
}

struct EntryRepository {
  this(Database db) {
    this.db = db;
  }

  CachedFileEntry[string] getFileEntriesMap(long rootId) {
    CachedFileEntry[string] cache;
    Statement stmt = db.prepare(`
      SELECT rel_path, size, mtime, sha256
      FROM entries
      WHERE root_id = ? AND is_dir = 0;
    `);
    stmt.bind(1, rootId);
    ResultRange results = stmt.execute();
    foreach (Row row; results) {
      const relPath = row.peek!string(0);
      const size = row.peek!ulong(1);
      const mtime = row.peek!long(2);
      const sha256 = row.peek!string(3);
      cache[relPath] = CachedFileEntry(size, mtime, sha256);
    }
    return cache;
  }

  bool hasCatalogedEntries(long rootId) {
    Statement stmt = db.prepare(`
      SELECT 1 FROM entries
      WHERE root_id = ? AND rel_path != '.'
      LIMIT 1;
    `);
    stmt.bind(1, rootId);
    ResultRange results = stmt.execute();
    return !results.empty;
  }

  bool[string] getEntryPathsSet(long rootId) {
    bool[string] paths;
    Statement stmt = db.prepare(`
      SELECT rel_path
      FROM entries
      WHERE root_id = ? AND rel_path != '.';
    `);
    stmt.bind(1, rootId);
    ResultRange results = stmt.execute();
    foreach (Row row; results) {
      paths[row.peek!string(0)] = true;
    }
    return paths;
  }

  void replaceRootEntries(long rootId, in Entry[] entries) {
    Statement delStmt = db.prepare("DELETE FROM entries WHERE root_id = ?;");
    delStmt.bind(1, rootId);
    delStmt.execute();
    if (entries.length > 0) {
      upsertEntries(rootId, entries);
    }
  }

  void clearRootEntries(long rootId) {
    Statement delStmt = db.prepare("DELETE FROM entries WHERE root_id = ?;");
    delStmt.bind(1, rootId);
    delStmt.execute();
  }

  void upsertEntriesBatch(long rootId, in Entry[] batch) {
    if (batch.length == 0) {
      return;
    }
    withTransaction(db, {
      upsertEntries(rootId, batch);
    });
  }

  void ensureStagingTable() {
    db.execute(`
      CREATE TEMP TABLE IF NOT EXISTS sync_staged_entries (
        root_id     INTEGER NOT NULL,
        rel_path    TEXT NOT NULL,
        parent_path TEXT,
        name        TEXT NOT NULL,
        is_dir      INTEGER NOT NULL,
        size        INTEGER NOT NULL,
        mtime       INTEGER NOT NULL,
        sha256      TEXT NOT NULL,
        PRIMARY KEY(root_id, rel_path)
      );
    `);
  }

  void stageEntriesBatch(long rootId, in Entry[] batch) {
    if (batch.length == 0) {
      return;
    }
    ensureStagingTable();
    Statement stmt = db.prepare(`
      INSERT INTO temp.sync_staged_entries (
        root_id, rel_path, parent_path, name, is_dir, size, mtime, sha256
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(root_id, rel_path) DO UPDATE SET
        parent_path = excluded.parent_path,
        name = excluded.name,
        is_dir = excluded.is_dir,
        size = excluded.size,
        mtime = excluded.mtime,
        sha256 = excluded.sha256;
    `);
    bindAndExecuteEntryBatch(stmt, rootId, batch);
  }

  void clearStagedEntries(long rootId) {
    ensureStagingTable();
    Statement stmt = db.prepare(
      "DELETE FROM temp.sync_staged_entries WHERE root_id = ?;"
    );
    stmt.bind(1, rootId);
    stmt.execute();
  }

  void commitStagedSync(in SyncSaveParams params) {
    ensureStagingTable();
    withTransaction(db, {
      deleteUnstagedEntries(params.rootId);
      upsertFromStaging(params.rootId);
      RootRepository(db).updateLastSync(params);
    });
    clearStagedEntries(params.rootId);
  }

  void commitStagedSync(
    long rootId,
    long syncTimestamp,
    ulong freeSpace = 0,
    bool hasFreeSpace = false
  ) {
    commitStagedSync(
      SyncSaveParams(rootId, syncTimestamp, freeSpace, hasFreeSpace)
    );
  }

  void saveSyncEntries(in SyncSaveParams params, in Entry[] allEntries) {
    stageEntriesBatch(params.rootId, allEntries);
    commitStagedSync(params);
  }

  void saveSyncEntries(
    long rootId,
    in Entry[] allEntries,
    long syncTimestamp,
    ulong freeSpace = 0,
    bool hasFreeSpace = false
  ) {
    saveSyncEntries(
      SyncSaveParams(rootId, syncTimestamp, freeSpace, hasFreeSpace),
      allEntries
    );
  }

  void saveSyncEntries(
    long rootId,
    in Entry[] allEntries,
    in Entry[] remainingEntries,
    long syncTimestamp,
    ulong freeSpace = 0,
    bool hasFreeSpace = false
  ) {
    saveSyncEntries(
      SyncSaveParams(rootId, syncTimestamp, freeSpace, hasFreeSpace),
      allEntries
    );
  }

  Entry[] listEntriesByRootId(
    long rootId,
    in ListEntriesFilter filter = ListEntriesFilter.init
  ) {
    return queryEntries(
      "WHERE e.root_id = ?",
      filter,
      false,
      (ref Statement stmt, ref int idx) {
        stmt.bind(idx++, rootId);
      }
    );
  }

  Entry[] listEntriesByPattern(
    string rootPattern,
    in ListEntriesFilter filter = ListEntriesFilter.init
  ) {
    const string whereRoot = filter.useGlob
      ? "WHERE r.name GLOB ?"
      : "WHERE r.name LIKE ? ESCAPE '\\'";
    return queryEntries(
      whereRoot,
      filter,
      true,
      (ref Statement stmt, ref int idx) {
        if (filter.useGlob) {
          stmt.bind(idx++, rootPattern);
        } else {
          stmt.bind(idx++, userPatternToLike(rootPattern));
        }
      }
    );
  }

  Entry[] listEntries(
    long rootId,
    in ListEntriesFilter filter = ListEntriesFilter.init
  ) {
    return listEntriesByRootId(rootId, filter);
  }

  Entry[] listEntries(
    string rootPattern,
    in ListEntriesFilter filter = ListEntriesFilter.init
  ) {
    return listEntriesByPattern(rootPattern, filter);
  }

  Entry[] listDuplicates(in HashQueryFilter filter = HashQueryFilter.init) {
    return queryGroupedEntries(filter, "COUNT(*) > 1");
  }

  Entry[] listUnique(in HashQueryFilter filter = HashQueryFilter.init) {
    return queryGroupedEntries(filter, "COUNT(*) = 1");
  }

  static DuplicateGroup[] groupDuplicates(in Entry[] entries) {
    return .groupDuplicates(entries);
  }

private:
  void deleteUnstagedEntries(long rootId) {
    Statement delStmt = db.prepare(`
      DELETE FROM entries
      WHERE root_id = ?
        AND rel_path NOT IN (
          SELECT rel_path FROM temp.sync_staged_entries WHERE root_id = ?
        );
    `);
    delStmt.bind(1, rootId);
    delStmt.bind(2, rootId);
    delStmt.execute();
  }

  void upsertFromStaging(long rootId) {
    Statement upsertStmt = db.prepare(`
      INSERT INTO entries (
        root_id, rel_path, parent_path, name, is_dir, size, mtime, sha256
      )
      SELECT
        root_id, rel_path, parent_path, name, is_dir, size, mtime, sha256
      FROM temp.sync_staged_entries
      WHERE root_id = ?
      ON CONFLICT(root_id, rel_path) DO UPDATE SET
        parent_path = excluded.parent_path,
        name = excluded.name,
        is_dir = excluded.is_dir,
        size = excluded.size,
        mtime = excluded.mtime,
        sha256 = excluded.sha256;
    `);
    upsertStmt.bind(1, rootId);
    upsertStmt.execute();
  }

  void upsertEntries(long rootId, in Entry[] newEntries) {
    Statement upsertStmt = db.prepare(`
      INSERT INTO entries (
        root_id, rel_path, parent_path, name, is_dir, size, mtime, sha256
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(root_id, rel_path) DO UPDATE SET
        parent_path = excluded.parent_path,
        name = excluded.name,
        is_dir = excluded.is_dir,
        size = excluded.size,
        mtime = excluded.mtime,
        sha256 = excluded.sha256;
    `);
    bindAndExecuteEntryBatch(upsertStmt, rootId, newEntries);
  }

  static void bindAndExecuteEntryBatch(
    ref Statement stmt,
    long rootId,
    in Entry[] entries
  ) {
    foreach (ref const e; entries) {
      stmt.reset();
      stmt.bind(1, rootId);
      stmt.bind(2, e.relPath);
      bindNullable(
        stmt,
        3,
        e.parentPath !is null && e.parentPath.length > 0,
        e.parentPath
      );
      stmt.bind(4, e.name);
      stmt.bind(5, e.isDir ? 1 : 0);
      stmt.bind(6, e.size);
      stmt.bind(7, e.mtime);
      stmt.bind(8, e.sha256);
      stmt.execute();
    }
  }

  Entry[] queryEntries(
    string whereRootClause,
    in ListEntriesFilter filter,
    bool includeRootInSort,
    scope void delegate(ref Statement, ref int) bindRoot
  ) {
    string sql = entrySelectSql ~ " " ~ whereRootClause;
    sql ~= buildTypeFilterSql(filter.typeFilter, "e.");

    if (filter.subpath.length > 0) {
      sql ~= " AND " ~ buildSubpathSql(filter.subpath, filter.useGlob, "e.");
    }
    if (filter.hashPattern.length > 0) {
      sql ~= " AND e.sha256 LIKE ? ESCAPE '\\'";
    }
    sql ~= buildEntrySortSql(filter.sort, includeRootInSort);

    Statement stmt = db.prepare(sql);
    int paramIdx = 1;
    bindRoot(stmt, paramIdx);
    if (filter.subpath.length > 0) {
      bindSubpath(stmt, paramIdx, filter.subpath, filter.useGlob);
    }
    if (filter.hashPattern.length > 0) {
      stmt.bind(paramIdx++, userPatternToLike(filter.hashPattern));
    }

    return readEntries(stmt);
  }

  Entry[] queryGroupedEntries(
    in HashQueryFilter filter,
    string havingClause
  ) {
    const filterSql = buildFilterSql(filter, "e.", "r.");
    const sql = "WITH scoped_entries AS (" ~
      entrySelectSql ~
      " WHERE " ~ filterSql ~
      ") " ~
      "SELECT * FROM scoped_entries " ~
      "WHERE (is_dir, sha256) IN (" ~
        "SELECT is_dir, sha256 FROM scoped_entries " ~
        "GROUP BY is_dir, sha256 " ~
        "HAVING " ~ havingClause ~
      ") " ~
      "ORDER BY size DESC, is_dir, sha256, name, rel_path ASC";

    Statement stmt = db.prepare(sql);
    int idx = 1;
    bindFilters(stmt, idx, filter);
    return readEntries(stmt);
  }

  static string buildFilterSql(
    in HashQueryFilter filter,
    string entryPrefix,
    string rootPrefix
  ) {
    string s = entryPrefix ~ "rel_path != '.'";
    s ~= buildTypeFilterSql(filter.typeFilter, entryPrefix);

    if (filter.skipEmpty) {
      s ~= " AND " ~ entryPrefix ~ "size > 0 AND " ~ entryPrefix ~
        "sha256 != '" ~ emptyHash ~ "'";
    }

    if (filter.targets.length > 0) {
      s ~= " AND (" ~ buildTargetsSql(filter, entryPrefix, rootPrefix) ~ ")";
    }
    return s;
  }

  static string buildTargetsSql(
    in HashQueryFilter filter,
    string entryPrefix,
    string rootPrefix
  ) {
    string s;
    foreach (i, ref const t; filter.targets) {
      if (i > 0) {
        s ~= " OR ";
      }
      s ~= "(" ~
        buildSingleTargetSql(t, filter.useGlob, entryPrefix, rootPrefix) ~
        ")";
    }
    return s;
  }

  static string buildSingleTargetSql(
    in TargetSpec target,
    bool useGlob,
    string entryPrefix,
    string rootPrefix
  ) {
    string s = useGlob
      ? (rootPrefix ~ "name GLOB ?")
      : (rootPrefix ~ "name LIKE ? ESCAPE '\\'");
    if (target.hasSubpath && target.subpath.length > 0) {
      s ~= " AND " ~ buildSubpathSql(target.subpath, useGlob, entryPrefix);
    }
    return s;
  }

  static void bindFilters(
    ref Statement stmt,
    ref int idx,
    in HashQueryFilter filter
  ) {
    foreach (ref const t; filter.targets) {
      bindSingleTarget(stmt, idx, t, filter.useGlob);
    }
  }

  static void bindSingleTarget(
    ref Statement stmt,
    ref int idx,
    in TargetSpec target,
    bool useGlob
  ) {
    if (useGlob) {
      stmt.bind(idx++, target.rootName);
    } else {
      stmt.bind(idx++, userPatternToLike(target.rootName));
    }
    if (target.hasSubpath && target.subpath.length > 0) {
      bindSubpath(stmt, idx, target.subpath, useGlob);
    }
  }

  static Entry[] readEntries(ref Statement stmt) {
    Entry[] entries;
    ResultRange results = stmt.execute();
    foreach (Row row; results) {
      Entry e;
      e.id = row.peek!long(0);
      e.rootId = row.peek!long(1);
      e.rootName = row.peek!string(2);
      e.relPath = row.peek!string(3);
      if (row[4].type != SqliteType.NULL) {
        e.parentPath = row.peek!string(4);
      }
      e.name = row.peek!string(5);
      e.isDir = row.peek!int(6) == 1;
      e.size = row.peek!ulong(7);
      e.mtime = row.peek!long(8);
      e.sha256 = row.peek!string(9);
      entries ~= e;
    }
    return entries;
  }

  Database db;
}

unittest {
  import orglistremo.db.connection : openDatabase;

  Database db = openDatabase(":memory:");
  RootRepository rootRepo = RootRepository(db);
  EntryRepository entryRepo = EntryRepository(db);

  const r1 = rootRepo.addRoot("r1", "/mnt/r1");
  const r2 = rootRepo.addRoot("r2", "/mnt/r2");

  Entry[] entries1 = [
    Entry(0, r1, "r1", ".", null, ".", true, 100, 1000, "dir_hash"),
    Entry(0, r1, "r1", "f1.txt", ".", "f1.txt", false, 60, 1000, "hash1"),
    Entry(0, r1, "r1", "f2.txt", ".", "f2.txt", false, 40, 1000, "hash2"),
    Entry(0, r1, "r1", "dup.txt", ".", "dup.txt", false, 10, 1000, "hash_dup")
  ];
  entryRepo.saveSyncEntries(r1, entries1, 2000);

  Entry[] entries2 = [
    Entry(0, r2, "r2", ".", null, ".", true, 10, 1000, "dir2_hash"),
    Entry(0, r2, "r2", "copy.txt", ".", "copy.txt", false, 10, 1000, "hash_dup")
  ];
  entryRepo.saveSyncEntries(r2, entries2, 2000);

  // Test caching map
  const cache = entryRepo.getFileEntriesMap(r1);
  assert("f1.txt" in cache);
  assert(cache["f1.txt"].size == 60);
  assert(cache["f1.txt"].sha256 == "hash1");

  // Test listEntriesByRootId
  const list = entryRepo.listEntriesByRootId(
    r1, ListEntriesFilter(null, EntryType.all)
  );
  assert(list.length == 4);

  // Test duplicates within r1 (none)
  HashQueryFilter fR1;
  fR1.targets = [TargetSpec.parse("r1")];
  const dupsR1 = entryRepo.listDuplicates(fR1);
  assert(dupsR1.length == 0);

  // Test duplicates across all roots (hash_dup present in r1 and r2)
  HashQueryFilter fAll;
  const dupsAll = entryRepo.listDuplicates(fAll);
  assert(dupsAll.length == 2);
  assert(dupsAll[0].sha256 == "hash_dup");

  const groups = entryRepo.groupDuplicates(dupsAll);
  assert(groups.length == 1);
  assert(groups[0].entries.length == 2);

  // Test unique across all roots (f1.txt, f2.txt)
  const uniques = entryRepo.listUnique(fAll);
  assert(uniques.length == 2);

  // Test subtree queries
  Entry[] subtreeEntries = [
    Entry(0, r1, "r1", "photos", ".", "photos", true, 50, 1000, "ph_hash"),
    Entry(
      0, r1, "r1", "photos/a.jpg", "photos", "a.jpg", false, 30, 1000, "hA"
    ),
    Entry(
      0, r1, "r1", "photos/b.jpg", "photos", "b.jpg", false, 20, 1000, "hB"
    ),
    Entry(0, r1, "r1", "other/c.jpg", "other", "c.jpg", false, 15, 1000, "hC"),
    Entry(0, r1, "r1", "zero1.txt", ".", "zero1.txt", false, 0, 1000, "0"),
    Entry(0, r1, "r1", "zero2.txt", ".", "zero2.txt", false, 0, 1000, "0"),
    Entry(0, r1, "r1", "empty_dir", ".", "empty_dir", true, 0, 1000, "0")
  ];
  entryRepo.saveSyncEntries(r1, subtreeEntries, 3000);

  // Subpath "photos" should only return photos, photos/a.jpg, photos/b.jpg
  const subList = entryRepo.listEntriesByRootId(
    r1, ListEntriesFilter("photos")
  );
  assert(subList.length == 3);

  // Subpath with file only
  const fileSub = entryRepo.listEntriesByRootId(
    r1, ListEntriesFilter("photos/a.jpg")
  );
  assert(fileSub.length == 1);
  assert(fileSub[0].name == "a.jpg");

  // Sorting by size descending
  const sortedSize = entryRepo.listEntriesByRootId(
    r1, ListEntriesFilter(null, EntryType.all, SortField.size)
  );
  assert(sortedSize[0].size >= sortedSize[$ - 1].size);

  // Duplicates within r1 with skipEmpty
  // zero1 and zero2 have sha256 = "0" (files)
  // empty_dir has sha256 = "0" (dir)
  // When typeFilter == EntryType.all, empty file and empty dir
  // must NOT collide!
  HashQueryFilter fZeroAll;
  fZeroAll.targets = [TargetSpec.parse("r1")];
  fZeroAll.typeFilter = EntryType.all;
  fZeroAll.skipEmpty = false;
  const dupsZeroAll = entryRepo.listDuplicates(fZeroAll);
  // zero1.txt and zero2.txt duplicate each other (2 file entries),
  // empty_dir is single (not duplicate)
  assert(dupsZeroAll.length == 2);
  assert(dupsZeroAll[0].sha256 == "0");
  assert(!dupsZeroAll[0].isDir);
  assert(!dupsZeroAll[1].isDir);

  // Verify groupDuplicates groups correctly
  const zeroGroups = entryRepo.groupDuplicates(dupsZeroAll);
  assert(zeroGroups.length == 1);
  assert(zeroGroups[0].entries.length == 2);
  assert(!zeroGroups[0].isDir);

  // Duplicates within r1 with skipEmpty: zero1 and zero2 are skipped
  HashQueryFilter fSkipZero;
  fSkipZero.targets = [TargetSpec.parse("r1")];
  fSkipZero.typeFilter = EntryType.file;
  fSkipZero.skipEmpty = true;
  const dupsSkipZero = entryRepo.listDuplicates(fSkipZero);
  assert(dupsSkipZero.length == 0);

  // Test hasCatalogedEntries
  assert(entryRepo.hasCatalogedEntries(r1));
  const rEmpty = rootRepo.addRoot("r_empty", "/mnt/empty");
  assert(!entryRepo.hasCatalogedEntries(rEmpty));
  Entry[] dotOnly = [
    Entry(0, rEmpty, "r_empty", ".", null, ".", true, 0, 1000, "0")
  ];
  entryRepo.saveSyncEntries(rEmpty, dotOnly, 4000);
  assert(!entryRepo.hasCatalogedEntries(rEmpty));

  // Test upsertEntriesBatch and remainingEntries saveSyncEntries
  const rBatch = rootRepo.addRoot("r_batch", "/mnt/batch");
  Entry[] batch1 = [
    Entry(0, rBatch, "r_batch", "f1.txt", ".", "f1.txt", false, 10, 1000, "h1"),
    Entry(0, rBatch, "r_batch", "f2.txt", ".", "f2.txt", false, 20, 1000, "h2")
  ];
  entryRepo.upsertEntriesBatch(rBatch, batch1);
  assert(entryRepo.getFileEntriesMap(rBatch).length == 2);

  Entry[] allBatch = batch1 ~ [
    Entry(0, rBatch, "r_batch", ".", null, ".", true, 0, 1000, "hdir")
  ];
  Entry[] remaining = [allBatch[$ - 1]];
  entryRepo.saveSyncEntries(rBatch, allBatch, remaining, 5000);
  assert(entryRepo.listEntriesByRootId(rBatch).length == 3);

  // Test free_space in RootRepository
  Root rCheck;
  assert(rootRepo.findByName("r_batch", rCheck));
  assert(!rCheck.hasFreeSpace);
  assert(rCheck.freeSpace == 0);

  rootRepo.updateLastSync(
    SyncSaveParams(rBatch, 6000, 1024 * 1024 * 50, true)
  );
  assert(rootRepo.findByName("r_batch", rCheck));
  assert(rCheck.hasFreeSpace);
  assert(rCheck.freeSpace == 1024 * 1024 * 50);

  entryRepo.saveSyncEntries(
    SyncSaveParams(rBatch, 7000, 1024 * 1024 * 80, true),
    allBatch
  );
  assert(rootRepo.findByName("r_batch", rCheck));
  assert(rCheck.hasFreeSpace);
  assert(rCheck.freeSpace == 1024 * 1024 * 80);

  const rootSummaries = rootRepo.listRoots();
  bool foundBatch = false;
  foreach (ref s; rootSummaries) {
    if (s.root.name == "r_batch") {
      foundBatch = true;
      assert(s.root.hasFreeSpace);
      assert(s.root.freeSpace == 1024 * 1024 * 80);
    }
  }
  assert(foundBatch);

  // Test pattern matching on roots
  const rMatches = rootRepo.findByPattern("r%");
  assert(rMatches.length >= 4);

  const r1Exact = rootRepo.findByPattern("r1");
  assert(r1Exact.length == 1);
  assert(r1Exact[0].name == "r1");

  const rPctId = rootRepo.addRoot("100%disk", "/mnt/pct");
  const rPctMatches = rootRepo.findByPattern("100\\%disk");
  assert(rPctMatches.length == 1);
  assert(rPctMatches[0].name == "100%disk");

  const noneMatches = rootRepo.findByPattern("nonexistent%");
  assert(noneMatches.length == 0);

  // Test listRoots with pattern
  const batchSummaries = rootRepo.listRoots("r_batch");
  assert(batchSummaries.length == 1);
  assert(batchSummaries[0].root.name == "r_batch");

  const noSummaries = rootRepo.listRoots("nonexistent%");
  assert(noSummaries.length == 0);

  // Test listEntriesByPattern
  const allEntriesAcrossRoots = entryRepo.listEntriesByPattern("%");
  assert(allEntriesAcrossRoots.length > 0);

  const jpgEntries = entryRepo.listEntriesByPattern(
    "r1", ListEntriesFilter("%.jpg")
  );
  assert(jpgEntries.length == 3);
  foreach (ref e; jpgEntries) {
    import std.algorithm.searching : endsWith;
    assert(e.relPath.endsWith(".jpg"));
  }

  // Test literal % in entry path
  Entry[] pctEntries = [
    Entry(
      0, rPctId, "100%disk", "100%free.txt", ".", "100%free.txt",
      false, 10, 1000, "hpct"
    )
  ];
  entryRepo.saveSyncEntries(rPctId, pctEntries, 8000);
  const foundPct = entryRepo.listEntriesByPattern(
    "100\\%disk", ListEntriesFilter("100\\%free.txt")
  );
  assert(foundPct.length == 1);
  assert(foundPct[0].name == "100%free.txt");

  // Test userPatternToLike
  assert(userPatternToLike("abc%def") == "abc%def");
  assert(userPatternToLike("abc\\%def") == "abc\\%def");
  assert(userPatternToLike("abc_def") == "abc\\_def");
  assert(userPatternToLike("abc\\\\%def") == "abc\\\\%def");

  // Test findByGlob on roots
  const globRoots = rootRepo.findByGlob("r*");
  assert(globRoots.length >= 3);

  const globR1R2 = rootRepo.findByGlob("r[12]");
  assert(globR1R2.length == 2);
  assert(globR1R2[0].name == "r1");
  assert(globR1R2[1].name == "r2");

  // SQLite GLOB is case-sensitive: "R*" should match no lowercase roots
  assert(rootRepo.findByGlob("R*").length == 0);

  // Test listEntriesByPattern with useGlob
  ListEntriesFilter fGlobJpg;
  fGlobJpg.subpath = "*.jpg";
  fGlobJpg.useGlob = true;
  const globJpgEntries = entryRepo.listEntriesByPattern("r1", fGlobJpg);
  assert(globJpgEntries.length == 3);

  ListEntriesFilter fGlobCase;
  fGlobCase.subpath = "*.JPG";
  fGlobCase.useGlob = true;
  assert(entryRepo.listEntriesByPattern("r1", fGlobCase).length == 0);

  // Subpath without wildcards in GLOB mode matches directory and subtree
  ListEntriesFilter fGlobSub;
  fGlobSub.subpath = "photos";
  fGlobSub.useGlob = true;
  const globSubEntries = entryRepo.listEntriesByPattern("r1", fGlobSub);
  assert(globSubEntries.length == 3);

  // Test listEntriesByPattern with hashPattern (LIKE operator)
  ListEntriesFilter fHashExact;
  fHashExact.hashPattern = "hA";
  const hAEntries = entryRepo.listEntriesByPattern("r1", fHashExact);
  assert(hAEntries.length == 1);
  assert(hAEntries[0].name == "a.jpg");

  ListEntriesFilter fHashZero;
  fHashZero.hashPattern = "0";
  const zeroEntries = entryRepo.listEntriesByPattern("r1", fHashZero);
  assert(zeroEntries.length == 3);

  ListEntriesFilter fHashLike;
  fHashLike.hashPattern = "h%";
  const hashLikeEntries = entryRepo.listEntriesByPattern("%", fHashLike);
  assert(hashLikeEntries.length >= 4); // hA, hB, hC, hash_dup

  // BUG-16: '_' in hash pattern is escaped to match literal '_'
  ListEntriesFilter fHashUnderscore;
  fHashUnderscore.hashPattern = "hash_dup";
  const hashUnderEntries = entryRepo.listEntriesByPattern(
    "%", fHashUnderscore
  );
  assert(hashUnderEntries.length == 1); // matches literal "hash_dup" in r2
  assert(hashUnderEntries[0].sha256 == "hash_dup");

  ListEntriesFilter fHashNoWildcard;
  fHashNoWildcard.hashPattern = "h_";
  assert(entryRepo.listEntriesByPattern("r1", fHashNoWildcard).length == 0);

  // Combine GLOB subpath and hash LIKE pattern
  ListEntriesFilter fGlobAndHash;
  fGlobAndHash.subpath = "photos/*.jpg";
  fGlobAndHash.useGlob = true;
  fGlobAndHash.hashPattern = "hA";
  const combined = entryRepo.listEntriesByPattern("r1", fGlobAndHash);
  assert(combined.length == 1);
  assert(combined[0].name == "a.jpg");

  // Test listDuplicates and listUnique with patterns across roots
  Entry[] r2Entries = [
    Entry(0, r2, "r2", ".", null, ".", true, 10, 1000, "dir2_hash"),
    Entry(0, r2, "r2", "copy_a.jpg", ".", "copy_a.jpg", false, 30, 1000, "hA")
  ];
  entryRepo.saveSyncEntries(r2, r2Entries, 9000);

  // Test listDuplicates with LIKE rootPattern (r1 and r2 match r%)
  HashQueryFilter fDupLike;
  fDupLike.targets = [TargetSpec.parse("r%")];
  fDupLike.skipEmpty = true;
  const dupLike = entryRepo.listDuplicates(fDupLike);
  assert(dupLike.length == 2);
  assert(dupLike[0].sha256 == "hA");
  assert(dupLike[1].sha256 == "hA");

  // Test listDuplicates with GLOB rootPattern
  HashQueryFilter fDupGlob;
  fDupGlob.targets = [TargetSpec.parse("r[12]", true)];
  fDupGlob.useGlob = true;
  fDupGlob.skipEmpty = true;
  const dupGlob = entryRepo.listDuplicates(fDupGlob);
  assert(dupGlob.length == 2);
  assert(dupGlob[0].sha256 == "hA");

  // In r1 alone, hA is unique (no duplicates in r1 with skipEmpty)
  HashQueryFilter fDupR1;
  fDupR1.targets = [TargetSpec.parse("r1")];
  fDupR1.skipEmpty = true;
  assert(entryRepo.listDuplicates(fDupR1).length == 0);

  // Test listDuplicates with subpath GLOB
  HashQueryFilter fDupSubGlob;
  fDupSubGlob.targets = [TargetSpec.parse("r1:/photos/*.jpg", true)];
  fDupSubGlob.useGlob = true;
  assert(entryRepo.listDuplicates(fDupSubGlob).length == 0);

  // Test listUnique with LIKE rootPattern
  HashQueryFilter fUniqLike;
  fUniqLike.targets = [TargetSpec.parse("r1:/photos")];
  fUniqLike.skipEmpty = true;
  const uniqPhotos = entryRepo.listUnique(fUniqLike);
  assert(uniqPhotos.length == 2); // a.jpg and b.jpg

  // Test listUnique with GLOB rootPattern and case-sensitivity
  HashQueryFilter fUniqCase;
  fUniqCase.targets = [TargetSpec.parse("R*", true)];
  fUniqCase.useGlob = true;
  assert(entryRepo.listUnique(fUniqCase).length == 0);

  // Test multiple targets in HashQueryFilter for listDuplicates and listUnique
  HashQueryFilter fMultiDup;
  fMultiDup.targets = [
    TargetSpec.parse("r1:/photos"),
    TargetSpec.parse("r2:/")
  ];
  fMultiDup.skipEmpty = true;
  const multiDups = entryRepo.listDuplicates(fMultiDup);
  assert(multiDups.length == 2); // r1:/photos/a.jpg and r2:/copy_a.jpg (hA)
  assert(multiDups[0].sha256 == "hA");
  assert(multiDups[1].sha256 == "hA");

  // Unique across r1:/photos and r2:/ is only r1:/photos/b.jpg (hB)
  const multiUniq = entryRepo.listUnique(fMultiDup);
  assert(multiUniq.length == 1);
  assert(multiUniq[0].name == "b.jpg");
  assert(multiUniq[0].sha256 == "hB");

  // Overlapping targets in HashQueryFilter do not duplicate a single row
  HashQueryFilter fOverlapDup;
  fOverlapDup.targets = [
    TargetSpec.parse("r1"),
    TargetSpec.parse("r1:/photos")
  ];
  fOverlapDup.skipEmpty = true;
  assert(entryRepo.listDuplicates(fOverlapDup).length == 0);

  // Test RootRepository validation with enforce
  import std.exception : assertThrown;
  assertThrown!Exception(rootRepo.addRoot("", "/mnt/test"));
  assertThrown!Exception(rootRepo.addRoot("r:colon", "/mnt/test"));
  assertThrown!Exception(rootRepo.addRoot("valid", ""));
  assertThrown!Exception(rootRepo.setPath("", "/mnt/test"));
  assertThrown!Exception(rootRepo.setPath("r1", ""));

  // Test stageEntriesBatch, clearStagedEntries, commitStagedSync
  const rStaging = rootRepo.addRoot("r_stage", "/mnt/stage");
  Entry[] stageBatch = [
    Entry(0, rStaging, "r_stage", "file1.txt", ".", "file1.txt",
      false, 100, 1000, "h_stage1"),
    Entry(0, rStaging, "r_stage", "file2.txt", ".", "file2.txt",
      false, 200, 1000, "h_stage2")
  ];
  entryRepo.stageEntriesBatch(rStaging, stageBatch);
  // Live entries table has 0 entries before commit
  assert(entryRepo.listEntriesByRootId(rStaging).length == 0);

  // Commit staged entries
  entryRepo.commitStagedSync(rStaging, 3000);
  assert(entryRepo.listEntriesByRootId(rStaging).length == 2);

  // Sync update with set-based stale deletion: stage only file2 and new file3
  Entry[] updateBatch = [
    Entry(0, rStaging, "r_stage", "file2.txt", ".", "file2.txt",
      false, 250, 1001, "h_stage2_v2"),
    Entry(0, rStaging, "r_stage", "file3.txt", ".", "file3.txt",
      false, 300, 1001, "h_stage3")
  ];
  entryRepo.stageEntriesBatch(rStaging, updateBatch);
  entryRepo.commitStagedSync(rStaging, 4000);

  // Verify file1 is deleted, file2 is updated, file3 is added
  const updatedList = entryRepo.listEntriesByRootId(rStaging);
  assert(updatedList.length == 2);
  assert(updatedList[0].relPath == "file2.txt" && updatedList[0].size == 250);
  assert(updatedList[1].relPath == "file3.txt" && updatedList[1].size == 300);
}
