module orglistremo.db.repo;

import d2sqlite3 : Database, Row, SqliteType, Statement;
import orglistremo.model :
  DuplicateGroup, Entry, EntryType, hasGlobWildcard, hasPatternWildcard, Root,
  RootSummary, SortField, unescapePatternEscapes;
import std.datetime.systime : Clock;

struct CachedFileEntry {
  ulong size;
  long mtime;
  string sha256;
}

struct ListEntriesFilter {
  string subpath;
  EntryType typeFilter = EntryType.all;
  SortField sort = SortField.path;
  bool useGlob = false;
  string hashPattern = null;
}

struct HashQueryFilter {
  bool hasRoot;
  long rootId;
  string subpath;
  EntryType typeFilter = EntryType.file;
  bool skipEmpty;
}

struct RootRepository {
  this(Database db) {
    this.db = db;
  }

  long addRoot(string name, string path) {
    assert(name.length > 0, "Root name cannot be empty");
    assert(path.length > 0, "Root path cannot be empty");

    const now = Clock.currTime.toUnixTime();
    auto stmt = db.prepare(`
      INSERT INTO roots (name, path, created_at)
      VALUES (?, ?, ?);
    `);
    stmt.bind(1, name);
    stmt.bind(2, path);
    stmt.bind(3, now);
    stmt.execute();
    return db.lastInsertRowid;
  }

  bool removeRoot(string name) {
    auto stmt = db.prepare("DELETE FROM roots WHERE name = ?;");
    stmt.bind(1, name);
    stmt.execute();
    return db.changes > 0;
  }

  bool setPath(string name, string newPath) {
    assert(newPath.length > 0, "New path cannot be empty");
    auto stmt = db.prepare("UPDATE roots SET path = ? WHERE name = ?;");
    stmt.bind(1, newPath);
    stmt.bind(2, name);
    stmt.execute();
    return db.changes > 0;
  }

  bool findByName(string name, out Root root) {
    import std.format : format;

    const freeCol = hasFreeSpaceColumn()
      ? "free_space"
      : "NULL AS free_space";
    auto stmt = db.prepare(format(`
      SELECT id, name, path, created_at, last_sync, %s
      FROM roots
      WHERE name = ?;
    `, freeCol));
    stmt.bind(1, name);
    auto results = stmt.execute();
    if (results.empty) {
      return false;
    }
    root = readRootRow(results.front);
    return true;
  }

  bool findById(long id, out Root root) {
    import std.format : format;

    const freeCol = hasFreeSpaceColumn()
      ? "free_space"
      : "NULL AS free_space";
    auto stmt = db.prepare(format(`
      SELECT id, name, path, created_at, last_sync, %s
      FROM roots
      WHERE id = ?;
    `, freeCol));
    stmt.bind(1, id);
    auto results = stmt.execute();
    if (results.empty) {
      return false;
    }
    root = readRootRow(results.front);
    return true;
  }

  void updateLastSync(
    long rootId,
    long timestamp,
    ulong freeSpace = 0,
    bool hasFreeSpace = false
  ) {
    if (hasFreeSpace) {
      auto stmt = db.prepare(
        "UPDATE roots SET last_sync = ?, free_space = ? WHERE id = ?;"
      );
      stmt.bind(1, timestamp);
      stmt.bind(2, freeSpace);
      stmt.bind(3, rootId);
      stmt.execute();
    } else {
      auto stmt = db.prepare(
        "UPDATE roots SET last_sync = ? WHERE id = ?;"
      );
      stmt.bind(1, timestamp);
      stmt.bind(2, rootId);
      stmt.execute();
    }
  }

  Root[] findByPattern(string pattern) {
    import std.format : format;

    const freeCol = hasFreeSpaceColumn()
      ? "free_space"
      : "NULL AS free_space";
    auto stmt = db.prepare(format(`
      SELECT id, name, path, created_at, last_sync, %s
      FROM roots
      WHERE name LIKE ? ESCAPE '\'
      ORDER BY name;
    `, freeCol));
    stmt.bind(1, escapeLikePattern(pattern));
    auto results = stmt.execute();
    Root[] roots;
    foreach (row; results) {
      roots ~= readRootRow(row);
    }
    return roots;
  }

