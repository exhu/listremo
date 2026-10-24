/**
 * Output subsystem facade for orglistremo.
 *
 * Consumers should import the specific first-level modules (`console`, `csv`,
 * `formatter`, `html`, `options`, `units`) explicitly per `codestyle.md`.
 */
module orglistremo.output;

version (unittest) {
  import orglistremo.output.console;
  import orglistremo.output.csv;
  import orglistremo.output.formatter;
  import orglistremo.output.html;
  import orglistremo.output.options;
  import orglistremo.output.units;
}
