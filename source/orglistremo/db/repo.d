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

  void saveSyncEntries(long rootId, Entry[] newEntries, long syncTimestamp) {
    db.execute("BEGIN IMMEDIATE;");
    scope (failure) {
      db.execute("ROLLBACK;");
    }

    // Collect all existing relative paths to identify deletions
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

    // Delete stale entries
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

    // Upsert new entries
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

    // Update root's last_sync timestamp
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
    string subpath = null,
    EntryType typeFilter = EntryType.all,
    SortField sort = SortField.path
  ) {
    import std.format : format;

    string sql = `
      SELECT
        e.id, e.root_id, r.name, e.rel_path, e.parent_path,
        e.name, e.is_dir, e.size, e.mtime, e.sha256
      FROM entries e
      JOIN roots r ON r.id = e.root_id
      WHERE e.root_id = ?
    `;

    if (typeFilter == EntryType.file) {
      sql ~= " AND e.is_dir = 0";
    } else if (typeFilter == EntryType.dir) {
      sql ~= " AND e.is_dir = 1";
    }

    const hasSubpath = subpath.length > 0;
    if (hasSubpath) {
      sql ~= " AND (e.rel_path = ? OR e.rel_path LIKE ? ESCAPE '\\')";
    }

    switch (sort) {
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
      stmt.bind(paramIdx++, subpath);
      stmt.bind(paramIdx++, escapeLike(subpath) ~ "/%");
    }

    return readEntries(stmt);
  }

  Entry[] listDuplicates(
    bool hasRoot,
    long rootId,
    string subpath = null,
    EntryType typeFilter = EntryType.file,
    bool skipEmpty = false
  ) {
    string sql = `
      SELECT
        e.id, e.root_id, r.name, e.rel_path, e.parent_path,
        e.name, e.is_dir, e.size, e.mtime, e.sha256
      FROM entries e
      JOIN roots r ON r.id = e.root_id
      WHERE 1=1
    `;

    string innerSql = `
      SELECT sha256 FROM entries WHERE 1=1
    `;

    string filters = "";
    if (typeFilter == EntryType.file) {
      filters ~= " AND is_dir = 0";
    } else if (typeFilter == EntryType.dir) {
      filters ~= " AND is_dir = 1";
    }

    if (skipEmpty) {
      filters ~= " AND size > 0 AND sha256 != '0'";
    }

    if (hasRoot) {
      filters ~= " AND root_id = ?";
      if (subpath.length > 0) {
        filters ~= " AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\\')";
      }
    }

    sql ~= replacePrefix(filters, "e.");
    innerSql ~= filters ~ " GROUP BY sha256 HAVING COUNT(*) > 1";
    sql ~= " AND e.sha256 IN (" ~ innerSql ~ ") ";
    sql ~= " ORDER BY e.size DESC, e.sha256, r.name, e.rel_path ASC";

    auto stmt = db.prepare(sql);
    bindDuplicateOrUniqueParams(stmt, hasRoot, rootId, subpath);
    return readEntries(stmt);
  }

  Entry[] listUnique(
    bool hasRoot,
    long rootId,
    string subpath = null,
    EntryType typeFilter = EntryType.file,
    bool skipEmpty = false
  ) {
    string sql = `
      SELECT
        e.id, e.root_id, r.name, e.rel_path, e.parent_path,
        e.name, e.is_dir, e.size, e.mtime, e.sha256
      FROM entries e
      JOIN roots r ON r.id = e.root_id
      WHERE 1=1
    `;

    string innerSql = `
      SELECT sha256 FROM entries WHERE 1=1
    `;

    string filters = "";
    if (typeFilter == EntryType.file) {
      filters ~= " AND is_dir = 0";
    } else if (typeFilter == EntryType.dir) {
      filters ~= " AND is_dir = 1";
    }

    if (skipEmpty) {
      filters ~= " AND size > 0 AND sha256 != '0'";
    }

    if (hasRoot) {
      filters ~= " AND root_id = ?";
      if (subpath.length > 0) {
        filters ~= " AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\\')";
      }
    }

    sql ~= replacePrefix(filters, "e.");
    innerSql ~= filters ~ " GROUP BY sha256 HAVING COUNT(*) = 1";
    sql ~= " AND e.sha256 IN (" ~ innerSql ~ ") ";
    sql ~= " ORDER BY e.size DESC, e.sha256, r.name, e.rel_path ASC";

    auto stmt = db.prepare(sql);
    bindDuplicateOrUniqueParams(stmt, hasRoot, rootId, subpath);
    return readEntries(stmt);
  }

  DuplicateGroup[] groupDuplicates(Entry[] entries) {
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
      if (entries[i].sha256 == currentGroup.sha256) {
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

  static void bindDuplicateOrUniqueParams(
    ref Statement stmt,
    bool hasRoot,
    long rootId,
    string subpath
  ) {
    if (!hasRoot) {
      return;
    }
    int idx = 1;
    // Outer query parameters
    stmt.bind(idx++, rootId);
    if (subpath.length > 0) {
      stmt.bind(idx++, subpath);
      stmt.bind(idx++, escapeLike(subpath) ~ "/%");
    }
    // Subquery parameters
    stmt.bind(idx++, rootId);
    if (subpath.length > 0) {
      stmt.bind(idx++, subpath);
      stmt.bind(idx++, escapeLike(subpath) ~ "/%");
    }
  }

  static string replacePrefix(string sql, string prefix) {
    import std.array : replace;
    return sql
      .replace("is_dir", prefix ~ "is_dir")
      .replace("size", prefix ~ "size")
      .replace("sha256", prefix ~ "sha256")
      .replace("root_id", prefix ~ "root_id")
      .replace("rel_path", prefix ~ "rel_path");
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

  auto db = openDatabase(":memory:");
  auto rootRepo = RootRepository(db);
  auto entryRepo = EntryRepository(db);

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
  auto cache = entryRepo.getFileEntriesMap(r1);
  assert("f1.txt" in cache);
  assert(cache["f1.txt"].size == 60);
  assert(cache["f1.txt"].sha256 == "hash1");

  // Test listEntries
  auto list = entryRepo.listEntries(r1, null, EntryType.all);
  assert(list.length == 4);

  // Test duplicates within r1 (none)
  auto dupsR1 = entryRepo.listDuplicates(true, r1);
  assert(dupsR1.length == 0);

  // Test duplicates across all roots (hash_dup present in r1 and r2)
  auto dupsAll = entryRepo.listDuplicates(false, 0);
  assert(dupsAll.length == 2);
  assert(dupsAll[0].sha256 == "hash_dup");

  auto groups = entryRepo.groupDuplicates(dupsAll);
  assert(groups.length == 1);
  assert(groups[0].entries.length == 2);

  // Test unique across all roots (f1.txt, f2.txt)
  auto uniques = entryRepo.listUnique(false, 0);
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
    Entry(0, r1, "r1", "zero2.txt", ".", "zero2.txt", false, 0, 1000, "0")
  ];
  entryRepo.saveSyncEntries(r1, subtreeEntries, 3000);

  // Subpath "photos" should only return photos, photos/a.jpg, photos/b.jpg
  auto subList = entryRepo.listEntries(r1, "photos");
  assert(subList.length == 3);

  // Subpath with file only
  auto fileSub = entryRepo.listEntries(r1, "photos/a.jpg");
  assert(fileSub.length == 1);
  assert(fileSub[0].name == "a.jpg");

  // Sorting by size descending
  auto sortedSize = entryRepo.listEntries(
    r1, null, EntryType.all, SortField.size
  );
  assert(sortedSize[0].size >= sortedSize[$ - 1].size);

  // Duplicates within r1 with skipEmpty
  // zero1 and zero2 have sha256 = "0"
  auto dupsWithZero = entryRepo.listDuplicates(
    true, r1, null, EntryType.file, false
  );
  assert(dupsWithZero.length == 2);
  assert(dupsWithZero[0].sha256 == "0");

  auto dupsSkipZero = entryRepo.listDuplicates(
    true, r1, null, EntryType.file, true
  );
  assert(dupsSkipZero.length == 0);
}
