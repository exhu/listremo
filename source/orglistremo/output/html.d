module orglistremo.output.html;

import orglistremo.internal.assets : reportCss, reportJs;
import orglistremo.model :
  countEntries, DuplicateGroup, DuplicateStats, Entry, EntryStats, RootSummary,
  summarizeDuplicates;
import orglistremo.output.options : OutputOptions;
import orglistremo.output.units :
  formatHash, formatLastSync, formatSizeHuman, formatUnixTime;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.format : format;
import std.stdio : File, stdout;

void printHtmlRoots(
  in RootSummary[] summaries,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Roots");
  writePageHeader(
    outStream,
    "Storage Roots",
    format("%d root(s)", summaries.length)
  );

  if (summaries.length == 0) {
    outStream.writeln(`  <p class="empty">No storage roots registered.</p>`);
  } else {
    renderRootsTable(summaries, outStream);
  }

  writeHtmlDocFooter(outStream);
}

void printHtmlEntries(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Entries");

  const EntryStats stats = countEntries(entries);
  const string badgeText = format(
    "%d files, %d dirs (%s)",
    stats.fileCount,
    stats.dirCount,
    formatSizeHuman(stats.totalSize)
  );
  writeTreePageHeader(outStream, "Catalog Entries", badgeText);

  if (entries.length == 0) {
    outStream.writeln(`  <p class="empty">No entries found.</p>`);
  } else {
    renderEntryTrees(entries, options, outStream);
  }

  writeHtmlDocFooter(outStream);
}

void printHtmlDuplicates(
  in DuplicateGroup[] groups,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Duplicates");

  const DuplicateStats stats = summarizeDuplicates(groups);
  const string badgeText = format(
    "%d groups, %d duplicate copies (%s)",
    stats.groupCount,
    stats.duplicateCopies,
    formatSizeHuman(stats.duplicateBytes)
  );
  writeTreePageHeader(outStream, "Duplicate Entries", badgeText);

  if (groups.length == 0) {
    outStream.writeln(`  <p class="empty">No duplicate entries found.</p>`);
  } else {
    foreach (idx, ref const g; groups) {
      renderDuplicateGroup(g, idx + 1, HtmlWriter(outStream, options));
    }
  }

  writeHtmlDocFooter(outStream);
}

void printHtmlUnique(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Unique Entries");

  const EntryStats stats = countEntries(entries);
  const string badgeText = format(
    "%d unique (%d files, %d dirs, %s)",
    entries.length,
    stats.fileCount,
    stats.dirCount,
    formatSizeHuman(stats.totalSize)
  );
  writeTreePageHeader(outStream, "Unique Entries", badgeText);

  if (entries.length == 0) {
    outStream.writeln(`  <p class="empty">No unique entries found.</p>`);
  } else {
    renderEntryTrees(entries, options, outStream);
  }

  writeHtmlDocFooter(outStream);
}

string escapeHtml(string s) {
  bool needsEscape = false;
  foreach (const char c; s) {
    if (c == '&' || c == '<' || c == '>' || c == '"' || c == '\'') {
      needsEscape = true;
      break;
    }
  }
  if (!needsEscape) {
    return s;
  }

  Appender!string app = appender!string();
  foreach (const char c; s) {
    switch (c) {
      case '&':
        app.put("&amp;");
        break;
      case '<':
        app.put("&lt;");
        break;
      case '>':
        app.put("&gt;");
        break;
      case '"':
        app.put("&quot;");
        break;
      case '\'':
        app.put("&#39;");
        break;
      default:
        app.put(c);
        break;
    }
  }
  return app.data;
}

private:

struct HtmlWriter {
  File outStream;
  OutputOptions options;
}

final class HtmlTreeNode {
  this(string name, bool isDir) {
    this.name = name;
    this.isDir = isDir;
  }

  void setMeta(in Entry e) {
    this.size = e.size;
    this.mtime = e.mtime;
    this.sha256 = e.sha256;
    this.hasMeta = true;
  }

  HtmlTreeNode getOrCreateDir(string dirName) {
    if (const idx = dirName in dirIndexByName) {
      return dirs[*idx];
    }
    HtmlTreeNode newNode = new HtmlTreeNode(dirName, true);
    const size_t newIdx = dirs.length;
    dirs ~= newNode;
    dirIndexByName[dirName] = newIdx;
    return newNode;
  }

