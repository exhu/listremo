module orglistremo.empirical_m2_stress;

import core.atomic : atomicLoad, atomicOp;
import d2sqlite3 : Database;
import orglistremo.db.connection : openDatabase;
import orglistremo.db.repo :
  EntryRepository, ListEntriesFilter, RootRepository;
import orglistremo.internal.testutil : captureOutput, TempDir;
import orglistremo.model :
  DuplicateGroup, DuplicateStats, emptyHash, Entry, EntryParams, EntryStats,
  EntryType, groupDuplicates, makeEntry, Root, RootSummary,
  summarizeDuplicates;
import orglistremo.output.console :
  OutputOptions, printConsoleDuplicates, printConsoleEntries;
import orglistremo.output.csv :
  printCsvDuplicates, printCsvEntries;
import orglistremo.output.html :
  printHtmlDuplicates, printHtmlEntries;
import orglistremo.output.units :
  formatHash;
import orglistremo.pattern :
  escapeLikeLiteral, hasGlobWildcard, hasPatternWildcard, isWildcard,
  NamePattern, unescapePatternEscapes, userPatternToLike;
import orglistremo.sync.hasher :
  ChildRecord, hashDirectory, hashFile;
import std.algorithm.searching : canFind;
import std.file : exists, write;
import std.format : format;
import std.path : buildPath;
import std.stdio : File, stderr, writeln;

shared int g_failures = 0;
shared int g_assertions = 0;

void recordAssertion(bool condition, string testName, string detail) {
  atomicOp!"+="(g_assertions, 1);
  if (condition) {
    writeln("  [PASS] ", testName, ": ", detail);
  } else {
    atomicOp!"+="(g_failures, 1);
    stderr.writeln("  [FAIL] ", testName, ": ", detail);
  }
}

// Exact replica of source/orglistremo/output/csv.d:84-110
// (which is declared private in csv.d).
string escapeCsvFieldRef(string val) {
  bool needsQuotes = false;
  foreach (c; val) {
    if (c == ',' || c == '"' || c == '\n' || c == '\r') {
      needsQuotes = true;
      break;
    }
  }

  if (!needsQuotes) {
    return val;
  }

  import std.array : Appender, appender;
  Appender!string app = appender!string();
  app.reserve(val.length + 8);
  app.put('"');
  foreach (c; val) {
    if (c == '"') {
      app.put("\"\"");
    } else {
      app.put(c);
    }
  }
  app.put('"');
  return app.data;
}

