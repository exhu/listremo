module orglistremo.pattern;

package(orglistremo):

import std.array : appender, Appender;

struct NamePattern {
  bool isWildcard() const {
    return .isWildcard(text, useGlob);
  }

  string toSqlPattern() const {
    if (useGlob) {
      return text;
    }
    return userPatternToLike(text);
  }

  string text;
  bool useGlob = false;
}

bool hasPatternWildcard(string s) {
  size_t backslashes = 0;
  foreach (c; s) {
    if (c == '\\') {
      backslashes++;
    } else {
      if (c == '%' && (backslashes % 2 == 0)) {
        return true;
      }
      backslashes = 0;
    }
  }
  return false;
}

bool hasGlobWildcard(string s) {
  foreach (c; s) {
    if (c == '*' || c == '?' || c == '[') {
      return true;
    }
  }
  return false;
}

bool isWildcard(string s, bool useGlob) {
  return useGlob ? hasGlobWildcard(s) : hasPatternWildcard(s);
}

string unescapePatternEscapes(string s) {
  bool hasEscape = false;
  size_t i = 0;
  while (i + 1 < s.length) {
    if (s[i] == '\\' && (s[i + 1] == '%' || s[i + 1] == '\\')) {
      hasEscape = true;
      break;
    }
    i++;
  }
  if (!hasEscape) {
    return s;
  }

  Appender!string app = appender!string();
  app.reserve(s.length);
  app.put(s[0 .. i]);
  while (i < s.length) {
    if (s[i] == '\\' && i + 1 < s.length &&
        (s[i + 1] == '%' || s[i + 1] == '\\')) {
      app.put(s[i + 1]);
      i += 2;
    } else {
      app.put(s[i]);
      i++;
    }
  }
  return app.data;
}

string userPatternToLike(string s) {
  bool needsEscape = false;
  foreach (c; s) {
    if (c == '_' || c == '\\') {
      needsEscape = true;
      break;
    }
  }
  if (!needsEscape) {
    return s;
  }

  Appender!string app = appender!string();
  app.reserve(s.length + 8);
  size_t i = 0;
  while (i < s.length) {
    const char c = s[i];
    if (c == '\\') {
      if (i + 1 < s.length && (s[i + 1] == '%' || s[i + 1] == '\\')) {
        app.put('\\');
        app.put(s[i + 1]);
        i += 2;
      } else {
        app.put("\\\\");
        i++;
      }
    } else if (c == '_') {
      app.put("\\_");
      i++;
    } else {
      app.put(c);
      i++;
    }
  }
  return app.data;
}

string escapeLikeLiteral(string s) {
  bool needsEscape = false;
  foreach (c; s) {
    if (c == '%' || c == '_' || c == '\\') {
      needsEscape = true;
      break;
    }
  }
  if (!needsEscape) {
    return s;
  }

  Appender!string app = appender!string();
  app.reserve(s.length + 8);
  foreach (c; s) {
    if (c == '%' || c == '_' || c == '\\') {
      app.put('\\');
    }
    app.put(c);
  }
  return app.data;
}

string[] parseIgnorePatterns(string content) {
  import std.string : splitLines, strip;

  string[] result;
  bool[string] seen;
  foreach (line; content.splitLines()) {
    const string trimmed = line.strip();
    if (trimmed.length == 0) {
      continue;
    }
    if (trimmed !in seen) {
      seen[trimmed] = true;
      result ~= trimmed;
    }
  }
  return result;
}

bool matchesIgnoreList(
  string relPath,
  bool isDir,
  in string[] patterns
) {
  if (relPath.length == 0 || relPath == "." || patterns.length == 0) {
    return false;
  }
  foreach (pat; patterns) {
    if (matchesSingleIgnoreGlob(relPath, isDir, pat)) {
      return true;
    }
  }
  return false;
}

private:

bool matchesSingleIgnoreGlob(string relPath, bool isDir, string rawPat) {
  import std.path : globMatch;

  string pat = rawPat;
  while (pat.length >= 2 && pat[0 .. 2] == "./") {
    pat = pat[2 .. $];
  }
  while (pat.length > 0 && pat[0] == '/') {
    pat = pat[1 .. $];
  }

  bool dirOnly = false;
  while (pat.length > 0 && pat[$ - 1] == '/') {
    dirOnly = true;
    pat = pat[0 .. $ - 1];
  }

  if (pat.length == 0) {
    return false;
  }
  if (dirOnly && !isDir) {
    return false;
  }
  return globMatch(relPath, pat);
}

unittest {
  // Test hasPatternWildcard
  assert(hasPatternWildcard("%"));
  assert(hasPatternWildcard("abc%"));
  assert(hasPatternWildcard("%def"));
  assert(!hasPatternWildcard("abc"));
  assert(!hasPatternWildcard("abc\\%def"));
  assert(hasPatternWildcard("abc\\\\%def"));
  assert(!hasPatternWildcard("abc\\\\\\%def"));

  // Test hasGlobWildcard
  assert(hasGlobWildcard("*"));
  assert(hasGlobWildcard("?"));
  assert(hasGlobWildcard("[0-9]"));
  assert(hasGlobWildcard("photos/*.jpg"));
  assert(hasGlobWildcard("photos/pic?.png"));
  assert(hasGlobWildcard("photos/[*].txt"));
  assert(!hasGlobWildcard("photos/pic.png"));
  assert(!hasGlobWildcard("normal_name"));

  // Test isWildcard
  assert(isWildcard("%", false));
  assert(!isWildcard("*", false));
  assert(isWildcard("*", true));
  assert(!isWildcard("%", true));

  // Test NamePattern
  NamePattern npLike = NamePattern("alpha%", false);
  assert(npLike.isWildcard());
  assert(npLike.toSqlPattern() == "alpha%");

  NamePattern npGlob = NamePattern("alpha*", true);
  assert(npGlob.isWildcard());
  assert(npGlob.toSqlPattern() == "alpha*");

  // Test zero-alloc fast paths
  const string plain = "clean-path/without-escapes";
  assert(userPatternToLike(plain).ptr is plain.ptr);
  assert(escapeLikeLiteral(plain).ptr is plain.ptr);
  assert(unescapePatternEscapes(plain).ptr is plain.ptr);

  // Test unescapePatternEscapes
  assert(unescapePatternEscapes("100\\%done") == "100%done");
  assert(unescapePatternEscapes("path\\\\file") == "path\\file");
  assert(unescapePatternEscapes("normal") == "normal");

  // Test userPatternToLike
  assert(userPatternToLike("photo_1.jpg") == "photo\\_1.jpg");
  assert(userPatternToLike("100%_done") == "100%\\_done");
  assert(userPatternToLike("100\\%done") == "100\\%done");
  assert(userPatternToLike("path\\file") == "path\\\\file");

  // Test escapeLikeLiteral
  assert(escapeLikeLiteral("100%_done\\") == "100\\%\\_done\\\\");
  assert(escapeLikeLiteral("normal") == "normal");

  // Test parseIgnorePatterns
  const parsedIgnores = parseIgnorePatterns(
    "  *~  \n\n#*#\r\n*~ \n  build/ \n"
  );
  assert(parsedIgnores == ["*~", "#*#", "build/"]);
  assert(parseIgnorePatterns("   \n\t\n").length == 0);

  // Test matchesIgnoreList
  const string[] globs = ["*~", "build/", "tmp/*"];
  assert(matchesIgnoreList("abc.d~", false, globs));
  assert(matchesIgnoreList("sub/abc.d~", false, globs));
  assert(!matchesIgnoreList("abc.d", false, globs));
  assert(matchesIgnoreList("build", true, globs));
  assert(!matchesIgnoreList("build", false, globs));
  assert(!matchesIgnoreList("tmp", true, globs));
  assert(matchesIgnoreList("tmp/a.txt", false, globs));
  assert(matchesIgnoreList("tmp/sub", true, globs));
  assert(!matchesIgnoreList(".", true, globs));
}
