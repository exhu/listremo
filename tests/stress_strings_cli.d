module orglistremo.stress_strings_cli;

import core.sys.posix.sys.stat : chmod;
import core.time : dur;
import d2sqlite3 : Database;
import orglistremo.db.connection : openDatabase;
import orglistremo.db.repo : EntryRepository, RootRepository;
import orglistremo.model : Entry, Root, RootSummary, SortField;
import orglistremo.output.console : ConsoleProgressReporter, OutputOptions;
import orglistremo.output.html :
  escapeHtml, printHtmlEntries, printHtmlRoots;
import orglistremo.output.units : formatLastSync, formatUnixTime;
import orglistremo.sync.scanner :
  isDiskDirEmpty, SyncPhase, SyncProgress;
import std.algorithm.searching : canFind;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, remove, rmdirRecurse, symlink, write;
import std.path : buildPath, isAbsolute;
import std.process : execute;
import std.stdio : File, writeln;
import std.string : indexOf, splitLines;
import std.utf : validate;

// Exact replica of console.d logic for pure algorithmic stress-testing
size_t countCodePointsRef(string s) {
  size_t count = 0;
  foreach (const char c; s) {
    if ((c & 0xC0) != 0x80) {
      count++;
    }
  }
  return count;
}

size_t findSuffixStartRef(string s, size_t targetCodePoints) {
  if (targetCodePoints == 0 || s.length == 0) {
    return s.length;
  }
  size_t count = 0;
  size_t i = s.length;
  while (i > 0) {
    i--;
    if ((s[i] & 0xC0) != 0x80) {
      count++;
      if (count == targetCodePoints) {
        return i;
      }
    }
  }
  return 0;
}

string truncatePathLeftRef(string path, size_t maxLen) {
  if (maxLen == 0) {
    return "";
  }
  if (path.length <= maxLen || countCodePointsRef(path) <= maxLen) {
    return path;
  }
  if (maxLen <= 3) {
    const size_t start = findSuffixStartRef(path, maxLen);
    return path[start .. $];
  }
  const size_t start = findSuffixStartRef(path, maxLen - 3);
  return "..." ~ path[start .. $];
}

void testBug02HtmlEscaping() {
  writeln("[TEST] BUG-02: HTML escaping with arbitrary non-UTF-8 bytes...");

  // 1. Raw invalid UTF-8 bytes mixed with HTML special characters
  ubyte[] rawBytes = [
    0xFF, 0xFE, 0x80, 0xBF, 0xC0, 0xC1, 0xF5, '<',
    0xE9, 0xE0, 0xF4, '>', '&', 0x80, '"', '\'', 0x00
  ];
  string invalidInput = cast(string) rawBytes;

  string escaped = escapeHtml(invalidInput);
  // Verify HTML chars are escaped
  assert(!escaped.canFind('<'), "Must not contain raw <");
  assert(!escaped.canFind('>'), "Must not contain raw >");
  assert(!escaped.canFind('"'), "Must not contain raw \"");
  assert(!escaped.canFind('\''), "Must not contain raw '");
  assert(escaped.canFind("&lt;"), "Must contain &lt;");
  assert(escaped.canFind("&gt;"), "Must contain &gt;");
  assert(escaped.canFind("&amp;"), "Must contain &amp;");
  assert(escaped.canFind("&quot;"), "Must contain &quot;");
  assert(escaped.canFind("&#39;"), "Must contain &#39;");

  // Verify non-UTF-8 byte preservation
  assert((cast(const(ubyte)[]) escaped).canFind(0xFF));
  assert((cast(const(ubyte)[]) escaped).canFind(0xFE));
  assert((cast(const(ubyte)[]) escaped).canFind(0xE9));

  // 2. Truncated UTF-8 sequences mixed with HTML characters
  ubyte[] truncSeq = [
    0xC3, '<',             // Truncated 2-byte UTF-8
    0xE3, 0x81, '>',       // Truncated 3-byte UTF-8
    0xF0, 0x9F, 0x9A, '&', // Truncated 4-byte UTF-8
    '"', '\''
  ];
  string truncInput = cast(string) truncSeq;
  string truncEscaped = escapeHtml(truncInput);
  assert(truncEscaped.canFind("&lt;"));
  assert(truncEscaped.canFind("&gt;"));
  assert(truncEscaped.canFind("&amp;"));
  assert(truncEscaped.canFind("&quot;"));
  assert(truncEscaped.canFind("&#39;"));

  // 3. Permutation of all 256 byte values
  ubyte[] allBytes = new ubyte[256];
  foreach (i; 0 .. 256) {
    allBytes[i] = cast(ubyte) i;
  }
  string allBytesInput = cast(string) allBytes;
  string allBytesEscaped = escapeHtml(allBytesInput);
  assert(!allBytesEscaped.canFind('<'));
  assert(!allBytesEscaped.canFind('>'));
  assert(!allBytesEscaped.canFind('"'));
  assert(!allBytesEscaped.canFind('\''));

  // 4. Large buffer of 50,000 invalid bytes mixed with HTML
  ubyte[] largeBuf;
  largeBuf.reserve(50000);
  for (size_t i = 0; i < 50000; i++) {
    const ubyte b = cast(ubyte)(i % 256);
    if (b == '<' || b == '>' || b == '&' || b == '"' || b == '\'') {
      largeBuf ~= b;
    } else {
      largeBuf ~= cast(ubyte)(0x80 + (i % 128));
    }
  }
  string largeEscaped = escapeHtml(cast(string) largeBuf);
  assert(!largeEscaped.canFind('<'));
  assert(!largeEscaped.canFind('>'));

  // 5. End-to-end printHtmlEntries with non-UTF-8 entries
  OutputOptions htmlOpts;
  const tempHtml = "/tmp/listremo_stress_html_test.html";
  File htmlFile = File(tempHtml, "w");
  Entry[] nonUtf8Entries = [
    Entry(
      1, 1, "root_latin",
      cast(string) [0xFF, 0xFE, 0x80, 'a', '<', 'b', '>'],
      ".",
      cast(string) [0xFF, 0xFE, 0x80, 'a', '<', 'b', '>'],
      false, 100, 1000, "h1"
    )
  ];
  printHtmlEntries(nonUtf8Entries, htmlOpts, htmlFile);
  htmlFile.close();
  assert(exists(tempHtml));
  remove(tempHtml);

  writeln("  -> PASSED: BUG-02 HTML escaping byte-safety verified.");
}

