module orglistremo.internal.testutil;

version (unittest):

package(orglistremo):

import d2sqlite3 : Database, Statement;
import std.stdio : File;

struct TempDir {
  static TempDir create(string tag = "test") {
    return TempDir(tag);
  }

  this(string tag) {
    import core.atomic : atomicOp;
    import std.file : exists, mkdirRecurse, tempDir;
    import std.format : format;
    import std.path : buildPath;
    import std.process : thisProcessID;

    const uint seq = atomicOp!"+="(s_counter, 1);
    this.path = buildPath(
      tempDir(),
      format("listremo_test_%d_%d_%s", thisProcessID, seq, tag)
    );

    if (exists(this.path)) {
      cleanupPath(this.path);
    }
    mkdirRecurse(this.path);
  }

  ~this() {
    close();
  }

  void close() {
    if (this.path.length == 0) {
      return;
    }
    cleanupPath(this.path);
    this.path = null;
  }

  string subPath(string rel) const {
    import std.path : buildPath;
    return buildPath(this.path, rel);
  }

  @disable this(this);

  string path;
  alias path this;

private:
  static void cleanupPath(string p) {
    import std.file : exists, rmdirRecurse;
    if (!exists(p)) {
      return;
    }
    version (Posix) {
      import std.process : execute;
      try {
        execute(["chmod", "-R", "u+rwx", p]);
      } catch (Exception) {
      }
    }
    try {
      rmdirRecurse(p);
    } catch (Exception) {
    }
  }

  static shared uint s_counter;
}

struct LegacyV0Options {
  string rootName = "legacy_root";
  string rootPath = "/mnt/legacy";
  long createdAt = 1600000000;
}

void createLegacyV0Db(
  string dbPath,
  in LegacyV0Options options = LegacyV0Options.init
) {
  Database db = Database(dbPath);
  createLegacyV0Db(db, options);
  db.close();
}

void createLegacyV0Db(
  ref Database db,
  in LegacyV0Options options = LegacyV0Options.init
) {
  db.execute(`
    CREATE TABLE roots (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL UNIQUE,
      path        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      last_sync   INTEGER
    );
  `);
  db.execute(`
    CREATE TABLE entries (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      root_id     INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
      rel_path    TEXT NOT NULL,
      parent_path TEXT,
      name        TEXT NOT NULL,
      is_dir      INTEGER NOT NULL,
      size        INTEGER NOT NULL,
      mtime       INTEGER NOT NULL,
      sha256      TEXT NOT NULL,
      UNIQUE(root_id, rel_path)
    );
  `);

  if (options.rootName.length > 0) {
    Statement stmt = db.prepare(`
      INSERT INTO roots (name, path, created_at)
      VALUES (?, ?, ?);
    `);
    stmt.bind(1, options.rootName);
    stmt.bind(2, options.rootPath);
    stmt.bind(3, options.createdAt);
    stmt.execute();
  }
}

string captureOutput(scope void delegate(File) writer) {
  File tmp = File.tmpfile();
  writer(tmp);
  tmp.rewind();
  const ulong sz = tmp.size;
  if (sz == 0) {
    return "";
  }
  char[] buf = new char[cast(size_t) sz];
  tmp.rawRead(buf);
  return cast(string) buf;
}

unittest {
  TempDir dir = TempDir("testutil");
  assert(dir.path.length > 0);
  import std.file : exists, write;
  const fpath = dir.subPath("sub.txt");
  write(fpath, "hello");
  assert(exists(fpath));

  const outStr = captureOutput((File f) {
    f.write("test capture");
  });
  assert(outStr == "test capture");
}
