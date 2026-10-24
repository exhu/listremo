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
import std.stdio : stdout;

void outputRoots(
  in RootSummary[] roots,
  in OutputOptions options
) {
  if (options.format == OutputFormat.csv) {
    printCsvRoots(roots, stdout);
  } else if (options.format == OutputFormat.html) {
    printHtmlRoots(roots, options, stdout);
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
  } else if (options.format == OutputFormat.html) {
    printHtmlEntries(entries, options, stdout);
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
  } else if (options.format == OutputFormat.html) {
    printHtmlDuplicates(groups, options, stdout);
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
  } else if (options.format == OutputFormat.html) {
    printHtmlUnique(entries, options, stdout);
  } else {
    printConsoleUnique(entries, options, stdout);
  }
}
