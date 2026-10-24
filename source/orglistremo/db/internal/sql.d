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

struct NullableValue(T) {
  bool hasValue;
  T value;
}

void bindNullable(T)(
  ref Statement stmt,
  int index,
  in NullableValue!T opt
) {
  if (opt.hasValue) {
    stmt.bind(index, opt.value);
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

struct SubpathQuery {
  string subpath;
  bool useGlob;
}

string buildSubpathSql(in SubpathQuery query, string entryPrefix) {
  const isPattern = query.useGlob
    ? hasGlobWildcard(query.subpath)
    : hasPatternWildcard(query.subpath);
  if (query.useGlob) {
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
  in SubpathQuery query
) {
  const isPattern = isWildcard(query.subpath, query.useGlob);
  if (query.useGlob) {
    if (isPattern) {
      stmt.bind(idx++, query.subpath);
    } else {
      stmt.bind(idx++, query.subpath);
      stmt.bind(idx++, query.subpath ~ "/*");
    }
  } else {
    if (isPattern) {
      stmt.bind(idx++, userPatternToLike(query.subpath));
    } else {
      const unescaped = unescapePatternEscapes(query.subpath);
      stmt.bind(idx++, unescaped);
      stmt.bind(idx++, escapeLikeLiteral(unescaped) ~ "/%");
    }
  }
}