void testBug08TruncatePathLeft() {
  writeln("[TEST] BUG-08: UTF-8 code point boundary truncation...");

  string[] testPaths = [
    "документы/проекты/отчет_2026.pdf",
    "日本語/ディレクトリ/ファイル/ドキュメント.txt",
    "📁/🚀/🎉/🔥/✨/🌟/emoji_path.dat",
    "Mixed/документы/日本語/🚀_test.bin",
    "👨‍👩‍👧‍👦/family/photo.jpg",
    "ascii/path/to/normal/file.txt",
    ""
  ];

  // Algorithmic stress test across all boundary lengths
  foreach (path; testPaths) {
    const totalCp = countCodePointsRef(path);
    foreach (maxLen; 0 .. totalCp + 5) {
      const truncated = truncatePathLeftRef(path, maxLen);

      // 1. Result must be strictly valid UTF-8
      validate(truncated);

      // 2. Code point count must not exceed maxLen
      const resCp = countCodePointsRef(truncated);
      if (maxLen == 0) {
        assert(truncated == "");
      } else if (resCp > maxLen) {
        assert(false, "Truncated code points exceed maxLen");
      }

      // 3. For maxLen <= 3, no "..." prefix
      if (maxLen > 0 && maxLen <= 3) {
        if (totalCp > maxLen) {
          assert(!truncated.canFind("..."));
          assert(resCp == maxLen);
        }
      }

      // 4. For maxLen > 3, if truncated, prefix must be "..."
      if (maxLen > 3 && totalCp > maxLen) {
        assert(truncated.length >= 3);
        assert(truncated[0 .. 3] == "...");
        const suffix = truncated[3 .. $];
        validate(suffix);
        assert(countCodePointsRef(suffix) == maxLen - 3);
        // Suffix must match end of path
        assert(path[path.length - suffix.length .. $] == suffix);
      }
    }
  }

  // Non-UTF-8 bytes input test (must not throw or crash)
  const nonUtf8Path = cast(string) [0xFF, 0xFE, 'a', 'b', 'c'];
  const resTrunc = truncatePathLeftRef(nonUtf8Path, 3);
  assert(resTrunc.length > 0);

  // End-to-end integration test with ConsoleProgressReporter
  OutputOptions opts;
  const tempLog = "/tmp/listremo_console_progress_test.log";
  File f = File(tempLog, "w");
  auto reporter = new ConsoleProgressReporter(opts, 0, f, true);

  SyncProgress sp;
  sp.phase = SyncPhase.scanning;
  sp.fileCount = 10;
  sp.dirCount = 2;
  sp.totalBytes = 2048;
  sp.fileBytesHashed = 1024;
  sp.fileBytesTotal = 2048;

  foreach (p; testPaths) {
    sp.currentPath = p;
    reporter.update(sp);
  }
  reporter.finish();
  f.close();

  // Read log and validate all lines are valid UTF-8
  import std.file : readText;
  string content = readText(tempLog);
  validate(content);
  remove(tempLog);

  writeln("  -> PASSED: BUG-08 UTF-8 truncation strictly valid.");
}

