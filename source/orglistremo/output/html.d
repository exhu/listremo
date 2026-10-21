module orglistremo.output.html;

import orglistremo.model : DuplicateGroup, Entry, RootSummary;
import orglistremo.output.console : OutputOptions;
import orglistremo.output.units :
  formatDuration, formatIso8601, formatSizeHuman, formatUnixTime;
import std.algorithm.sorting : sort;
import std.array : appender;
import std.format : format;
import std.stdio : File, stdout;

void printHtmlRoots(
  in RootSummary[] summaries,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Roots");
  outStream.writeln(`  <div class="header">`);
  outStream.writeln(`    <h1 class="title">Storage Roots</h1>`);
  outStream.writefln(
    `    <span class="badge">%d root(s)</span>`,
    summaries.length
  );
  outStream.writeln(`  </div>`);

  if (summaries.length == 0) {
    outStream.writeln(`  <p class="empty">No storage roots registered.</p>`);
  } else {
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

    foreach (ref s; summaries) {
      const syncStr = s.root.hasLastSync
        ? formatUnixTime(s.root.lastSync)
        : "never";
      const freeStr = s.root.hasFreeSpace
        ? formatSizeHuman(s.root.freeSpace)
        : "-";
      outStream.writeln(`      <tr>`);
      outStream.writefln(`        <td><strong>%s</strong></td>`,
        escapeHtml(s.root.name));
      outStream.writefln(`        <td><code>%s</code></td>`,
        escapeHtml(s.root.path));
      outStream.writefln(`        <td>%s</td>`, escapeHtml(syncStr));
      outStream.writefln(`        <td style="text-align:right">%d</td>`,
        s.fileCount);
      outStream.writefln(`        <td style="text-align:right">%d</td>`,
        s.dirCount);
      outStream.writefln(`        <td style="text-align:right">%s</td>`,
        escapeHtml(formatSizeHuman(s.totalSize)));
      outStream.writefln(`        <td style="text-align:right">%s</td>`,
        escapeHtml(freeStr));
      outStream.writeln(`      </tr>`);
    }

    outStream.writeln(`    </tbody>`);
    outStream.writeln(`  </table>`);
  }

  writeHtmlDocFooter(outStream);
}

