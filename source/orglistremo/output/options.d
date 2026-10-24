module orglistremo.output.options;

import std.stdio : writeln;

package(orglistremo):

enum OutputFormat {
  console,
  csv,
  html
}

enum ColorMode {
  autoMode,
  always,
  never
}

struct Styler {
  string wrap(string text, string code) const {
    return enabled ? "\033[" ~ code ~ "m" ~ text ~ "\033[0m" : text;
  }

  string bold(string s) const {
    return wrap(s, "1");
  }

  string header(string s) const {
    return wrap(s, "1;36");
  }

  string root(string s) const {
    return wrap(s, "1;35");
  }

  string dir(string s) const {
    return wrap(s, "1;34");
  }

  string size(string s) const {
    return wrap(s, "33");
  }

  string hash(string s) const {
    return wrap(s, "2;37");
  }

  string date(string s) const {
    return wrap(s, "32");
  }

  bool enabled;
}

struct OutputOptions {
  OutputFormat format = OutputFormat.console;
  Styler styler;
  bool fullHash = false;
}

void info(in OutputOptions opts, string msg) {
  if (opts.format == OutputFormat.console) {
    writeln(msg);
  }
}

unittest {
  Styler styler;
  styler.enabled = false;
  assert(styler.bold("abc") == "abc");
  assert(styler.root("r1") == "r1");

  styler.enabled = true;
  assert(styler.bold("abc") == "\033[1mabc\033[0m");
  assert(styler.root("r1") == "\033[1;35mr1\033[0m");

  OutputOptions opts;
  assert(opts.format == OutputFormat.console);
  assert(!opts.styler.enabled);
  assert(!opts.fullHash);
}