  void addFile(HtmlTreeNode fileNode) {
    files ~= fileNode;
  }

  void sortChildren() {
    dirs.sort!((a, b) => a.name < b.name);
    files.sort!((a, b) => a.name < b.name);
    foreach (d; dirs) {
      d.sortChildren();
    }
  }

  string name;
  bool isDir;
  ulong size;
  long mtime;
  string sha256;
  bool hasMeta;
  HtmlTreeNode[] dirs;
  HtmlTreeNode[] files;

private:
  size_t[string] dirIndexByName;
}

struct HtmlTreeRoot {
  string rootName;
  HtmlTreeNode rootNode;
}

void writePageHeader(File outStream, string title, string badgeText) {
  outStream.writeln(`  <div class="header">`);
  outStream.writefln(`    <h1 class="title">%s</h1>`, escapeHtml(title));
  outStream.writefln(
    `    <span class="badge">%s</span>`,
    escapeHtml(badgeText)
  );
  outStream.writeln(`  </div>`);
}

void writeTreePageHeader(File outStream, string title, string badgeText) {
  outStream.writeln(`  <div class="header">`);
  outStream.writefln(`    <h1 class="title">%s</h1>`, escapeHtml(title));
  outStream.writeln(`    <div class="toolbar">`);
  outStream.writefln(
    `      <span class="badge">%s</span>`,
    escapeHtml(badgeText)
  );
  outStream.writeln(
    `      <button type="button" class="btn" ` ~
    `onclick="toggleAll(true)">Expand All</button>`
  );
  outStream.writeln(
    `      <button type="button" class="btn" ` ~
    `onclick="toggleAll(false)">Collapse All</button>`
  );
  outStream.writeln(`    </div>`);
  outStream.writeln(`  </div>`);
}

void renderRootsTable(in RootSummary[] summaries, File outStream) {
  outStream.writeln(`  <table class="roots-table">`);
  outStream.writeln(`    <thead><tr>`);
  outStream.writeln(`      <th>NAME</th>`);
  outStream.writeln(`      <th>PATH</th>`);
  outStream.writeln(`      <th>LAST SYNC</th>`);
  outStream.writeln(`      <th style="text-align:right">FILES</th>`);
  outStream.writeln(`      <th style="text-align:right">DIRS</th>`);
  outStream.writeln(`      <th style="text-align:right">TOTAL SIZE</th>`);
  outStream.writeln(`      <th style="text-align:right">FREE SPACE</th>`);
  outStream.writeln(`    </tr></thead>`);
  outStream.writeln(`    <tbody>`);

  foreach (ref const s; summaries) {
    renderRootRow(s, outStream);
  }

  outStream.writeln(`    </tbody>`);
  outStream.writeln(`  </table>`);
}

void renderRootRow(in RootSummary s, File outStream) {
  const string syncStr = formatLastSync(s.root.lastSync, s.root.hasLastSync);
  const string freeStr = s.root.hasFreeSpace
    ? formatSizeHuman(s.root.freeSpace)
    : "-";
  outStream.writeln(`      <tr>`);
  outStream.writefln(
    `        <td><strong>%s</strong></td>`, escapeHtml(s.root.name)
  );
  outStream.writefln(
    `        <td><code>%s</code></td>`, escapeHtml(s.root.path)
  );
  outStream.writefln(`        <td>%s</td>`, escapeHtml(syncStr));
  outStream.writefln(
    `        <td style="text-align:right">%d</td>`, s.fileCount
  );
  outStream.writefln(
    `        <td style="text-align:right">%d</td>`, s.dirCount
  );
  outStream.writefln(
    `        <td style="text-align:right">%s</td>`,
    escapeHtml(formatSizeHuman(s.totalSize))
  );
  outStream.writefln(
    `        <td style="text-align:right">%s</td>`, escapeHtml(freeStr)
  );
  outStream.writeln(`      </tr>`);
}