  Root[] findByGlob(string pattern) {
    import std.format : format;

    const freeCol = hasFreeSpaceColumn()
      ? "free_space"
      : "NULL AS free_space";
    auto stmt = db.prepare(format(`
      SELECT id, name, path, created_at, last_sync, %s
      FROM roots
      WHERE name GLOB ?
      ORDER BY name;
    `, freeCol));
    stmt.bind(1, pattern);
    auto results = stmt.execute();
    Root[] roots;
    foreach (row; results) {
      roots ~= readRootRow(row);
    }
    return roots;
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

    auto stmt = db.prepare(sql);
    if (pattern.length > 0) {
      stmt.bind(1, escapeLikePattern(pattern));
    }
    RootSummary[] summaries;
    auto results = stmt.execute();
    foreach (row; results) {
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
  Database db;

  bool hasFreeSpaceColumn() {
    auto stmt = db.prepare("PRAGMA table_info(roots);");
    foreach (row; stmt.execute()) {
      if (row.peek!string(1) == "free_space") {
        return true;
      }
    }
    return false;
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
    if (row.length > 5 && row[5].type != SqliteType.NULL) {
      r.freeSpace = row[5].as!ulong;
      r.hasFreeSpace = true;
    } else {
      r.freeSpace = 0;
      r.hasFreeSpace = false;
    }
    return r;
  }
}

struct EntryRepository {
  this(Database db) {
    this.db = db;
  }

  CachedFileEntry[string] getFileEntriesMap(long rootId) {
    CachedFileEntry[string] cache;
    auto stmt = db.prepare(`
      SELECT rel_path, size, mtime, sha256
      FROM entries
      WHERE root_id = ? AND is_dir = 0;
    `);
    stmt.bind(1, rootId);
    auto results = stmt.execute();
    foreach (row; results) {
      const relPath = row.peek!string(0);
      const size = row.peek!ulong(1);
      const mtime = row.peek!long(2);
      const sha256 = row.peek!string(3);
      cache[relPath] = CachedFileEntry(size, mtime, sha256);
    }
    return cache;
  }

  bool hasCatalogedEntries(long rootId) {
    auto stmt = db.prepare(`
      SELECT 1 FROM entries
      WHERE root_id = ? AND rel_path != '.'
      LIMIT 1;
    `);
    stmt.bind(1, rootId);
    return !stmt.execute().empty;
  }

  void upsertEntriesBatch(long rootId, in Entry[] batch) {
    if (batch.length == 0) {
      return;
    }
    db.execute("BEGIN IMMEDIATE;");
    scope (failure) {
      db.execute("ROLLBACK;");
    }
    upsertEntries(rootId, batch);
    db.execute("COMMIT;");
  }

  void saveSyncEntries(
    long rootId,
    in Entry[] allEntries,
    long syncTimestamp,
    ulong freeSpace = 0,
    bool hasFreeSpace = false
  ) {
    saveSyncEntries(
      rootId, allEntries, allEntries, syncTimestamp, freeSpace, hasFreeSpace
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
    db.execute("BEGIN IMMEDIATE;");
    scope (failure) {
      db.execute("ROLLBACK;");
    }

    deleteStaleEntries(rootId, allEntries);
    if (remainingEntries.length > 0) {
      upsertEntries(rootId, remainingEntries);
    }

    if (hasFreeSpace) {
      auto syncStmt = db.prepare(`
        UPDATE roots SET last_sync = ?, free_space = ? WHERE id = ?;
      `);
      syncStmt.bind(1, syncTimestamp);
      syncStmt.bind(2, freeSpace);
      syncStmt.bind(3, rootId);
      syncStmt.execute();
    } else {
      auto syncStmt = db.prepare(`
        UPDATE roots SET last_sync = ? WHERE id = ?;
      `);
      syncStmt.bind(1, syncTimestamp);
      syncStmt.bind(2, rootId);
      syncStmt.execute();
    }

    db.execute("COMMIT;");
  }

  Entry[] listEntries(
    long rootId,
    in ListEntriesFilter filter = ListEntriesFilter.init
  ) {
    string sql = `
      SELECT
        e.id, e.root_id, r.name, e.rel_path, e.parent_path,
        e.name, e.is_dir, e.size, e.mtime, e.sha256
      FROM entries e
      JOIN roots r ON r.id = e.root_id
      WHERE e.root_id = ?
    `;

    if (filter.typeFilter == EntryType.file) {
      sql ~= " AND e.is_dir = 0";
    } else if (filter.typeFilter == EntryType.dir) {
      sql ~= " AND e.is_dir = 1";
    }

    const hasSubpath = filter.subpath.length > 0;
    const isSubpathPattern = hasSubpath && (
      filter.useGlob
        ? hasGlobWildcard(filter.subpath)
        : hasPatternWildcard(filter.subpath)
    );
    if (hasSubpath) {
      if (filter.useGlob) {
        if (isSubpathPattern) {
          sql ~= " AND e.rel_path GLOB ?";
        } else {
          sql ~= " AND (e.rel_path = ? OR e.rel_path GLOB ?)";
        }
      } else {
        if (isSubpathPattern) {
          sql ~= " AND e.rel_path LIKE ? ESCAPE '\\'";
        } else {
          sql ~= " AND (e.rel_path = ? OR e.rel_path LIKE ? ESCAPE '\\')";
        }
      }
    }

    if (filter.hashPattern.length > 0) {
      sql ~= " AND e.sha256 LIKE ? ESCAPE '\\'";
    }

    switch (filter.sort) {
      case SortField.size:
        sql ~= " ORDER BY e.size DESC, e.rel_path ASC";
        break;
      case SortField.mtime:
        sql ~= " ORDER BY e.mtime DESC, e.rel_path ASC";
        break;
      case SortField.path:
      default:
        sql ~= " ORDER BY e.rel_path ASC";
        break;
    }

    auto stmt = db.prepare(sql);
    int paramIdx = 1;
    stmt.bind(paramIdx++, rootId);
    if (hasSubpath) {
      if (filter.useGlob) {
        if (isSubpathPattern) {
          stmt.bind(paramIdx++, filter.subpath);
        } else {
          stmt.bind(paramIdx++, filter.subpath);
          stmt.bind(paramIdx++, filter.subpath ~ "/*");
        }
      } else {
        if (isSubpathPattern) {
          stmt.bind(paramIdx++, escapeLikePattern(filter.subpath));
        } else {
          const unescaped = unescapePatternEscapes(filter.subpath);
          stmt.bind(paramIdx++, unescaped);
          stmt.bind(paramIdx++, escapeLike(unescaped) ~ "/%");
        }
      }
    }
    if (filter.hashPattern.length > 0) {
      stmt.bind(paramIdx++, filter.hashPattern);
    }

    return readEntries(stmt);
  }

  Entry[] listEntries(
    string rootPattern,
    in ListEntriesFilter filter = ListEntriesFilter.init
  ) {
    string sql = `
      SELECT
        e.id, e.root_id, r.name, e.rel_path, e.parent_path,
        e.name, e.is_dir, e.size, e.mtime, e.sha256
      FROM entries e
      JOIN roots r ON r.id = e.root_id
    `;

    if (filter.useGlob) {
      sql ~= " WHERE r.name GLOB ?";
    } else {
      sql ~= " WHERE r.name LIKE ? ESCAPE '\\'";
    }

    if (filter.typeFilter == EntryType.file) {
      sql ~= " AND e.is_dir = 0";
    } else if (filter.typeFilter == EntryType.dir) {
      sql ~= " AND e.is_dir = 1";
    }

    const hasSubpath = filter.subpath.length > 0;
    const isSubpathPattern = hasSubpath && (
      filter.useGlob
        ? hasGlobWildcard(filter.subpath)
        : hasPatternWildcard(filter.subpath)
    );
    if (hasSubpath) {
      if (filter.useGlob) {
        if (isSubpathPattern) {
          sql ~= " AND e.rel_path GLOB ?";
        } else {
          sql ~= " AND (e.rel_path = ? OR e.rel_path GLOB ?)";
        }
      } else {
        if (isSubpathPattern) {
          sql ~= " AND e.rel_path LIKE ? ESCAPE '\\'";
        } else {
          sql ~= " AND (e.rel_path = ? OR e.rel_path LIKE ? ESCAPE '\\')";
        }
      }
    }

    if (filter.hashPattern.length > 0) {
      sql ~= " AND e.sha256 LIKE ? ESCAPE '\\'";
    }

    switch (filter.sort) {
      case SortField.size:
        sql ~= " ORDER BY e.size DESC, r.name ASC, e.rel_path ASC";
        break;
      case SortField.mtime:
        sql ~= " ORDER BY e.mtime DESC, r.name ASC, e.rel_path ASC";
        break;
      case SortField.path:
      default:
        sql ~= " ORDER BY r.name ASC, e.rel_path ASC";
        break;
    }

    auto stmt = db.prepare(sql);
    int paramIdx = 1;
    if (filter.useGlob) {
      stmt.bind(paramIdx++, rootPattern);
    } else {
      stmt.bind(paramIdx++, escapeLikePattern(rootPattern));
    }
    if (hasSubpath) {
      if (filter.useGlob) {
        if (isSubpathPattern) {
          stmt.bind(paramIdx++, filter.subpath);
        } else {
          stmt.bind(paramIdx++, filter.subpath);
          stmt.bind(paramIdx++, filter.subpath ~ "/*");
        }
      } else {
        if (isSubpathPattern) {
          stmt.bind(paramIdx++, escapeLikePattern(filter.subpath));
        } else {
          const unescaped = unescapePatternEscapes(filter.subpath);
          stmt.bind(paramIdx++, unescaped);
          stmt.bind(paramIdx++, escapeLike(unescaped) ~ "/%");
        }
      }
    }
    if (filter.hashPattern.length > 0) {
      stmt.bind(paramIdx++, filter.hashPattern);
    }

    return readEntries(stmt);
  }

  Entry[] listDuplicates(in HashQueryFilter filter = HashQueryFilter.init) {
    return queryGroupedEntries(filter, "COUNT(*) > 1");
  }

  Entry[] listUnique(in HashQueryFilter filter = HashQueryFilter.init) {
    return queryGroupedEntries(filter, "COUNT(*) = 1");
  }

  DuplicateGroup[] groupDuplicates(in Entry[] entries) {
    DuplicateGroup[] groups;
    if (entries.length == 0) {
      return groups;
    }

    DuplicateGroup currentGroup;
    currentGroup.sha256 = entries[0].sha256;
    currentGroup.size = entries[0].size;
    currentGroup.isDir = entries[0].isDir;
    currentGroup.entries ~= entries[0];

    foreach (i; 1 .. entries.length) {
      if (entries[i].sha256 == currentGroup.sha256 &&
          entries[i].isDir == currentGroup.isDir) {
        currentGroup.entries ~= entries[i];
      } else {
        groups ~= currentGroup;
        currentGroup = DuplicateGroup();
        currentGroup.sha256 = entries[i].sha256;
        currentGroup.size = entries[i].size;
        currentGroup.isDir = entries[i].isDir;
        currentGroup.entries ~= entries[i];
      }
    }
    groups ~= currentGroup;
    return groups;
  }

private:
  Database db;

  void deleteStaleEntries(long rootId, in Entry[] newEntries) {
    bool[string] newPaths;
    foreach (ref e; newEntries) {
      newPaths[e.relPath] = true;
    }

    auto existingStmt = db.prepare(`
      SELECT rel_path FROM entries WHERE root_id = ?;
    `);
    existingStmt.bind(1, rootId);
    string[] stalePaths;
    foreach (row; existingStmt.execute()) {
      const path = row.peek!string(0);
      if (path !in newPaths) {
        stalePaths ~= path;
      }
    }

    if (stalePaths.length > 0) {
      auto delStmt = db.prepare(`
        DELETE FROM entries WHERE root_id = ? AND rel_path = ?;
      `);
      foreach (path; stalePaths) {
        delStmt.reset();
        delStmt.bind(1, rootId);
        delStmt.bind(2, path);
        delStmt.execute();
      }
    }
  }

  void upsertEntries(long rootId, in Entry[] newEntries) {
    auto upsertStmt = db.prepare(`
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

    foreach (ref e; newEntries) {
      upsertStmt.reset();
      upsertStmt.bind(1, rootId);
      upsertStmt.bind(2, e.relPath);
      if (e.parentPath is null || e.parentPath.length == 0) {
        upsertStmt.bind(3, null);
      } else {
        upsertStmt.bind(3, e.parentPath);
      }
      upsertStmt.bind(4, e.name);
      upsertStmt.bind(5, e.isDir ? 1 : 0);
      upsertStmt.bind(6, e.size);
      upsertStmt.bind(7, e.mtime);
      upsertStmt.bind(8, e.sha256);
      upsertStmt.execute();
    }
  }

  Entry[] queryGroupedEntries(
    in HashQueryFilter filter,
    string havingClause
  ) {
    const outerFilters = buildFilterSql(filter, "e.");
    const innerFilters = buildFilterSql(filter, "");

    const sql = "SELECT " ~
      "e.id, e.root_id, r.name, e.rel_path, e.parent_path, " ~
      "e.name, e.is_dir, e.size, e.mtime, e.sha256 " ~
      "FROM entries e " ~
      "JOIN roots r ON r.id = e.root_id " ~
      "WHERE " ~ outerFilters ~
      " AND (e.is_dir, e.sha256) IN (" ~
        "SELECT is_dir, sha256 FROM entries " ~
        "WHERE " ~ innerFilters ~ " " ~
        "GROUP BY is_dir, sha256 " ~
        "HAVING " ~ havingClause ~
      ") " ~
      "ORDER BY e.size DESC, e.is_dir, e.sha256, r.name, e.rel_path ASC";

    auto stmt = db.prepare(sql);
    bindDuplicateOrUniqueParams(stmt, filter);
    return readEntries(stmt);
  }

  static string buildFilterSql(in HashQueryFilter filter, string prefix) {
    string s = prefix ~ "rel_path != '.'";
    if (filter.typeFilter == EntryType.file) {
      s ~= " AND " ~ prefix ~ "is_dir = 0";
    } else if (filter.typeFilter == EntryType.dir) {
      s ~= " AND " ~ prefix ~ "is_dir = 1";
    }

    if (filter.skipEmpty) {
      s ~= " AND " ~ prefix ~ "size > 0 AND " ~ prefix ~ "sha256 != '0'";
    }

    if (filter.hasRoot) {
      s ~= " AND " ~ prefix ~ "root_id = ?";
      if (filter.subpath.length > 0) {
        s ~= " AND (" ~ prefix ~ "rel_path = ? OR " ~
          prefix ~ "rel_path LIKE ? ESCAPE '\\')";
      }
    }
    return s;
  }

  static void bindDuplicateOrUniqueParams(
    ref Statement stmt,
    in HashQueryFilter filter
  ) {
    if (!filter.hasRoot) {
      return;
    }
    int idx = 1;
    stmt.bind(idx++, filter.rootId);
    if (filter.subpath.length > 0) {
      stmt.bind(idx++, filter.subpath);
      stmt.bind(idx++, escapeLike(filter.subpath) ~ "/%");
    }
    stmt.bind(idx++, filter.rootId);
    if (filter.subpath.length > 0) {
      stmt.bind(idx++, filter.subpath);
      stmt.bind(idx++, escapeLike(filter.subpath) ~ "/%");
    }
  }

  static Entry[] readEntries(ref Statement stmt) {
    Entry[] entries;
    auto results = stmt.execute();
    foreach (row; results) {
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
}

string escapeLikePattern(string s) {
  string res;
  size_t i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c == '\\') {
      if (i + 1 < s.length && s[i + 1] == '%') {
        res ~= "\\%";
        i += 2;
        continue;
      }
      if (i + 1 < s.length && s[i + 1] == '\\') {
        res ~= "\\\\";
        i += 2;
        continue;
      }
      res ~= "\\\\";
      i++;
    } else if (c == '_') {
      res ~= "\\_";
      i++;
    } else {
      res ~= c;
      i++;
    }
  }
  return res;
}

string escapeLike(string s) {
  string res;
  foreach (c; s) {
    if (c == '%' || c == '_' || c == '\\') {
      res ~= '\\';
    }
    res ~= c;
  }
  return res;
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

  // Test listEntries
  const list = entryRepo.listEntries(
    r1, ListEntriesFilter(null, EntryType.all)
  );
  assert(list.length == 4);

  // Test duplicates within r1 (none)
  HashQueryFilter fR1;
  fR1.hasRoot = true;
  fR1.rootId = r1;
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
  const subList = entryRepo.listEntries(r1, ListEntriesFilter("photos"));
  assert(subList.length == 3);

  // Subpath with file only
  const fileSub = entryRepo.listEntries(r1, ListEntriesFilter("photos/a.jpg"));
  assert(fileSub.length == 1);
  assert(fileSub[0].name == "a.jpg");

  // Sorting by size descending
  const sortedSize = entryRepo.listEntries(
    r1, ListEntriesFilter(null, EntryType.all, SortField.size)
  );
  assert(sortedSize[0].size >= sortedSize[$ - 1].size);

  // Duplicates within r1 with skipEmpty
  // zero1 and zero2 have sha256 = "0" (files)
  // empty_dir has sha256 = "0" (dir)
  // When typeFilter == EntryType.all, empty file and empty dir
  // must NOT collide!
  HashQueryFilter fZeroAll;
  fZeroAll.hasRoot = true;
  fZeroAll.rootId = r1;
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
  fSkipZero.hasRoot = true;
  fSkipZero.rootId = r1;
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
  assert(entryRepo.listEntries(rBatch).length == 3);

  // Test free_space in RootRepository
  Root rCheck;
  assert(rootRepo.findByName("r_batch", rCheck));
  assert(!rCheck.hasFreeSpace);
  assert(rCheck.freeSpace == 0);

  rootRepo.updateLastSync(rBatch, 6000, 1024 * 1024 * 50, true);
  assert(rootRepo.findByName("r_batch", rCheck));
  assert(rCheck.hasFreeSpace);
  assert(rCheck.freeSpace == 1024 * 1024 * 50);

  entryRepo.saveSyncEntries(
    rBatch, allBatch, 7000, 1024 * 1024 * 80, true
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

  // Test listEntries by rootPattern
  const allEntriesAcrossRoots = entryRepo.listEntries("%");
  assert(allEntriesAcrossRoots.length > 0);

  const jpgEntries = entryRepo.listEntries(
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
  const foundPct = entryRepo.listEntries(
    "100\\%disk", ListEntriesFilter("100\\%free.txt")
  );
  assert(foundPct.length == 1);
  assert(foundPct[0].name == "100%free.txt");

  // Test escapeLikePattern
  assert(escapeLikePattern("abc%def") == "abc%def");
  assert(escapeLikePattern("abc\\%def") == "abc\\%def");
  assert(escapeLikePattern("abc_def") == "abc\\_def");
  assert(escapeLikePattern("abc\\\\%def") == "abc\\\\%def");

  // Test findByGlob on roots
  const globRoots = rootRepo.findByGlob("r*");
  assert(globRoots.length >= 3);

  const globR1R2 = rootRepo.findByGlob("r[12]");
  assert(globR1R2.length == 2);
  assert(globR1R2[0].name == "r1");
  assert(globR1R2[1].name == "r2");

  // SQLite GLOB is case-sensitive: "R*" should match no lowercase roots
  assert(rootRepo.findByGlob("R*").length == 0);

  // Test listEntries with useGlob
  ListEntriesFilter fGlobJpg;
  fGlobJpg.subpath = "*.jpg";
  fGlobJpg.useGlob = true;
  const globJpgEntries = entryRepo.listEntries("r1", fGlobJpg);
  assert(globJpgEntries.length == 3);

  ListEntriesFilter fGlobCase;
  fGlobCase.subpath = "*.JPG";
  fGlobCase.useGlob = true;
  assert(entryRepo.listEntries("r1", fGlobCase).length == 0);

  // Subpath without wildcards in GLOB mode matches directory and subtree
  ListEntriesFilter fGlobSub;
  fGlobSub.subpath = "photos";
  fGlobSub.useGlob = true;
  const globSubEntries = entryRepo.listEntries("r1", fGlobSub);
  assert(globSubEntries.length == 3);

  // Test listEntries with hashPattern (LIKE operator)
  ListEntriesFilter fHashExact;
  fHashExact.hashPattern = "hA";
  const hAEntries = entryRepo.listEntries("r1", fHashExact);
  assert(hAEntries.length == 1);
  assert(hAEntries[0].name == "a.jpg");

  ListEntriesFilter fHashZero;
  fHashZero.hashPattern = "0";
  const zeroEntries = entryRepo.listEntries("r1", fHashZero);
  assert(zeroEntries.length == 3);

  ListEntriesFilter fHashLike;
  fHashLike.hashPattern = "h%";
  const hashLikeEntries = entryRepo.listEntries("%", fHashLike);
  assert(hashLikeEntries.length >= 4); // hA, hB, hC, hash_dup

  // Single-character wildcard '_' in hash LIKE pattern
  ListEntriesFilter fHashUnderscore;
  fHashUnderscore.hashPattern = "h_";
  const hashUnderEntries = entryRepo.listEntries("r1", fHashUnderscore);
  assert(hashUnderEntries.length == 3); // hA, hB, hC

  // Combine GLOB subpath and hash LIKE pattern
  ListEntriesFilter fGlobAndHash;
  fGlobAndHash.subpath = "photos/*.jpg";
  fGlobAndHash.useGlob = true;
  fGlobAndHash.hashPattern = "hA";
  const combined = entryRepo.listEntries("r1", fGlobAndHash);
  assert(combined.length == 1);
  assert(combined[0].name == "a.jpg");
}
