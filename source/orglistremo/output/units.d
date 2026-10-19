module orglistremo.output.units;

import core.time : Duration;
import std.format : format;

string formatSizeHuman(ulong bytes) {
  if (bytes < 1024) {
    return format("%d B", bytes);
  }
  static immutable string[] units = ["KiB", "MiB", "GiB", "TiB", "PiB"];
  double d = (cast(double) bytes) / 1024.0;
  size_t u = 0;
  while (d >= 1024.0 && u + 1 < units.length) {
    d /= 1024.0;
    u++;
  }
  return format("%.2f %s", d, units[u]);
}

string formatUnixTime(long ts) {
  if (ts <= 0) {
    return "never";
  }
  return formatTimestamp(ts, ' ');
}

string formatIso8601(long unixTs) {
  if (unixTs <= 0) {
    return "";
  }
  return formatTimestamp(unixTs, 'T');
}

string formatDuration(Duration d) {
  const totalMsecs = d.total!"msecs"();
  if (totalMsecs < 1000) {
    return format("%d ms", totalMsecs);
  }
  const totalSeconds = d.total!"seconds"();
  if (totalSeconds < 60) {
    const fractionSec = (cast(double) totalMsecs) / 1000.0;
    return format("%.2f s", fractionSec);
  }
  const minutes = totalSeconds / 60;
  const secs = totalSeconds % 60;
  if (minutes < 60) {
    return format("%dm %02ds", minutes, secs);
  }
  const hours = minutes / 60;
  const remMinutes = minutes % 60;
  return format("%dh %02dm %02ds", hours, remMinutes, secs);
}

private:

string formatTimestamp(long ts, char dateTimeSeparator) {
  import std.datetime.systime : SysTime;

  const s = SysTime.fromUnixTime(ts).toISOString();
  if (s.length >= 15) {
    return format(
      "%s-%s-%s%c%s:%s:%s",
      s[0 .. 4],
      s[4 .. 6],
      s[6 .. 8],
      dateTimeSeparator,
      s[9 .. 11],
      s[11 .. 13],
      s[13 .. 15]
    );
  }
  return s;
}

unittest {
  import core.time : dur;

  assert(formatSizeHuman(500) == "500 B");
  assert(formatSizeHuman(1024) == "1.00 KiB");
  assert(formatSizeHuman(1048576) == "1.00 MiB");

  assert(formatUnixTime(0) == "never");
  assert(formatUnixTime(1700000000).length == 19);

  assert(formatIso8601(0) == "");
  const iso = formatIso8601(1700000000);
  assert(iso.length == 19);
  assert(iso[10] == 'T');

  assert(formatDuration(dur!"msecs"(450)) == "450 ms");
  assert(formatDuration(dur!"msecs"(1500)) == "1.50 s");
  assert(formatDuration(dur!"seconds"(65)) == "1m 05s");
  assert(formatDuration(dur!"seconds"(3665)) == "1h 01m 05s");
}
