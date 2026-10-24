module orglistremo.cli.args;

import std.conv : to;
import std.stdio : stderr, writefln;

package(orglistremo):

bool isFlag(string s) {
  return s.length > 0 && s[0] == '-';
}

struct ArgCursor {
  this(string[] args, size_t startIdx = 1) {
    this.args = args;
    this.idx = startIdx;
  }

  bool empty() const {
    return idx >= args.length;
  }

  string front() const {
    return empty() ? null : args[idx];
  }

  void popFront() {
    if (!empty()) {
      idx++;
    }
  }

  string take() {
    const string val = front();
    popFront();
    return val;
  }

  bool matchFlag(string longFlag) {
    return matchFlag(null, longFlag);
  }

  bool matchFlag(string shortFlag, string longFlag) {
    if (empty()) {
      return false;
    }
    const string s = args[idx];
    if ((shortFlag.length > 0 && s == shortFlag) ||
        (longFlag.length > 0 && s == longFlag)) {
      popFront();
      return true;
    }
    return false;
  }

  bool nextValue(string optionName, out string val) {
    if (empty()) {
      stderr.writefln("Error: Missing value for %s option.", optionName);
      return false;
    }
    val = front();
    popFront();
    return true;
  }

  bool isOption() const {
    return !empty() && isFlag(args[idx]);
  }

private:
  string[] args;
  size_t idx;
}

bool parseChoice(T)(string raw, out T parsed, string optionName = null) {
  import std.traits : EnumMembers;

  static foreach (member; EnumMembers!T) {
    if (raw == member.to!string) {
      parsed = member;
      return true;
    }
  }
  if (optionName.length > 0) {
    import std.array : join;
    string[] validNames;
    static foreach (member; EnumMembers!T) {
      validNames ~= member.to!string;
    }
    stderr.writefln(
      "Invalid %s '%s'. Valid values: %s.",
      optionName,
      raw,
      validNames.join(", ")
    );
  }
  return false;
}

unittest {
  import orglistremo.model : EntryType, SortField;

  assert(isFlag("-j"));
  assert(isFlag("--all"));
  assert(!isFlag("root"));
  assert(!isFlag(""));

  ArgCursor cur = ArgCursor(["sync", "--all", "-j", "4", "backup%"]);
  assert(!cur.empty());
  assert(cur.isOption());
  assert(cur.matchFlag("--all"));
  assert(cur.matchFlag("-j", "--jobs"));
  string jVal;
  assert(cur.nextValue("--jobs", jVal));
  assert(jVal == "4");
  assert(!cur.isOption());
  assert(cur.take() == "backup%");
  assert(cur.empty());

  EntryType et;
  assert(parseChoice("file", et));
  assert(et == EntryType.file);
  assert(!parseChoice("invalid", et));

  SortField sf;
  assert(parseChoice("size", sf, "--sort"));
  assert(sf == SortField.size);
}
