module orglistremo.db.internal.sql;

import d2sqlite3 : Statement;
import orglistremo.model : EntryType, SortField;
import orglistremo.pattern :
  escapeLikeLiteral, hasGlobWildcard, hasPatternWildcard, isWildcard,
  unescapePatternEscapes, userPatternToLike;

package(orglistremo):

enum entrySelectSql = `
  SELECT
    e.id, e.root_id, r.name, e.rel_path, e.parent_path,
    e.name, e.is_dir, e.size, e.mtime, e.sha256
  FROM entries e
  JOIN roots r ON r.id = e.root_id
`;

void bindNullable(T)(ref Statement stmt, int index, bool hasVal, T val) {
  if (hasVal) {
    stmt.bind(index, val);
  } else {
    stmt.bind(index, null);
  }
}

string buildTypeFilterSql(EntryType typeFilter, string entryPrefix) {
  if (typeFilter == EntryType.file) {
    return " AND " ~ entryPrefix ~ "is_dir = 0";
  }
  if (typeFilter == EntryType.dir) {
    return " AND " ~ entryPrefix ~ "is_dir = 1";
  }
  return "";
}

string buildSubpathSql(
  string subpath,
  bool useGlob,
  string entryPrefix
) {
  const isPattern = useGlob
    ? hasGlobWildcard(subpath)
    : hasPatternWildcard(subpath);
  if (useGlob) {
    if (isPattern) {
      return entryPrefix ~ "rel_path GLOB ?";
    }
    return "(" ~ entryPrefix ~ "rel_path = ? OR " ~
      entryPrefix ~ "rel_path GLOB ?)";
  }
  if (isPattern) {
    return entryPrefix ~ "rel_path LIKE ? ESCAPE '\\'";
  }
  return "(" ~ entryPrefix ~ "rel_path = ? OR " ~
    entryPrefix ~ "rel_path LIKE ? ESCAPE '\\')";
}

string buildEntrySortSql(SortField sort, bool includeRootName) {
  const string rootOrder = includeRootName ? "r.name ASC, " : "";
  switch (sort) {
    case SortField.size:
      return " ORDER BY e.size DESC, " ~ rootOrder ~ "e.rel_path ASC";
    case SortField.mtime:
      return " ORDER BY e.mtime DESC, " ~ rootOrder ~ "e.rel_path ASC";
    case SortField.path:
    default:
      return " ORDER BY " ~ rootOrder ~ "e.rel_path ASC";
  }
}

void bindSubpath(
  ref Statement stmt,
  ref int idx,
  string subpath,
  bool useGlob
) {
  const isPattern = isWildcard(subpath, useGlob);
  if (useGlob) {
    if (isPattern) {
      stmt.bind(idx++, subpath);
    } else {
      stmt.bind(idx++, subpath);
      stmt.bind(idx++, subpath ~ "/*");
    }
  } else {
    if (isPattern) {
      stmt.bind(idx++, userPatternToLike(subpath));
    } else {
      const unescaped = unescapePatternEscapes(subpath);
      stmt.bind(idx++, unescaped);
      stmt.bind(idx++, escapeLikeLiteral(unescaped) ~ "/%");
    }
  }
}
