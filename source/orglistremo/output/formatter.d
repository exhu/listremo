module orglistremo.output.formatter;

import orglistremo.model : DuplicateGroup, Entry, RootSummary;
import orglistremo.output.console :
  printConsoleDuplicates, printConsoleEntries, printConsoleRoots,
  printConsoleUnique;
import orglistremo.output.csv :
  printCsvDuplicates, printCsvEntries, printCsvRoots, printCsvUnique;
import orglistremo.output.html :
  printHtmlDuplicates, printHtmlEntries, printHtmlRoots, printHtmlUnique;
import orglistremo.output.options : OutputFormat, OutputOptions;
import std.stdio : File, stdout;

void outputRoots(
  in RootSummary[] roots,
  in OutputOptions options,
  File outStream = stdout
) {
  dispatchFormat!(
    RootSummary[],
    printCsvRoots,
    printHtmlRoots,
    printConsoleRoots
  )(roots, options, outStream);
}

void outputEntries(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  dispatchFormat!(
    Entry[],
    printCsvEntries,
    printHtmlEntries,
    printConsoleEntries
  )(entries, options, outStream);
}

void outputDuplicates(
  in DuplicateGroup[] groups,
  in OutputOptions options,
  File outStream = stdout
) {
  dispatchFormat!(
    DuplicateGroup[],
    printCsvDuplicates,
    printHtmlDuplicates,
    printConsoleDuplicates
  )(groups, options, outStream);
}

void outputUnique(
  in Entry[] entries,
  in OutputOptions options,
  File outStream = stdout
) {
  dispatchFormat!(
    Entry[],
    printCsvUnique,
    printHtmlUnique,
    printConsoleUnique
  )(entries, options, outStream);
}

private:

void dispatchFormat(T, alias csvFn, alias htmlFn, alias consoleFn)(
  in T items,
  in OutputOptions options,
  File outStream
) {
  final switch (options.format) {
    case OutputFormat.csv:
      csvFn(items, outStream);
      break;
    case OutputFormat.html:
      htmlFn(items, options, outStream);
      break;
    case OutputFormat.console:
      consoleFn(items, options, outStream);
      break;
  }
}

unittest {
  import orglistremo.internal.testutil : captureOutput;
  import orglistremo.model : Root;
  import std.algorithm.searching : canFind;

  Root r = Root(1, "r1", "/mnt/r1", 1000, 1700000000, true, 1024, true);
  RootSummary[] roots = [RootSummary(r, 1, 0, 10)];
  Entry e = Entry(1, 1, "r1", "a.txt", ".", "a.txt", false, 10, 100, "h");
  DuplicateGroup dg = DuplicateGroup("h", 10, false, [e, e]);

  foreach (fmt; [OutputFormat.console, OutputFormat.csv, OutputFormat.html]) {
    OutputOptions opts;
    opts.format = fmt;
    const rOut = captureOutput((File f) { outputRoots(roots, opts, f); });
    const eOut = captureOutput((File f) { outputEntries([e], opts, f); });
    const dOut = captureOutput((File f) { outputDuplicates([dg], opts, f); });
    const uOut = captureOutput((File f) { outputUnique([e], opts, f); });
    assert(rOut.canFind("r1"));
    assert(eOut.canFind("a.txt"));
    assert(dOut.canFind("a.txt"));
    assert(uOut.canFind("a.txt"));
  }
}