void renderDuplicateGroup(
  in DuplicateGroup g,
  size_t groupNum,
  HtmlWriter writer
) {
  const string typeStr = g.isDir ? "DIR" : "FILE";
  const string hStr = formatHash(g.sha256, writer.options.fullHash);
  const string sizeStr = formatSizeHuman(g.size);
  File outStream = writer.outStream;

  outStream.writeln(`  <details class="tree-dir dup-group" open>`);
  outStream.writeln(`    <summary class="dir-summary">`);
  outStream.writeln(`      <span class="chevron">&#9654;</span>`);
  outStream.writefln(
    `      <span class="name">[%s] Group %d: ` ~
    `<span class="hash-text" title="%s">%s</span></span>`,
    typeStr, groupNum, escapeHtml(g.sha256), escapeHtml(hStr)
  );
  outStream.writeln(`      <span class="meta">`);
  outStream.writefln(
    `        <span class="meta-size">%s</span>`, escapeHtml(sizeStr)
  );
  outStream.writefln(
    `        <span class="meta-copies">%d copies</span>`, g.entries.length
  );
  outStream.writeln(`      </span>`);
  outStream.writeln(`    </summary>`);
  outStream.writeln(`    <div class="dup-content">`);
  renderEntryTrees(g.entries, writer.options, outStream);
  outStream.writeln(`    </div>`);
  outStream.writeln(`  </details>`);
}

void renderEntryTrees(
  in Entry[] entries,
  in OutputOptions options,
  File outStream
) {
  HtmlTreeRoot[] trees = buildHtmlTree(entries);
  foreach (ref const tree; trees) {
    renderTreeRoot(tree, options, outStream);
  }
}

HtmlTreeRoot[] buildHtmlTree(in Entry[] entries) {
  HtmlTreeNode[string] rootMap;
  string[] rootOrder;

  foreach (ref const e; entries) {
    const string rName = e.rootName.length > 0 ? e.rootName : "/";
    if (rName !in rootMap) {
      rootMap[rName] = new HtmlTreeNode(rName, true);
      rootOrder ~= rName;
    }
    HtmlTreeNode rootNode = rootMap[rName];

    if (e.relPath == "." || e.relPath.length == 0) {
      rootNode.setMeta(e);
      continue;
    }

    insertEntry(rootNode, e);
  }

  HtmlTreeRoot[] result;
  foreach (rName; rootOrder) {
    HtmlTreeNode rootNode = rootMap[rName];
    rootNode.sortChildren();
    result ~= HtmlTreeRoot(rName, rootNode);
  }
  return result;
}

void insertEntry(HtmlTreeNode rootNode, in Entry e) {
  const string[] parts = splitPath(e.relPath);
  if (parts.length == 0) {
    return;
  }

  HtmlTreeNode current = rootNode;
  for (size_t i = 0; i + 1 < parts.length; i++) {
    current = current.getOrCreateDir(parts[i]);
  }

  const string lastName = parts[$ - 1];
  if (e.isDir) {
    HtmlTreeNode dirNode = current.getOrCreateDir(lastName);
    dirNode.setMeta(e);
  } else {
    HtmlTreeNode fileNode = new HtmlTreeNode(lastName, false);
    fileNode.setMeta(e);
    current.addFile(fileNode);
  }
}

string[] splitPath(string p) {
  string[] parts;
  size_t start = 0;
  while (start < p.length && p[start] == '/') {
    start++;
  }
  for (size_t i = start; i < p.length; i++) {
    if (p[i] == '/') {
      if (i > start) {
        parts ~= p[start .. i];
      }
      start = i + 1;
    }
  }
  if (start < p.length) {
    parts ~= p[start .. $];
  }
  return parts;
}

void renderTreeRoot(
  in HtmlTreeRoot tree,
  in OutputOptions options,
  File outStream
) {
  outStream.writeln(`  <div class="root-tree">`);
  outStream.writeln(`    <details class="tree-dir" open>`);
  outStream.writeln(`      <summary class="dir-summary">`);
  outStream.writeln(`        <span class="chevron">&#9654;</span>`);
  outStream.writeln(`        <span class="icon">&#128193;</span>`);
  outStream.writefln(
    `        <span class="name"><strong>%s:/</strong></span>`,
    escapeHtml(tree.rootName)
  );

  renderNodeMeta(tree.rootNode, options, outStream);

  outStream.writeln(`      </summary>`);
  outStream.writeln(`      <ul class="tree-children">`);

  foreach (d; tree.rootNode.dirs) {
    renderDirectoryNode(d, options, outStream);
  }
  foreach (f; tree.rootNode.files) {
    renderFileLeaf(f, options, outStream);
  }

  outStream.writeln(`      </ul>`);
  outStream.writeln(`    </details>`);
  outStream.writeln(`  </div>`);
}

