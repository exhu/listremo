module orglistremo.output.formatter;

import orglistremo.model : DuplicateGroup, Entry, OutputFormat, RootSummary;
import orglistremo.output.console :
  printConsoleDuplicates, printConsoleEntries, printConsoleRoots,
  printConsoleUnique, Styler;
import orglistremo.output.csv :
  printCsvDuplicates, printCsvEntries, printCsvRoots, printCsvUnique;
import std.stdio : stdout;

void outputRoots(
  RootSummary[] roots,
  OutputFormat format,
  Styler styler
) {
  if (format == OutputFormat.csv) {
    printCsvRoots(roots, stdout);
  } else {
    printConsoleRoots(roots, styler, stdout);
  }
}

void outputEntries(
  Entry[] entries,
  OutputFormat format,
  Styler styler,
  bool fullHash = false
) {
  if (format == OutputFormat.csv) {
    printCsvEntries(entries, stdout);
  } else {
    printConsoleEntries(entries, styler, fullHash, stdout);
  }
}

void outputDuplicates(
  DuplicateGroup[] groups,
  OutputFormat format,
  Styler styler,
  bool fullHash = false
) {
  if (format == OutputFormat.csv) {
    printCsvDuplicates(groups, stdout);
  } else {
    printConsoleDuplicates(groups, styler, fullHash, stdout);
  }
}

void outputUnique(
  Entry[] entries,
  OutputFormat format,
  Styler styler,
  bool fullHash = false
) {
  if (format == OutputFormat.csv) {
    printCsvUnique(entries, stdout);
  } else {
    printConsoleUnique(entries, styler, fullHash, stdout);
  }
}
