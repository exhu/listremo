module orglistremo.output.formatter;

import orglistremo.model : DuplicateGroup, Entry, OutputFormat, RootSummary;
import orglistremo.output.console :
  OutputOptions, printConsoleDuplicates, printConsoleEntries,
  printConsoleRoots, printConsoleUnique;
import orglistremo.output.csv :
  printCsvDuplicates, printCsvEntries, printCsvRoots, printCsvUnique;
import std.stdio : stdout;

void outputRoots(
  in RootSummary[] roots,
  in OutputOptions options
) {
  if (options.format == OutputFormat.csv) {
    printCsvRoots(roots, stdout);
  } else {
    printConsoleRoots(roots, options, stdout);
  }
}

void outputEntries(
  in Entry[] entries,
  in OutputOptions options
) {
  if (options.format == OutputFormat.csv) {
    printCsvEntries(entries, stdout);
  } else {
    printConsoleEntries(entries, options, stdout);
  }
}

void outputDuplicates(
  in DuplicateGroup[] groups,
  in OutputOptions options
) {
  if (options.format == OutputFormat.csv) {
    printCsvDuplicates(groups, stdout);
  } else {
    printConsoleDuplicates(groups, options, stdout);
  }
}

void outputUnique(
  in Entry[] entries,
  in OutputOptions options
) {
  if (options.format == OutputFormat.csv) {
    printCsvUnique(entries, stdout);
  } else {
    printConsoleUnique(entries, options, stdout);
  }
}