void renderDirectoryNode(
  in HtmlTreeNode node,
  in OutputOptions options,
  File outStream
) {
  outStream.writeln(`        <li class="tree-node">`);
  outStream.writeln(`          <details class="tree-dir" open>`);
  outStream.writeln(`            <summary class="dir-summary">`);
  outStream.writeln(`              <span class="chevron">&#9654;</span>`);
  outStream.writeln(`              <span class="icon">&#128193;</span>`);
  outStream.writefln(
    `              <span class="name">%s</span>`,
    escapeHtml(node.name)
  );

  renderNodeMeta(node, options, outStream);

  outStream.writeln(`            </summary>`);
  outStream.writeln(`            <ul class="tree-children">`);

  foreach (d; node.dirs) {
    renderDirectoryNode(d, options, outStream);
  }
  foreach (f; node.files) {
    renderFileLeaf(f, options, outStream);
  }

  outStream.writeln(`            </ul>`);
  outStream.writeln(`          </details>`);
  outStream.writeln(`        </li>`);
}

void renderFileLeaf(
  in HtmlTreeNode node,
  in OutputOptions options,
  File outStream
) {
  outStream.writeln(`        <li class="tree-leaf">`);
  outStream.writeln(`          <div class="tree-file">`);
  outStream.writeln(`            <span class="spacer"></span>`);
  outStream.writeln(`            <span class="icon">&#128196;</span>`);
  outStream.writefln(
    `            <span class="name">%s</span>`,
    escapeHtml(node.name)
  );

  renderNodeMeta(node, options, outStream);

  outStream.writeln(`          </div>`);
  outStream.writeln(`        </li>`);
}

void renderNodeMeta(
  in HtmlTreeNode node,
  in OutputOptions options,
  File outStream
) {
  outStream.writeln(`            <span class="meta">`);
  if (node.hasMeta) {
    const string sizeStr = formatSizeHuman(node.size);
    const string mtimeStr = formatUnixTime(node.mtime);
    const string hStr = formatHash(node.sha256, options.fullHash);
    outStream.writefln(
      `              <span class="meta-size">%s</span>`,
      escapeHtml(sizeStr)
    );
    outStream.writefln(
      `              <span class="meta-mtime">%s</span>`,
      escapeHtml(mtimeStr)
    );
    outStream.writefln(
      `              <span class="meta-hash" title="%s">%s</span>`,
      escapeHtml(node.sha256), escapeHtml(hStr)
    );
  } else {
    outStream.writeln(`              <span class="meta-size">-</span>`);
    outStream.writeln(`              <span class="meta-mtime">-</span>`);
    outStream.writeln(`              <span class="meta-hash">-</span>`);
  }
  outStream.writeln(`            </span>`);
}

void writeHtmlDocHeader(File outStream, string pageTitle) {
  outStream.writeln(`<!DOCTYPE html>`);
  outStream.writeln(`<html lang="en">`);
  outStream.writeln(`<head>`);
  outStream.writeln(`  <meta charset="utf-8">`);
  outStream.writeln(
    `  <meta name="viewport" content="width=device-width, initial-scale=1">`
  );
  outStream.writefln(`  <title>%s</title>`, escapeHtml(pageTitle));
  outStream.writeln(`  <style>`);
  writeHtmlStyles(outStream);
  outStream.writeln(`  </style>`);
  outStream.writeln(`</head>`);
  outStream.writeln(`<body>`);
  outStream.writeln(`  <div class="container">`);
}

void writeHtmlDocFooter(File outStream) {
  outStream.writeln(`  </div>`);
  outStream.writeln(`  <script>`);
  writeHtmlScript(outStream);
  outStream.writeln(`  </script>`);
  outStream.writeln(`</body>`);
  outStream.writeln(`</html>`);
}

void writeHtmlStyles(File outStream) {
  outStream.write(reportCss);
}

void writeHtmlScript(File outStream) {
  outStream.write(reportJs);
}

