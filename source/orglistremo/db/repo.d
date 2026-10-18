module orglistremo.db.repo;

import d2sqlite3 : Database, Row, SqliteType, Statement;
import orglistremo.model :
  DuplicateGroup, Entry, EntryType, Root, RootSummary, SortField;
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
    auto stmt = db.prepare(`
      SELECT id, name, path, created_at, last_sync
      FROM roots
      WHERE name = ?;
    `);
    stmt.bind(1, name);
    auto results = stmt.execute();
    if (results.empty) {
      return false;
    }
    root = readRootRow(results.front);
    return true;
  }

  bool findById(long id, out Root root) {
    auto stmt = db.prepare(`
      SELECT id, name, path, created_at, last_sync
      FROM roots
      WHERE id = ?;
    `);
    stmt.bind(1, id);
    auto results = stmt.execute();
    if (results.empty) {
      return false;
    }
    root = readRootRow(results.front);
    return true;
  }

  void updateLastSync(long rootId, long timestamp) {
    auto stmt = db.prepare("UPDATE roots SET last_sync = ? WHERE id = ?;");
    stmt.bind(1, timestamp);
    stmt.bind(2, rootId);
    stmt.execute();
  }

  RootSummary[] listRoots() {
    RootSummary[] summaries;
    auto stmt = db.prepare(`
      SELECT
        r.id, r.name, r.path, r.created_at, r.last_sync,
        COALESCE(SUM(CASE WHEN e.is_dir = 0 THEN 1 ELSE 0 END), 0)
          AS file_count,
        COALESCE(SUM(
          CASE WHEN e.is_dir = 1 AND e.rel_path != '.' THEN 1 ELSE 0 END
        ), 0) AS dir_count,
        COALESCE(SUM(CASE WHEN e.is_dir = 0 THEN e.size ELSE 0 END), 0)
          AS total_size
      FROM roots r
      LEFT JOIN entries e ON e.root_id = r.id
      GROUP BY r.id
      ORDER BY r.name;
    `);
    auto results = stmt.execute();
    foreach (row; results) {
      RootSummary summary;
      summary.root = readRootRow(row);
      summary.fileCount = row.peek!ulong(5);
      summary.dirCount = row.peek!ulong(6);
      summary.totalSize = row.peek!ulong(7);
      summaries ~= summary;
    }
    return summaries;
  }

private:
  Database db;

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

  void saveSyncEntries(
    long rootId,
    in Entry[] newEntries,
    long syncTimestamp
  ) {
    db.execute("BEGIN IMMEDIATE;");
    scope (failure) {
      db.execute("ROLLBACK;");
    }

    deleteStaleEntries(rootId, newEntries);
    upsertEntries(rootId, newEntries);

    auto syncStmt = db.prepare(`
      UPDATE roots SET last_sync = ? WHERE id = ?;
    `);
    syncStmt.bind(1, syncTimestamp);
    syncStmt.bind(2, rootId);
    syncStmt.execute();

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
    if (hasSubpath) {
      sql ~= " AND (e.rel_path = ? OR e.rel_path LIKE ? ESCAPE '\\')";
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
      stmt.bind(paramIdx++, filter.subpath);
      stmt.bind(paramIdx++, escapeLike(filter.subpath) ~ "/%");
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

  static string escapeLike(string s) {
    string res;
    foreach (c; s) {
      if (c == '%' || c == '_' || c == '\\') {
        res ~= '\\';
      }
      res ~= c;
    }
    return res;
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
}