void testBug06MultiTargetSorting() {
  writeln("[TEST] BUG-06: Multi-target listing sorting with 3+ targets...");

  const bin = "./listremo";
  const testDb = "/tmp/listremo_multi_target_sort_test.db";
  if (exists(testDb)) {
    remove(testDb);
  }

  // Initialize DB schema
  auto resInit = execute([bin, "--db", testDb, "migrate", "--no-backup"]);
  assert(resInit.status == 0, "Migrate must succeed");

  auto db = openDatabase(testDb);
  RootRepository rootRepo = RootRepository(db);
  const r1 = rootRepo.addRoot("alpha", "/mnt/alpha");
  const r2 = rootRepo.addRoot("beta", "/mnt/beta");
  const r3 = rootRepo.addRoot("gamma", "/mnt/gamma");

  // Insert conflicting entries:
  // Conflicting sizes: 500 (alpha & beta), 100 (alpha & gamma)
  // Conflicting mtimes: 3000 (alpha & gamma)
  Entry[] entries1 = [
    Entry(0, r1, "alpha", "f1.txt", ".", "f1.txt", false, 500, 1000, "h1"),
    Entry(0, r1, "alpha", "f2.txt", ".", "f2.txt", false, 100, 3000, "h2"),
    Entry(0, r1, "alpha", "f3.txt", ".", "f3.txt", false, 1000, 500, "h3")
  ];
  Entry[] entries2 = [
    Entry(0, r2, "beta", "f1.txt", ".", "f1.txt", false, 200, 2500, "h4"),
    Entry(0, r2, "beta", "f2.txt", ".", "f2.txt", false, 800, 1200, "h5"),
    Entry(0, r2, "beta", "f3.txt", ".", "f3.txt", false, 500, 1800, "h6")
  ];
  Entry[] entries3 = [
    Entry(0, r3, "gamma", "a.txt", ".", "a.txt", false, 100, 3000, "h7"),
    Entry(0, r3, "gamma", "b.txt", ".", "b.txt", false, 2000, 100, "h8"),
    Entry(0, r3, "gamma", "c.txt", ".", "c.txt", false, 50, 5000, "h9")
  ];

  EntryRepository entryRepo = EntryRepository(db);
  entryRepo.saveSyncEntries(r1, entries1, 1000);
  entryRepo.saveSyncEntries(r2, entries2, 2000);
  entryRepo.saveSyncEntries(r3, entries3, 3000);

  // 1. Test CLI multi-target list --sort size --format csv
  auto resSize = execute([
    bin, "--db", testDb, "list", "alpha", "beta", "gamma",
    "--sort", "size", "--format", "csv"
  ]);
  assert(resSize.status == 0, "CLI list --sort size must succeed");
  auto sizeLines = resSize.output.splitLines();
  // Line 0 is CSV header
  assert(sizeLines.length == 10, "Expected 9 entries + 1 header");

  string[] sizeOrder;
  foreach (line; sizeLines[1 .. $]) {
    import std.string : split;
    auto cols = line.split(",");
    // CSV format: root,full_path,rel_path,type,size,mtime,sha256
    sizeOrder ~= cols[1];
  }
  string[] expectedSizePaths = [
    "gamma:/b.txt",  // 2000
    "alpha:/f3.txt", // 1000
    "beta:/f2.txt",  // 800
    "alpha:/f1.txt", // 500 (alpha before beta)
    "beta:/f3.txt",  // 500
    "beta:/f1.txt",  // 200
    "alpha:/f2.txt", // 100 (alpha before gamma)
    "gamma:/a.txt",  // 100
    "gamma:/c.txt"   // 50
  ];
  assert(
    sizeOrder == expectedSizePaths,
    "Global size sort order across 3 targets mismatch"
  );

  // 2. Test CLI multi-target list --sort mtime --format csv
  auto resMtime = execute([
    bin, "--db", testDb, "list", "alpha", "beta", "gamma",
    "--sort", "mtime", "--format", "csv"
  ]);
  assert(resMtime.status == 0, "CLI list --sort mtime must succeed");
  auto mtimeLines = resMtime.output.splitLines();
  assert(mtimeLines.length == 10);
  string[] mtimeOrder;
  foreach (line; mtimeLines[1 .. $]) {
    import std.string : split;
    auto cols = line.split(",");
    mtimeOrder ~= cols[1];
  }
  string[] expectedMtimePaths = [
    "gamma:/c.txt",  // 5000
    "alpha:/f2.txt", // 3000 (alpha before gamma)
    "gamma:/a.txt",  // 3000
    "beta:/f1.txt",  // 2500
    "beta:/f3.txt",  // 1800
    "beta:/f2.txt",  // 1200
    "alpha:/f1.txt", // 1000
    "alpha:/f3.txt", // 500
    "gamma:/b.txt"   // 100
  ];
  assert(
    mtimeOrder == expectedMtimePaths,
    "Global mtime sort order across 3 targets mismatch"
  );

  // 3. Test CLI multi-target list --sort path --format csv
  auto resPath = execute([
    bin, "--db", testDb, "list", "alpha", "beta", "gamma",
    "--sort", "path", "--format", "csv"
  ]);
  assert(resPath.status == 0, "CLI list --sort path must succeed");
  auto pathLines = resPath.output.splitLines();
  assert(pathLines.length == 10);
  string[] pathOrder;
  foreach (line; pathLines[1 .. $]) {
    import std.string : split;
    auto cols = line.split(",");
    pathOrder ~= cols[1];
  }
  string[] expectedPathOrder = [
    "alpha:/f1.txt", "alpha:/f2.txt", "alpha:/f3.txt",
    "beta:/f1.txt", "beta:/f2.txt", "beta:/f3.txt",
    "gamma:/a.txt", "gamma:/b.txt", "gamma:/c.txt"
  ];
  assert(
    pathOrder == expectedPathOrder,
    "Global path sort order across 3 targets mismatch"
  );

  // 4. Test CLI multi-target list with reverse target arguments
  auto resRev = execute([
    bin, "--db", testDb, "list", "gamma", "beta", "alpha",
    "--sort", "path", "--format", "csv"
  ]);
  assert(resRev.status == 0);
  auto revLines = resRev.output.splitLines();
  assert(revLines.length == 10);
  string[] revPathOrder;
  foreach (line; revLines[1 .. $]) {
    import std.string : split;
    auto cols = line.split(",");
    revPathOrder ~= cols[1];
  }
  assert(
    revPathOrder == expectedPathOrder,
    "Reverse argument order must still be sorted globally"
  );

  remove(testDb);
  writeln("  -> PASSED: BUG-06 multi-target sorting verified via CLI.");
}