// ---------------------------------------------------------------------------
// Suite 1: Zero-Allocation Fast Paths (.ptr is s.ptr)
// ---------------------------------------------------------------------------
void testZeroAllocationFastPaths() {
  writeln("\n=== SUITE 1: Zero-Allocation Fast Paths Stress Testing ===");

  // 1. userPatternToLike fast path (no '_' and no '\')
  string[] cleanUserPatterns = [
    "",
    "a",
    "simple",
    "UPPERCASE",
    "camelCaseName",
    "numbers1234567890",
    "symbols-allowed.txt",
    "path/to/my/file.tar.gz",
    "file%with%wildcards",
    "%prefix-and-suffix%",
    "spaces in file name",
    "tabs\tand\tmore",
    "punctuation!@#$^&*()-+={}[]|:;'<>,.?/",
    "non_ascii_cyrillic_нет", // wait: has '_', should allocate
    "русский-текст/файл-без-подчеркиваний.txt",
    "日本語/カタカナ/ひらがな.doc",
    "🎉🚀🌟/emoji-no-underscore.png"
  ];

  // Filter out the one with underscore for clean testing
  foreach (s; cleanUserPatterns) {
    if (s.canFind('_') || s.canFind('\\')) {
      continue;
    }
    const res = userPatternToLike(s);
    recordAssertion(
      res.ptr is s.ptr && res.length == s.length,
      "userPatternToLike_fast_path",
      format("slice identical for '%s' (len=%d)", s, s.length)
    );
  }

  // Verify that strings WITH special characters DO allocate and escape
  string[] escapingUserPatterns = [
    "file_with_underscore",
    "file\\with\\backslash",
    "mixed_\\_characters",
    "_"
  ];
  foreach (s; escapingUserPatterns) {
    const res = userPatternToLike(s);
    recordAssertion(
      res.ptr !is s.ptr,
      "userPatternToLike_slow_path",
      format("escaped and allocated for '%s'", s)
    );
  }

  // 2. escapeLikeLiteral fast path (no '%', '_', '\')
  string[] cleanLikeLiterals = [
    "",
    "a",
    "cleanLiteral",
    "path/to/something.txt",
    "UPPER-and-lower",
    "digits9876543210",
    "symbols!@#$^&*()-+={}[]|:;'<>,.?/",
    "spaces in literal",
    "кириллица-без-спецсимволов",
    "日本語-テスト"
  ];
  foreach (s; cleanLikeLiterals) {
    const res = escapeLikeLiteral(s);
    recordAssertion(
      res.ptr is s.ptr && res.length == s.length,
      "escapeLikeLiteral_fast_path",
      format("slice identical for '%s' (len=%d)", s, s.length)
    );
  }

  string[] escapingLikeLiterals = [
    "literal%percent",
    "literal_underscore",
    "literal\\backslash",
    "%",
    "_",
    "\\"
  ];
  foreach (s; escapingLikeLiterals) {
    const res = escapeLikeLiteral(s);
    recordAssertion(
      res.ptr !is s.ptr,
      "escapeLikeLiteral_slow_path",
      format("escaped and allocated for '%s'", s)
    );
  }

  // 3. unescapePatternEscapes fast path (no `\%` and no `\\`)
  string[] cleanUnescapes = [
    "",
    "a",
    "plain/string",
    "contains%without%escape",
    "trailing_backslash\\",
    "slash_a\\a_not_escape",
    "slash_t\\t_not_escape",
    "slash_underscore\\_",
    "кириллица-текст"
  ];
  foreach (s; cleanUnescapes) {
    const res = unescapePatternEscapes(s);
    recordAssertion(
      res.ptr is s.ptr && res.length == s.length,
      "unescapePatternEscapes_fast_path",
      format("slice identical for '%s' (len=%d)", s, s.length)
    );
  }

  string[] escapingUnescapes = [
    "100\\%done",
    "double\\\\backslash",
    "prefix\\%middle\\\\suffix",
    "\\%",
    "\\\\"
  ];
  foreach (s; escapingUnescapes) {
    const res = unescapePatternEscapes(s);
    recordAssertion(
      res.ptr !is s.ptr,
      "unescapePatternEscapes_slow_path",
      format("unescaped and allocated for '%s'", s)
    );
  }

  // 4. escapeCsvField fast path (no ',', '"', '\n', '\r')
  string[] cleanCsvFields = [
    "",
    "a",
    "simple_column",
    "UPPERCASE-DATA",
    "digits12345",
    "col:with;colons!and?marks",
    "spaces inside field",
    "slash/and\\backslash",
    "percent%and_underscore",
    "unicode_данные_тест",
    "🚀🌟🎉"
  ];
  foreach (s; cleanCsvFields) {
    const res = escapeCsvFieldRef(s);
    recordAssertion(
      res.ptr is s.ptr && res.length == s.length,
      "escapeCsvField_fast_path",
      format("slice identical for '%s' (len=%d)", s, s.length)
    );
  }

  string[] escapingCsvFields = [
    "field,with,comma",
    "field\"with\"quote",
    "field\nwith\nnewline",
    "field\rwith\rcarriage",
    ",",
    "\"",
    "\n",
    "\r"
  ];
  foreach (s; escapingCsvFields) {
    const res = escapeCsvFieldRef(s);
    recordAssertion(
      res.ptr !is s.ptr,
      "escapeCsvField_slow_path",
      format("escaped and allocated for '%s'", s)
    );
  }

  // 5. Stress loop with 10,000 synthetic strings
  import std.random : Random, uniform;
  Random rng = Random(12345);
  static immutable string charsNoSpecial =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-./";
  for (size_t iter = 0; iter < 1000; iter++) {
    char[] buf = new char[uniform(5, 50, rng)];
    foreach (ref c; buf) {
      c = charsNoSpecial[uniform(0, charsNoSpecial.length, rng)];
    }
    string syn = buf.idup;
    assert(userPatternToLike(syn).ptr is syn.ptr);
    assert(escapeLikeLiteral(syn).ptr is syn.ptr);
    assert(unescapePatternEscapes(syn).ptr is syn.ptr);
    assert(escapeCsvFieldRef(syn).ptr is syn.ptr);
  }
  recordAssertion(
    true,
    "synthetic_batch_1000",
    "1000 random clean strings verified with zero allocations"
  );
}

