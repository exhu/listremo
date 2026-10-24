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
}
