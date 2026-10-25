module orglistremo.cli.migrate_cmd;

import orglistremo.cli.args : ArgCursor;
import orglistremo.cli.context :
  backupIfRequested, BackupRequest, BackupRequestBuilder, DbContext;
import orglistremo.db.migration : migrateDatabase;
import orglistremo.db.schema_version : schemaVersion;
import orglistremo.output.options : info, OutputOptions;
import std.format : format;
import std.stdio : stderr, writefln;

package(orglistremo):

struct MigrateArgs {
  bool noBackup;
}

bool parseMigrateArgs(string[] args, out MigrateArgs parsed) {
  ArgCursor cur = ArgCursor(args);
  while (!cur.empty()) {
    if (cur.matchFlag("--no-backup")) {
      parsed.noBackup = true;
    } else if (cur.isOption()) {
      stderr.writefln("Unknown flag '%s' for migrate.", cur.front());
      return false;
    } else {
      stderr.writefln("Unexpected argument '%s' for migrate.", cur.front());
      return false;
    }
  }
  return true;
}

int handleMigrateCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  MigrateArgs migrateArgs;
  if (!parseMigrateArgs(args, migrateArgs)) {
    return 1;
  }

  if (ctx.dbSchemaVersion == schemaVersion) {
    info(
      opts,
      format(
        "Database schema is already up to date (version %d).",
        schemaVersion
      )
    );
    return 0;
  }

  if (ctx.dbSchemaVersion < 0 || ctx.dbSchemaVersion > schemaVersion) {
    stderr.writefln(
      "Error: Cannot migrate database from schema version %d to %d.",
      ctx.dbSchemaVersion,
      schemaVersion
    );
    return 1;
  }

  const BackupRequest bkpReq = BackupRequestBuilder(ctx)
    .withNoBackup(migrateArgs.noBackup)
    .withOptions(opts)
    .build();
  if (!backupIfRequested(bkpReq)) {
    return 1;
  }

  return runMigration(ctx, opts);
}

private:

int runMigration(ref DbContext ctx, in OutputOptions opts) {
  try {
    const int prevVersion = ctx.dbSchemaVersion;
    migrateDatabase(ctx.db, prevVersion);
    ctx.dbSchemaVersion = schemaVersion;
    ctx.isReadOnly = false;
    info(
      opts,
      format(
        "Migrated database schema from version %d to %d.",
        prevVersion,
        schemaVersion
      )
    );
    return 0;
  } catch (Exception e) {
    stderr.writefln("Error migrating database: %s", e.msg);
    return 1;
  }
}

unittest {
  MigrateArgs migDefault;
  assert(parseMigrateArgs(["migrate"], migDefault));
  assert(!migDefault.noBackup);

  MigrateArgs migNoBackup;
  assert(parseMigrateArgs(["migrate", "--no-backup"], migNoBackup));
  assert(migNoBackup.noBackup);

  MigrateArgs migInvalidFlag;
  assert(!parseMigrateArgs(["migrate", "--unknown"], migInvalidFlag));

  MigrateArgs migInvalidPos;
  assert(!parseMigrateArgs(["migrate", "extra"], migInvalidPos));
}