// ---------------------------------------------------------------------------
// Suite 2: BUG-16 Hash Underscore Matching & Wildcard Escaping
// ---------------------------------------------------------------------------
void testBug16HashUnderscoreMatching(string dbPath) {
  writeln("\n=== SUITE 2: BUG-16 Hash Underscore Matching Stress Testing ===");

  Database db = openDatabase(dbPath);
  RootRepository rootRepo = RootRepository(db);
  EntryRepository entryRepo = EntryRepository(db);

  const rId = rootRepo.addRoot("root1", "/test/root1");

  // Populate entries with various hashes
  Entry[] testEntries = [
    // Literal underscores in hash
    Entry(0, rId, "root1", "f1.bin", ".", "f1.bin", false, 100, 1000,
          "hash_dup_123"),
    Entry(0, rId, "root1", "f2.bin", ".", "f2.bin", false, 100, 1000,
          "hash_dup_456"),
    // Non-underscore hashes that would match if '_' were wildcard
    Entry(0, rId, "root1", "f3.bin", ".", "f3.bin", false, 100, 1000,
          "hashXdupX123"),
    Entry(0, rId, "root1", "f4.bin", ".", "f4.bin", false, 100, 1000,
          "hash1dup1456"),
    // Double underscore
    Entry(0, rId, "root1", "f5.bin", ".", "f5.bin", false, 100, 1000,
          "sha256__double"),
    // Single underscore
    Entry(0, rId, "root1", "f6.bin", ".", "f6.bin", false, 100, 1000,
          "sha256_single"),
    // No underscore
    Entry(0, rId, "root1", "f7.bin", ".", "f7.bin", false, 100, 1000,
          "sha256Xsingle"),
    // Standard 64-char hex
    Entry(0, rId, "root1", "f8.bin", ".", "f8.bin", false, 200, 1000,
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    // Empty hash
    Entry(0, rId, "root1", "f9.bin", ".", "f9.bin", false, 0, 1000,
          emptyHash)
  ];
  entryRepo.saveSyncEntries(rId, testEntries, 9000);

  // Test 1: Exact hash with underscore matches ONLY literal underscore
  ListEntriesFilter fExact;
  fExact.hashPattern = "hash_dup_123";
  const exactRes = entryRepo.listEntries("root1", fExact);
  recordAssertion(
    exactRes.length == 1 && exactRes[0].sha256 == "hash_dup_123",
    "bug16_exact_underscore",
    format("matched %d entries (expected 1: hash_dup_123)", exactRes.length)
  );

  // Test 2: Hash with underscore prefix + % wildcard
  ListEntriesFilter fWildcard;
  fWildcard.hashPattern = "hash_dup_%";
  const wildRes = entryRepo.listEntries("root1", fWildcard);
  recordAssertion(
    wildRes.length == 2 &&
    wildRes[0].sha256.canFind("hash_dup_") &&
    wildRes[1].sha256.canFind("hash_dup_"),
    "bug16_underscore_plus_percent",
    format("matched %d entries (expected 2: hash_dup_123, hash_dup_456)",
           wildRes.length)
  );

  // Ensure "hashXdupX123" was NOT matched by "hash_dup_%"
  bool matchedNonUnderscore = false;
  foreach (ref e; wildRes) {
    if (e.sha256 == "hashXdupX123" || e.sha256 == "hash1dup1456") {
      matchedNonUnderscore = true;
    }
  }
  recordAssertion(
    !matchedNonUnderscore,
    "bug16_no_wildcard_expansion_for_underscore",
    "hashXdupX123 was correctly NOT matched by hash_dup_%"
  );

  // Test 3: Double underscore vs single underscore
  ListEntriesFilter fDouble;
  fDouble.hashPattern = "sha256__double";
  const doubleRes = entryRepo.listEntries("root1", fDouble);
  recordAssertion(
    doubleRes.length == 1 && doubleRes[0].sha256 == "sha256__double",
    "bug16_double_underscore",
    "matched literal double underscore"
  );

  // Test 4: Query with underscore wildcard character position
  // If '_' were wildcard, "sha256_single" would match "sha256Xsingle"
  ListEntriesFilter fSingle;
  fSingle.hashPattern = "sha256_single";
  const singleRes = entryRepo.listEntries("root1", fSingle);
  recordAssertion(
    singleRes.length == 1 && singleRes[0].sha256 == "sha256_single",
    "bug16_single_underscore_strict",
    "matched sha256_single and NOT sha256Xsingle"
  );

  // Test 5: Single underscore query "h_" must NOT match 2-char hashes
  // unless literal
  ListEntriesFilter fShort;
  fShort.hashPattern = "h_";
  const shortRes = entryRepo.listEntries("root1", fShort);
  recordAssertion(
    shortRes.length == 0,
    "bug16_h_underscore_no_wildcard",
    format("matched %d entries for pattern 'h_' (expected 0)", shortRes.length)
  );

  // Test 6: Global '%' query
  ListEntriesFilter fAll;
  fAll.hashPattern = "%";
  const allRes = entryRepo.listEntries("root1", fAll);
  recordAssertion(
    allRes.length == testEntries.length,
    "bug16_percent_multi_wildcard",
    format("matched all %d entries with '%%'", allRes.length)
  );
}

// ---------------------------------------------------------------------------
// Suite 3: emptyHash Consistency
// ---------------------------------------------------------------------------
void testEmptyHashConsistency(string workDir) {
  writeln("\n=== SUITE 3: emptyHash Consistency Stress Testing ===");

  // 1. Constant value
  recordAssertion(
    emptyHash == "0",
    "emptyHash_literal_value",
    "emptyHash is defined as '0'"
  );

  // 2. Default model structs
  Entry eDefault;
  recordAssertion(
    eDefault.sha256 == emptyHash,
    "entry_default_sha256",
    "Entry.init has sha256 == emptyHash"
  );

  EntryParams pDefault;
  recordAssertion(
    pDefault.sha256 == emptyHash,
    "entry_params_default_sha256",
    "EntryParams.init has sha256 == emptyHash"
  );

  const eMade = makeEntry("test/file.txt");
  recordAssertion(
    eMade.sha256 == emptyHash,
    "makeEntry_default_sha256",
    "makeEntry() has sha256 == emptyHash"
  );

  // 3. Hasher behavior
  const emptyFilePath = buildPath(workDir, "zero_byte_file.tmp");
  write(emptyFilePath, "");
  const hashOfEmptyFile = hashFile(emptyFilePath, 0);
  recordAssertion(
    hashOfEmptyFile == emptyHash,
    "hasher_zero_size_file",
    format("hashFile for 0-byte file returned '%s'", hashOfEmptyFile)
  );

  string dirHash;
  ulong dirSize;
  hashDirectory([], dirHash, dirSize);
  recordAssertion(
    dirHash == emptyHash && dirSize == 0,
    "hasher_empty_directory",
    format("hashDirectory for 0 children returned hash='%s', size=%d",
           dirHash, dirSize)
  );

  // 4. Units formatHash
  recordAssertion(
    formatHash("0", false) == "0",
    "units_formatHash_short",
    "formatHash('0', false) returns '0'"
  );
  recordAssertion(
    formatHash("0", true) == "0",
    "units_formatHash_full",
    "formatHash('0', true) returns '0'"
  );
  recordAssertion(
    formatHash(emptyHash, false) == emptyHash,
    "units_formatHash_emptyHash",
    "formatHash(emptyHash, false) returns emptyHash"
  );

  // 5. Console, HTML, and CSV output handling emptyHash
  Entry eEmpty = makeEntry("empty.txt", false, 0);
  eEmpty.sha256 = emptyHash;
  eEmpty.rootName = "root1";

  DuplicateGroup dgEmpty;
  dgEmpty.sha256 = emptyHash;
  dgEmpty.size = 0;
  dgEmpty.isDir = false;
  dgEmpty.entries = [eEmpty];

  OutputOptions opts;
  const consoleOut = captureOutput((File f) {
    printConsoleEntries([eEmpty], opts, f);
    printConsoleDuplicates([dgEmpty], opts, f);
  });
  recordAssertion(
    consoleOut.canFind("empty.txt") && consoleOut.canFind(" 0 "),
    "console_output_emptyHash",
    "Console output formatted emptyHash correctly"
  );

  const htmlOut = captureOutput((File f) {
    printHtmlEntries([eEmpty], opts, f);
    printHtmlDuplicates([dgEmpty], opts, f);
  });
  recordAssertion(
    htmlOut.canFind("empty.txt") && htmlOut.canFind("title=\"0\""),
    "html_output_emptyHash",
    "HTML output formatted emptyHash with title='0'"
  );

  const csvOut = captureOutput((File f) {
    printCsvEntries([eEmpty], f);
    printCsvDuplicates([dgEmpty], f);
  });
  recordAssertion(
    csvOut.canFind(",0\n") || csvOut.canFind(",0,"),
    "csv_output_emptyHash",
    "CSV output formatted emptyHash field as '0'"
  );
}

// ---------------------------------------------------------------------------
// Suite 4: groupDuplicates Stress & Edge Cases
// ---------------------------------------------------------------------------
void testGroupDuplicatesStress() {
  writeln("\n=== SUITE 4: groupDuplicates Stress Testing ===");

  // 1. Empty array
  const emptyGroups = groupDuplicates([]);
  recordAssertion(
    emptyGroups.length == 0,
    "groupDuplicates_empty",
    "returns empty array for empty input"
  );

  // 2. Single entry
  Entry e1 = makeEntry("f1.txt", false, 100);
  e1.sha256 = "hashA";
  const singleGroup = groupDuplicates([e1]);
  recordAssertion(
    singleGroup.length == 1 &&
    singleGroup[0].entries.length == 1 &&
    singleGroup[0].sha256 == "hashA",
    "groupDuplicates_single",
    "returns 1 group of 1 entry"
  );

  // 3. Partition by isDir when sha256 is identical (e.g. emptyHash)
  Entry fileEmpty1 = makeEntry("f_empty1.txt", false, 0);
  fileEmpty1.sha256 = emptyHash;
  Entry fileEmpty2 = makeEntry("f_empty2.txt", false, 0);
  fileEmpty2.sha256 = emptyHash;
  Entry dirEmpty1 = makeEntry("d_empty1", true, 0);
  dirEmpty1.sha256 = emptyHash;
  Entry dirEmpty2 = makeEntry("d_empty2", true, 0);
  dirEmpty2.sha256 = emptyHash;

  // Sorted by (size DESC, is_dir, sha256)
  Entry[] mixedEmpty = [fileEmpty1, fileEmpty2, dirEmpty1, dirEmpty2];
  const emptyResult = groupDuplicates(mixedEmpty);
  recordAssertion(
    emptyResult.length == 2 &&
    !emptyResult[0].isDir && emptyResult[0].entries.length == 2 &&
    emptyResult[1].isDir && emptyResult[1].entries.length == 2,
    "groupDuplicates_emptyHash_isDir_partition",
    "files and dirs with emptyHash are partitioned into separate groups"
  );

  // 4. Large scale duplicate grouping
  // (5,000 groups x 4 duplicates = 20,000 entries)
  enum NUM_GROUPS = 5000;
  enum DUP_PER_GROUP = 4;
  Entry[] largeEntries;
  largeEntries.reserve(NUM_GROUPS * DUP_PER_GROUP);

  for (size_t g = 0; g < NUM_GROUPS; g++) {
    const string hashVal = format("hash_%08d", g);
    const ulong sz = 1000 + (g % 500);
    for (size_t d = 0; d < DUP_PER_GROUP; d++) {
      Entry e = makeEntry(format("dir_%d/file_%d.dat", g, d), false, sz);
      e.sha256 = hashVal;
      e.rootName = format("root_%d", d);
      largeEntries ~= e;
    }
  }

  const largeGroups = groupDuplicates(largeEntries);
  recordAssertion(
    largeGroups.length == NUM_GROUPS,
    "groupDuplicates_large_scale_count",
    format("correctly formed %d groups from %d entries",
           largeGroups.length, largeEntries.length)
  );

  bool allGroupsValid = true;
  for (size_t g = 0; g < NUM_GROUPS; g++) {
    if (largeGroups[g].entries.length != DUP_PER_GROUP ||
        largeGroups[g].sha256 != format("hash_%08d", g)) {
      allGroupsValid = false;
      break;
    }
  }
  recordAssertion(
    allGroupsValid,
    "groupDuplicates_large_scale_integrity",
    "all 5,000 groups have exact 4 entries and matching hashes"
  );

  // 5. summarizeDuplicates verification
  const dupStats = summarizeDuplicates(largeGroups);
  recordAssertion(
    dupStats.groupCount == NUM_GROUPS &&
    dupStats.duplicateCopies == NUM_GROUPS * (DUP_PER_GROUP - 1),
    "summarizeDuplicates_scale",
    format("summarized %d groups with %d duplicate copies",
           dupStats.groupCount, dupStats.duplicateCopies)
  );
}

// ---------------------------------------------------------------------------
// Suite 5: makeEntry and deriveEntryPath
// ---------------------------------------------------------------------------
void testMakeEntryAndDerivePath() {
  writeln("\n=== SUITE 5: makeEntry and deriveEntryPath Stress Testing ===");

  struct PathTestCase {
    string relPath;
    string expectedParent;
    string expectedName;
  }

  PathTestCase[] testCases = [
    // Root level
    PathTestCase(".", null, "."),
    PathTestCase("", null, "."),
    PathTestCase("readme.txt", ".", "readme.txt"),
    PathTestCase("Cargo.toml", ".", "Cargo.toml"),
    PathTestCase(".gitignore", ".", ".gitignore"),
    PathTestCase("Makefile", ".", "Makefile"),

    // Single directory level
    PathTestCase("docs", ".", "docs"),
    PathTestCase("src/main.d", "src", "main.d"),
    PathTestCase(".git/config", ".git", "config"),

    // Deep nested hierarchy
    PathTestCase("a/b/c/d/e/f/g/h/target.bin",
                 "a/b/c/d/e/f/g/h", "target.bin"),
    PathTestCase("var/log/system/2026/10/audit.log",
                 "var/log/system/2026/10", "audit.log"),

    // Spaces and dots
    PathTestCase("My Documents/Annual Reports/2026 Q3 (Final).pdf",
                 "My Documents/Annual Reports", "2026 Q3 (Final).pdf"),
    PathTestCase("v1.2.3/build.4.5/archive.tar.gz",
                 "v1.2.3/build.4.5", "archive.tar.gz"),

    // Unicode / multibyte UTF-8 paths
    PathTestCase("документы/бухгалтерия/отчет.xlsx",
                 "документы/бухгалтерия",
                 "отчет.xlsx"),
    PathTestCase("写真/旅行/京都/寺院.jpg",
                 "写真/旅行/京都", "寺院.jpg"),
    PathTestCase("🚀_space/🌟_stars/moon.png",
                 "🚀_space/🌟_stars", "moon.png")
  ];

  foreach (tc; testCases) {
    const e = makeEntry(tc.relPath);
    recordAssertion(
      e.relPath == tc.relPath &&
      e.parentPath == tc.expectedParent &&
      e.name == tc.expectedName,
      "deriveEntryPath_test",
      format("relPath='%s' -> parent='%s', name='%s'",
             tc.relPath, e.parentPath, e.name)
    );
  }

  // Verify Entry fullPath derivation
  Entry eRoot = makeEntry(1, "usb_drive", ".");
  recordAssertion(
    eRoot.fullPath() == "usb_drive:/",
    "entry_fullPath_root",
    "usb_drive + '.' -> usb_drive:/"
  );

  Entry eSub = makeEntry(1, "usb_drive", "backup/data.zip");
  recordAssertion(
    eSub.fullPath() == "usb_drive:/backup/data.zip",
    "entry_fullPath_sub",
    "usb_drive + 'backup/data.zip' -> usb_drive:/backup/data.zip"
  );

  Entry eAnonymous = makeEntry("loose/file.txt");
  recordAssertion(
    eAnonymous.fullPath() == "loose/file.txt",
    "entry_fullPath_anonymous",
    "empty rootName -> 'loose/file.txt'"
  );

  Entry eAnonRoot = makeEntry(".");
  recordAssertion(
    eAnonRoot.fullPath() == "/",
    "entry_fullPath_anon_root",
    "empty rootName + '.' -> '/'"
  );
}

// ---------------------------------------------------------------------------
// Main Test Runner
// ---------------------------------------------------------------------------
void main() {
  writeln("==================================================================");
  writeln("      EMPIRICAL CHALLENGER M2: ZERO-ALLOC, PATTERN & MODEL TESTS  ");
  writeln("==================================================================");

  TempDir tempDir = TempDir("m2_stress");
  const string workDir = tempDir.path;
  const string dbPath = buildPath(workDir, "m2_stress.db");

  testZeroAllocationFastPaths();
  testBug16HashUnderscoreMatching(dbPath);
  testEmptyHashConsistency(workDir);
  testGroupDuplicatesStress();
  testMakeEntryAndDerivePath();

  writeln(
    "\n=================================================================="
  );
  writeln(format("Finished with %d assertions, %d failures.",
                 atomicLoad(g_assertions), atomicLoad(g_failures)));
  writeln("==================================================================");

  if (atomicLoad(g_failures) > 0) {
    import core.stdc.stdlib : exit;
    exit(1);
  }
}

unittest {
  main();
}