void printHtmlEntries(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Entries");

  size_t fileCount = 0;
  size_t dirCount = 0;
  ulong totalSize = 0;
  foreach (ref e; entries) {
    if (e.isDir) {
      dirCount++;
    } else {
      fileCount++;
      totalSize += e.size;
    }
  }

  outStream.writeln(`  <div class="header">`);
  outStream.writeln(`    <h1 class="title">Catalog Entries</h1>`);
  outStream.writeln(`    <div class="toolbar">`);
  outStream.writefln(
    `      <span class="badge">%d files, %d dirs (%s)</span>`,
    fileCount, dirCount, formatSizeHuman(totalSize)
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

  if (entries.length == 0) {
    outStream.writeln(`  <p class="empty">No entries found.</p>`);
  } else {
    HtmlTreeRoot[] trees = buildHtmlTree(entries);
    foreach (tree; trees) {
      renderTreeRoot(tree, options, outStream);
    }
  }

  writeHtmlDocFooter(outStream);
}

void printHtmlDuplicates(
  in DuplicateGroup[] groups,
  in OutputOptions options,
  File outStream = stdout
) {
  writeHtmlDocHeader(outStream, "listremo - Duplicates");

  size_t totalDupCopies = 0;
  ulong totalDupBytes = 0;
  foreach (ref g; groups) {
    const copies = g.entries.length;
    if (copies > 1) {
      totalDupCopies += (copies - 1);
      totalDupBytes += (copies - 1) * g.size;
    }
  }

  outStream.writeln(`  <div class="header">`);
  outStream.writeln(`    <h1 class="title">Duplicate Entries</h1>`);
  outStream.writeln(`    <div class="toolbar">`);
  outStream.writefln(
    `      <span class="badge">%d groups, %d duplicate copies (%s)</span>`,
    groups.length, totalDupCopies, formatSizeHuman(totalDupBytes)
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

  if (groups.length == 0) {
    outStream.writeln(`  <p class="empty">No duplicate entries found.</p>`);
  } else {
    foreach (idx, ref g; groups) {
      const typeStr = g.isDir ? "DIR" : "FILE";
      const hStr = formatHash(g.sha256, options.fullHash);
      const sizeStr = formatSizeHuman(g.size);

      outStream.writeln(`  <details class="tree-dir dup-group" open>`);
      outStream.writeln(`    <summary class="dir-summary">`);
      outStream.writeln(`      <span class="chevron">&#9654;</span>`);
      outStream.writefln(
        `      <span class="name">[%s] Group %d: ` ~
        `<span class="hash-text" title="%s">%s</span></span>`,
        typeStr, idx + 1, escapeHtml(g.sha256), escapeHtml(hStr)
      );
      outStream.writeln(`      <span class="meta">`);
      outStream.writefln(
        `        <span class="meta-size">%s</span>`,
        escapeHtml(sizeStr)
      );
      outStream.writefln(
        `        <span class="meta-copies">%d copies</span>`,
        g.entries.length
      );
      outStream.writeln(`      </span>`);
      outStream.writeln(`    </summary>`);
      outStream.writeln(`    <div class="dup-content">`);

      HtmlTreeRoot[] trees = buildHtmlTree(g.entries);
      foreach (tree; trees) {
        renderTreeRoot(tree, options, outStream);
      }

      outStream.writeln(`    </div>`);
      outStream.writeln(`  </details>`);
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

  size_t fileCount = 0;
  size_t dirCount = 0;
  ulong totalSize = 0;
  foreach (ref e; entries) {
    if (e.isDir) {
      dirCount++;
    } else {
      fileCount++;
      totalSize += e.size;
    }
  }

  outStream.writeln(`  <div class="header">`);
  outStream.writeln(`    <h1 class="title">Unique Entries</h1>`);
  outStream.writeln(`    <div class="toolbar">`);
  outStream.writefln(
    `      <span class="badge">%d unique (%d files, %d dirs, %s)</span>`,
    entries.length, fileCount, dirCount, formatSizeHuman(totalSize)
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

  if (entries.length == 0) {
    outStream.writeln(`  <p class="empty">No unique entries found.</p>`);
  } else {
    HtmlTreeRoot[] trees = buildHtmlTree(entries);
    foreach (tree; trees) {
      renderTreeRoot(tree, options, outStream);
    }
  }

  writeHtmlDocFooter(outStream);
}

string escapeHtml(string s) {
  auto app = appender!string();
  foreach (dchar c; s) {
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

final class HtmlTreeNode {
  string name;
  bool isDir;
  ulong size;
  long mtime;
  string sha256;
  bool hasMeta;

  HtmlTreeNode[] dirs;
  HtmlTreeNode[] files;

  this(string name, bool isDir) {
    this.name = name;
    this.isDir = isDir;
  }

  HtmlTreeNode getOrCreateDir(string dirName) {
    if (const idx = dirName in dirIndexByName) {
      return dirs[*idx];
    }
    HtmlTreeNode newNode = new HtmlTreeNode(dirName, true);
    const newIdx = dirs.length;
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

private:
  size_t[string] dirIndexByName;
}

struct HtmlTreeRoot {
  string rootName;
  HtmlTreeNode rootNode;
}

HtmlTreeRoot[] buildHtmlTree(in Entry[] entries) {
  HtmlTreeNode[string] rootMap;
  string[] rootOrder;

  foreach (ref e; entries) {
    const rName = e.rootName.length > 0 ? e.rootName : "/";
    if (rName !in rootMap) {
      rootMap[rName] = new HtmlTreeNode(rName, true);
      rootOrder ~= rName;
    }
    HtmlTreeNode rootNode = rootMap[rName];

    if (e.relPath == "." || e.relPath.length == 0) {
      rootNode.size = e.size;
      rootNode.mtime = e.mtime;
      rootNode.sha256 = e.sha256;
      rootNode.hasMeta = true;
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
  string[] parts = splitPath(e.relPath);
  if (parts.length == 0) {
    return;
  }

  HtmlTreeNode current = rootNode;
  for (size_t i = 0; i + 1 < parts.length; i++) {
    current = current.getOrCreateDir(parts[i]);
  }

  const lastName = parts[$ - 1];
  if (e.isDir) {
    HtmlTreeNode dirNode = current.getOrCreateDir(lastName);
    dirNode.size = e.size;
    dirNode.mtime = e.mtime;
    dirNode.sha256 = e.sha256;
    dirNode.hasMeta = true;
  } else {
    HtmlTreeNode fileNode = new HtmlTreeNode(lastName, false);
    fileNode.size = e.size;
    fileNode.mtime = e.mtime;
    fileNode.sha256 = e.sha256;
    fileNode.hasMeta = true;
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

string formatHash(string h, bool fullHash) {
  if (fullHash || h == "0" || h.length <= 12) {
    return h;
  }
  return h[0 .. 12];
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
    const sizeStr = formatSizeHuman(node.size);
    const mtimeStr = formatUnixTime(node.mtime);
    const hStr = formatHash(node.sha256, options.fullHash);
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
  outStream.writeln(`  function toggleAll(open) {`);
  outStream.writeln(`    document.querySelectorAll('details').forEach(`);
  outStream.writeln(`      function(d) { d.open = open; }`);
  outStream.writeln(`    );`);
  outStream.writeln(`  }`);
  outStream.writeln(`  </script>`);
  outStream.writeln(`</body>`);
  outStream.writeln(`</html>`);
}

void writeHtmlStyles(File outStream) {
  outStream.writeln(`    :root {`);
  outStream.writeln(`      --bg: #f6f8fa;`);
  outStream.writeln(`      --card-bg: #ffffff;`);
  outStream.writeln(`      --border: #d0d7de;`);
  outStream.writeln(`      --text: #1f2328;`);
  outStream.writeln(`      --text-muted: #656d76;`);
  outStream.writeln(`      --hover-bg: #f3f4f6;`);
  outStream.writeln(`      --btn-bg: #f6f8fa;`);
  outStream.writeln(`      --btn-border: #d0d7de;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    @media (prefers-color-scheme: dark) {`);
  outStream.writeln(`      :root {`);
  outStream.writeln(`        --bg: #0d1117;`);
  outStream.writeln(`        --card-bg: #161b22;`);
  outStream.writeln(`        --border: #30363d;`);
  outStream.writeln(`        --text: #e6edf3;`);
  outStream.writeln(`        --text-muted: #8b949e;`);
  outStream.writeln(`        --hover-bg: #21262d;`);
  outStream.writeln(`        --btn-bg: #21262d;`);
  outStream.writeln(`        --btn-border: #30363d;`);
  outStream.writeln(`      }`);
  outStream.writeln(`    }`);
  outStream.writeln(`    body {`);
  outStream.writeln(`      margin: 0;`);
  outStream.writeln(`      padding: 1.5rem;`);
  outStream.writeln(`      background-color: var(--bg);`);
  outStream.writeln(`      color: var(--text);`);
  outStream.writeln(
    `      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", ` ~
    `Helvetica, Arial, sans-serif;`
  );
  outStream.writeln(`      font-size: 14px;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .container {`);
  outStream.writeln(`      max-width: 1200px;`);
  outStream.writeln(`      margin: 0 auto;`);
  outStream.writeln(`      background-color: var(--card-bg);`);
  outStream.writeln(`      border: 1px solid var(--border);`);
  outStream.writeln(`      border-radius: 6px;`);
  outStream.writeln(`      padding: 1rem 1.5rem;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .header {`);
  outStream.writeln(`      display: flex;`);
  outStream.writeln(`      justify-content: space-between;`);
  outStream.writeln(`      align-items: center;`);
  outStream.writeln(`      margin-bottom: 1rem;`);
  outStream.writeln(`      padding-bottom: 0.75rem;`);
  outStream.writeln(`      border-bottom: 1px solid var(--border);`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .title {`);
  outStream.writeln(`      font-size: 1.25rem;`);
  outStream.writeln(`      font-weight: 600;`);
  outStream.writeln(`      margin: 0;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .badge {`);
  outStream.writeln(`      display: inline-block;`);
  outStream.writeln(`      padding: 2px 8px;`);
  outStream.writeln(`      font-size: 12px;`);
  outStream.writeln(`      background-color: var(--hover-bg);`);
  outStream.writeln(`      border: 1px solid var(--border);`);
  outStream.writeln(`      border-radius: 12px;`);
  outStream.writeln(`      color: var(--text-muted);`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .toolbar {`);
  outStream.writeln(`      display: flex;`);
  outStream.writeln(`      gap: 0.5rem;`);
  outStream.writeln(`      align-items: center;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .btn {`);
  outStream.writeln(`      background-color: var(--btn-bg);`);
  outStream.writeln(`      border: 1px solid var(--btn-border);`);
  outStream.writeln(`      color: var(--text);`);
  outStream.writeln(`      padding: 4px 10px;`);
  outStream.writeln(`      border-radius: 4px;`);
  outStream.writeln(`      cursor: pointer;`);
  outStream.writeln(`      font-size: 13px;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .btn:hover {`);
  outStream.writeln(`      background-color: var(--hover-bg);`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .tree-children {`);
  outStream.writeln(`      list-style: none;`);
  outStream.writeln(`      margin: 0;`);
  outStream.writeln(`      padding-left: 1.25rem;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .tree-node, .tree-leaf {`);
  outStream.writeln(`      margin: 2px 0;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .dir-summary, .tree-file {`);
  outStream.writeln(`      display: flex;`);
  outStream.writeln(`      align-items: center;`);
  outStream.writeln(`      padding: 3px 6px;`);
  outStream.writeln(`      border-radius: 4px;`);
  outStream.writeln(`      user-select: none;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .dir-summary {`);
  outStream.writeln(`      cursor: pointer;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .dir-summary:hover, .tree-file:hover {`);
  outStream.writeln(`      background-color: var(--hover-bg);`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .dir-summary::-webkit-details-marker {`);
  outStream.writeln(`      display: none;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .chevron {`);
  outStream.writeln(`      display: inline-block;`);
  outStream.writeln(`      width: 1.2rem;`);
  outStream.writeln(`      font-size: 0.7rem;`);
  outStream.writeln(`      color: var(--text-muted);`);
  outStream.writeln(`      transition: transform 0.15s ease;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    details[open] > summary > .chevron {`);
  outStream.writeln(`      transform: rotate(90deg);`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .spacer {`);
  outStream.writeln(`      display: inline-block;`);
  outStream.writeln(`      width: 1.2rem;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .icon {`);
  outStream.writeln(`      margin-right: 0.4rem;`);
  outStream.writeln(`      font-size: 1rem;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .name {`);
  outStream.writeln(
    `      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, ` ~
    `Consolas, monospace;`
  );
  outStream.writeln(`      font-weight: 500;`);
  outStream.writeln(`      flex: 1;`);
  outStream.writeln(`      word-break: break-all;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .meta {`);
  outStream.writeln(`      display: flex;`);
  outStream.writeln(`      gap: 1rem;`);
  outStream.writeln(
    `      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, ` ~
    `Consolas, monospace;`
  );
  outStream.writeln(`      font-size: 12px;`);
  outStream.writeln(`      color: var(--text-muted);`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .meta-size {`);
  outStream.writeln(`      width: 90px;`);
  outStream.writeln(`      text-align: right;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .meta-mtime {`);
  outStream.writeln(`      width: 160px;`);
  outStream.writeln(`      text-align: center;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .meta-hash {`);
  outStream.writeln(`      width: 110px;`);
  outStream.writeln(`      text-align: right;`);
  outStream.writeln(`      font-variant-numeric: tabular-nums;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .meta-copies {`);
  outStream.writeln(`      width: 80px;`);
  outStream.writeln(`      text-align: right;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .dup-group {`);
  outStream.writeln(`      margin-bottom: 0.75rem;`);
  outStream.writeln(`      border: 1px solid var(--border);`);
  outStream.writeln(`      border-radius: 6px;`);
  outStream.writeln(`      padding: 0.5rem;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .dup-content {`);
  outStream.writeln(`      padding-top: 0.5rem;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    .empty {`);
  outStream.writeln(`      color: var(--text-muted);`);
  outStream.writeln(`      font-style: italic;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    table.roots-table {`);
  outStream.writeln(`      width: 100%;`);
  outStream.writeln(`      border-collapse: collapse;`);
  outStream.writeln(`      font-size: 13px;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    table.roots-table th, table.roots-table td {`);
  outStream.writeln(`      padding: 8px 12px;`);
  outStream.writeln(`      border-bottom: 1px solid var(--border);`);
  outStream.writeln(`      text-align: left;`);
  outStream.writeln(`    }`);
  outStream.writeln(`    table.roots-table th {`);
  outStream.writeln(`      background-color: var(--hover-bg);`);
  outStream.writeln(`      font-weight: 600;`);
  outStream.writeln(`    }`);
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

  // Test formatHash
  assert(formatHash("0", false) == "0");
  assert(formatHash("abcdef0123456789", false) == "abcdef012345");
  assert(formatHash("abcdef0123456789", true) == "abcdef0123456789");

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

  // Test rendering functions with File.tmpfile()
  import orglistremo.model : Root;
  import std.string : indexOf;

  OutputOptions opts;
  opts.fullHash = false;

  File tmpEntries = File.tmpfile();
  printHtmlEntries(entries, opts, tmpEntries);
  tmpEntries.rewind();
  string entriesContent;
  foreach (line; tmpEntries.byLine()) {
    entriesContent ~= line ~ "\n";
  }
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

  File tmpRoots = File.tmpfile();
  printHtmlRoots(roots, opts, tmpRoots);
  tmpRoots.rewind();
  string rootsContent;
  foreach (line; tmpRoots.byLine()) {
    rootsContent ~= line ~ "\n";
  }
  assert(rootsContent.indexOf("roots-table") != -1);
  assert(rootsContent.indexOf("backup") != -1);

  // Test printHtmlDuplicates
  DuplicateGroup dg;
  dg.sha256 = "dup_hash_123456789";
  dg.size = 300;
  dg.isDir = false;
  dg.entries = [entries[2], entries[3]];
  DuplicateGroup[] dups = [dg];

  File tmpDups = File.tmpfile();
  printHtmlDuplicates(dups, opts, tmpDups);
  tmpDups.rewind();
  string dupsContent;
  foreach (line; tmpDups.byLine()) {
    dupsContent ~= line ~ "\n";
  }
  assert(dupsContent.indexOf("dup-group") != -1);
  assert(dupsContent.indexOf("dup_hash_123456789") != -1);

  // Test printHtmlUnique
  File tmpUniq = File.tmpfile();
  printHtmlUnique(entries[2 .. 4], opts, tmpUniq);
  tmpUniq.rewind();
  string uniqContent;
  foreach (line; tmpUniq.byLine()) {
    uniqContent ~= line ~ "\n";
  }
  assert(uniqContent.indexOf("Unique Entries") != -1);
}