void testBug03And12CliOptions() {
  writeln("[TEST] BUG-03 & BUG-12: CLI options and root validation...");

  const bin = "./listremo";
  const testDb = "/tmp/listremo_cli_test_stress.db";
  if (exists(testDb)) {
    remove(testDb);
  }
  execute([bin, "--db", testDb, "migrate", "--no-backup"]);

  // 1. --progress-interval 0 rejection
  auto res1 = execute([
    bin, "--db", testDb, "sync", "testroot", "--progress-interval", "0"
  ]);
  assert(res1.status != 0, "--progress-interval 0 must exit non-zero");
  assert(
    res1.output.canFind("Invalid --progress-interval value '0'"),
    "Expected positive integer error message"
  );
  assert(!res1.output.canFind("core.exception"), "Must not show stack trace");

  // 2. --progress-interval negative rejection
  auto res2 = execute([
    bin, "--db", testDb, "sync", "testroot", "--progress-interval", "-10"
  ]);
  assert(res2.status != 0, "--progress-interval -10 must exit non-zero");

  // 3. --progress-interval missing argument
  auto res3 = execute([
    bin, "--db", testDb, "sync", "testroot", "--progress-interval"
  ]);
  assert(res3.status != 0, "Missing argument must exit non-zero");
  assert(res3.output.canFind("Missing value for --progress-interval option"));

  // 4. -j flag without --all produces warning
  auto res4 = execute([
    bin, "--db", testDb, "sync", "testroot", "-j", "4"
  ]);
  assert(
    res4.output.canFind(
      "Warning: Option --jobs/-j has no effect without --all."
    ),
    "Expected warning for -j without --all"
  );

  // 5. Root name with colon rejection

  auto res5 = execute([
    bin, "--db", testDb, "root", "add", "bad:name", "/tmp"
  ]);
  assert(res5.status != 0, "Root with colon must be rejected");
  assert(
    res5.output.canFind("Error: Root name cannot contain ':'"),
    "Expected colon error message"
  );
  assert(!res5.output.canFind("core.exception"), "Must not throw assert");

  // 6. Empty root name rejection
  auto res6 = execute([bin, "--db", testDb, "root", "add", "", "/tmp"]);
  assert(res6.status != 0, "Empty root name must be rejected");
  assert(res6.output.canFind("Error: Root name cannot be empty."));

  // 7. Empty root path rejection
  auto res7 = execute([bin, "--db", testDb, "root", "add", "valid_name", ""]);
  assert(res7.status != 0, "Empty root path must be rejected");
  assert(res7.output.canFind("Error: Root path cannot be empty."));

  // 8. Unnormalized relative path normalization
  auto res8 = execute([
    bin, "--db", testDb, "root", "add", "norm_root", "./foo/../bar/./baz"
  ]);
  assert(res8.status == 0, "Root add with relative path must succeed");
  // Check path stored in db
  auto db = openDatabase(testDb);
  RootRepository rootRepo = RootRepository(db);
  Root stored;
  assert(rootRepo.findByName("norm_root", stored));
  assert(isAbsolute(stored.path), "Stored path must be absolute");
  assert(!stored.path.canFind("/./"), "Must not contain /./");
  assert(!stored.path.canFind("/../"), "Must not contain /../");

  // 9. Root set-path with unnormalized relative path
  auto res9 = execute([
    bin, "--db", testDb, "root", "set-path", "norm_root", "./other/../path"
  ]);
  assert(res9.status == 0, "Root set-path must succeed");
  assert(rootRepo.findByName("norm_root", stored));
  assert(isAbsolute(stored.path));
  assert(!stored.path.canFind("/./"));
  assert(!stored.path.canFind("/../"));

  // 10. Root set-path on non-existent root
  auto res10 = execute([
    bin, "--db", testDb, "root", "set-path", "ghost_root", "/tmp"
  ]);
  assert(res10.status != 0);
  assert(res10.output.canFind("Error: Root 'ghost_root' not found."));

  // Clean up
  if (exists(testDb)) {
    remove(testDb);
  }

  writeln("  -> PASSED: BUG-03 & BUG-12 CLI options validation verified.");
}