unittest {
  // Test escapeHtml
  assert(escapeHtml("hello") == "hello");
  assert(escapeHtml("<b>\"one\" & 'two'</b>") ==
    "&lt;b&gt;&quot;one&quot; &amp; &#39;two&#39;&lt;/b&gt;");

  // Test splitPath
  assert(splitPath("a/b/c") == ["a", "b", "c"]);
  assert(splitPath("/a/b/c/") == ["a", "b", "c"]);
  assert(splitPath("file.txt") == ["file.txt"]);

  // Test buildHtmlTree
  Entry[] entries = [
    Entry(1, 1, "r1", ".", null, "r1", true, 1000, 100, "dir_hash"),
    Entry(2, 1, "r1", "docs", ".", "docs", true, 600, 100, "docs_hash"),
    Entry(
      3, 1, "r1", "docs/a.txt", "docs", "a.txt", false, 300, 100, "a_hash"
    ),
    Entry(
      4, 1, "r1", "docs/b.txt", "docs", "b.txt", false, 300, 100, "b_hash"
    ),
    Entry(
      5, 1, "r1", "root_file.txt", ".", "root_file.txt", false, 400, 100, "rf"
    )
  ];

  HtmlTreeRoot[] trees = buildHtmlTree(entries);
  assert(trees.length == 1);
  assert(trees[0].rootName == "r1");
  assert(trees[0].rootNode.dirs.length == 1);
  assert(trees[0].rootNode.dirs[0].name == "docs");
  assert(trees[0].rootNode.dirs[0].files.length == 2);
  assert(trees[0].rootNode.dirs[0].files[0].name == "a.txt");
  assert(trees[0].rootNode.dirs[0].files[1].name == "b.txt");
  assert(trees[0].rootNode.files.length == 1);
  assert(trees[0].rootNode.files[0].name == "root_file.txt");

  // Test rendering functions with captureOutput
  import orglistremo.internal.testutil : captureOutput;
  import orglistremo.model : Root;
  import std.string : indexOf;

  OutputOptions opts;
  opts.fullHash = false;

  const entriesContent = captureOutput((File f) {
    printHtmlEntries(entries, opts, f);
  });
  assert(entriesContent.indexOf("<!DOCTYPE html>") != -1);
  assert(entriesContent.indexOf("class=\"tree-dir\"") != -1);
  assert(entriesContent.indexOf("class=\"tree-file\"") != -1);
  assert(entriesContent.indexOf("a.txt") != -1);
  assert(entriesContent.indexOf("docs") != -1);

  // Test printHtmlRoots
  Root r;
  r.name = "backup";
  r.path = "/mnt/backup";
  r.hasLastSync = true;
  r.lastSync = 1700000000;
  r.hasFreeSpace = true;
  r.freeSpace = 1024 * 1024 * 500;
  RootSummary[] roots = [RootSummary(r, 10, 2, 1024 * 1024 * 50)];

  const rootsContent = captureOutput((File f) {
    printHtmlRoots(roots, opts, f);
  });
  assert(rootsContent.indexOf("roots-table") != -1);
  assert(rootsContent.indexOf("backup") != -1);

  // Test printHtmlDuplicates
  DuplicateGroup dg;
  dg.sha256 = "dup_hash_123456789";
  dg.size = 300;
  dg.isDir = false;
  dg.entries = [entries[2], entries[3]];
  DuplicateGroup[] dups = [dg];

  const dupsContent = captureOutput((File f) {
    printHtmlDuplicates(dups, opts, f);
  });
  assert(dupsContent.indexOf("dup-group") != -1);
  assert(dupsContent.indexOf("dup_hash_123456789") != -1);

  // Test printHtmlUnique
  const uniqContent = captureOutput((File f) {
    printHtmlUnique(entries[2 .. 4], opts, f);
  });
  assert(uniqContent.indexOf("Unique Entries") != -1);

  // Fast path (no special chars)
  assert(escapeHtml("plain_name.txt") == "plain_name.txt");

  // ASCII special characters
  assert(escapeHtml("<b>\"one\" & 'two'</b>") ==
    "&lt;b&gt;&quot;one&quot; &amp; &#39;two&#39;&lt;/b&gt;");

  // Multibyte UTF-8 characters preserved intact
  assert(escapeHtml("<тест> & '日本語'") ==
    "&lt;тест&gt; &amp; &#39;日本語&#39;");

  // Invalid non-UTF-8 bytes do not throw UnicodeException
  const string invalidBytes = cast(string) [
    cast(char) 0xFF, '<', cast(char) 0xFE, '&', cast(char) 0x80
  ];
  const string escapedInvalid = escapeHtml(invalidBytes);
  assert(escapedInvalid == cast(string) [cast(char) 0xFF] ~ "&lt;" ~
    cast(string) [cast(char) 0xFE] ~ "&amp;" ~ cast(string) [cast(char) 0x80]);
}