void testBug09SymlinkEmptyDir() {
  writeln("[TEST] BUG-09: isDiskDirEmpty with symlinks and permissions...");

  const baseDir = "/tmp/listremo_stress_symlink_test";
  if (exists(baseDir)) {
    rmdirRecurse(baseDir);
  }
  mkdirRecurse(baseDir);

  const emptyDir = buildPath(baseDir, "empty");
  mkdirRecurse(emptyDir);
  assert(isDiskDirEmpty(emptyDir), "Truly empty directory must be empty");

  // 1. Directory with a valid file
  const fileDir = buildPath(baseDir, "with_file");
  mkdirRecurse(fileDir);
  write(buildPath(fileDir, "test.txt"), "hello");
  assert(!isDiskDirEmpty(fileDir), "Dir with file must NOT be empty");

  // 2. Directory with ONLY a symlink to an existing file
  const symDir = buildPath(baseDir, "with_symlink");
  mkdirRecurse(symDir);
  symlink(buildPath(fileDir, "test.txt"), buildPath(symDir, "link_to_file"));
  assert(!isDiskDirEmpty(symDir), "Dir with symlink to file must NOT be empty");

  // 3. Directory with ONLY a broken symlink (target does not exist)
  const brokenDir = buildPath(baseDir, "with_broken_symlink");
  mkdirRecurse(brokenDir);
  symlink(
    buildPath(baseDir, "non_existent_target.txt"),
    buildPath(brokenDir, "broken_link")
  );
  assert(
    !isDiskDirEmpty(brokenDir),
    "Dir with broken symlink must NOT be empty"
  );

  // 4. Directory with ONLY a symlink to an empty directory
  const symToEmptyDir = buildPath(baseDir, "with_symlink_to_dir");
  mkdirRecurse(symToEmptyDir);
  symlink(emptyDir, buildPath(symToEmptyDir, "link_to_dir"));
  assert(
    !isDiskDirEmpty(symToEmptyDir),
    "Dir with symlink to empty dir must NOT be empty"
  );

  // 4b. Directory with cyclical symlink (pointing to '.')
  const symToSelf = buildPath(baseDir, "with_self_symlink");
  mkdirRecurse(symToSelf);
  symlink(".", buildPath(symToSelf, "self_link"));
  assert(!isDiskDirEmpty(symToSelf), "Dir with self symlink is NOT empty");

  // 4c. Directory with symlink to /dev/null
  const symToDevNull = buildPath(baseDir, "with_devnull_symlink");
  mkdirRecurse(symToDevNull);
  symlink("/dev/null", buildPath(symToDevNull, "devnull_link"));
  assert(
    !isDiskDirEmpty(symToDevNull),
    "Dir with devnull symlink is NOT empty"
  );

  // 4d. Directory with an empty subdirectory
  const dirWithSubdir = buildPath(baseDir, "with_empty_subdir");
  mkdirRecurse(dirWithSubdir);
  mkdirRecurse(buildPath(dirWithSubdir, "sub"));
  assert(!isDiskDirEmpty(dirWithSubdir), "Dir with subdir is NOT empty");

  // 5. Inaccessible directory (permission denied)
  const inaccDir = buildPath(baseDir, "inaccessible");
  mkdirRecurse(inaccDir);
  chmod((inaccDir ~ "\0").ptr, 0); // Remove all permissions
  scope (exit) {
    chmod((inaccDir ~ "\0").ptr, 493); // 0755 restore
  }

  import std.file : FileException;
  assertThrown!FileException(
    isDiskDirEmpty(inaccDir),
    "isDiskDirEmpty must propagate FileException on permission denied"
  );

  // Cleanup
  chmod((inaccDir ~ "\0").ptr, 493);
  rmdirRecurse(baseDir);

  writeln("  -> PASSED: BUG-09 symlink and permission handling verified.");
}

void testBug15TimestampDecoupling() {
  writeln("[TEST] BUG-15: formatUnixTime and formatLastSync...");

  // 1. formatUnixTime(0) produces a valid timestamp, NOT "never"
  const epochStr = formatUnixTime(0);
  assert(epochStr != "never", "formatUnixTime(0) must not return 'never'");
  assert(epochStr.length == 19, "Must be formatted as YYYY-MM-DD HH:MM:SS");
  assert(epochStr[0 .. 4] == "1970", "Epoch timestamp year must be 1970");

  // 2. formatUnixTime with pre-epoch and future timestamps
  const preEpochStr = formatUnixTime(-100);
  assert(preEpochStr != "never", "Negative ts must not return 'never'");
  assert(formatUnixTime(-1).length == 19);
  assert(formatUnixTime(-86400).length == 19);
  assert(formatUnixTime(2147483647).length == 19);
  assert(formatUnixTime(4102444800).length == 19);

  // 3. formatLastSync with hasLastSync = false always outputs "never"
  assert(formatLastSync(0, false) == "never");
  assert(formatLastSync(10000, false) == "never");
  assert(formatLastSync(-100, false) == "never");

  // 4. formatLastSync with hasLastSync = true outputs valid timestamp
  assert(formatLastSync(0, true) == epochStr);
  assert(formatLastSync(0, true) != "never");
  const recentStr = formatLastSync(1700000000, true);
  assert(recentStr.length == 19);
  assert(recentStr != "never");

  writeln("  -> PASSED: BUG-15 timestamp decoupling verified.");
}

void main() {
  writeln("=== EMPIRICAL STRESS TEST SUITE: STRINGS, CLI & OUTPUT ===");

  testBug02HtmlEscaping();
  testBug08TruncatePathLeft();
  testBug06MultiTargetSorting();
  testBug03And12CliOptions();
  testBug09SymlinkEmptyDir();
  testBug15TimestampDecoupling();

  writeln("=== ALL 6 EMPIRICAL STRESS TESTS PASSED SUCCESSFULLY ===");
}
