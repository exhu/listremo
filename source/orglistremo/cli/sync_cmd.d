module orglistremo.cli.sync_cmd;

import core.sync.mutex : Mutex;
import core.time : MonoTime;
import d2sqlite3 : Database;
import orglistremo.cli.args : ArgCursor;
import orglistremo.cli.context : DbContext, requireWritable;
import orglistremo.cli.roots : resolveRoots;
import orglistremo.db.connection : openWorkerDatabase;
import orglistremo.db.repo : RootRepository;
import orglistremo.db.repo_locks :
  LockRequest, SyncLockInfo, SyncLockRepository;
import orglistremo.internal.os : getLocalHostName, isPidAlive;
import orglistremo.model : Root;
import orglistremo.output.console : ConsoleProgressReporter;
import orglistremo.output.options : info, OutputFormat, OutputOptions;
import orglistremo.output.units : formatDuration, formatUnixTime;
import orglistremo.sync.progress : SyncIssue;
import orglistremo.sync.scanner : syncRoot, SyncOptions, SyncResult;
import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.parallelism : TaskPool, totalCPUs;
import std.process : thisProcessID;
import std.stdio : stderr, writefln, writeln;

package(orglistremo):

struct SyncArgs {
  bool allFlag;
  bool forceFlag;
  bool forceHash;
  bool noProgress;
  bool breakLock;
  uint jobs = 1;
  bool jobsPassed;
  uint progressIntervalMs = 1000;
  string targetRoot;
}

struct SyncRunConfig {
  SyncArgs syncArgs;
  OutputOptions opts;
}

struct SyncRunResult {
  bool hadError;
  bool syncStarted;
}

bool parseSyncArgs(string[] args, out SyncArgs parsed) {
  ArgCursor cur = ArgCursor(args);
  while (!cur.empty()) {
    string val;
    if (cur.matchFlag("--all")) {
      parsed.allFlag = true;
    } else if (cur.matchFlag("--force")) {
      parsed.forceFlag = true;
    } else if (cur.matchFlag("--force-hash")) {
      parsed.forceHash = true;
    } else if (cur.matchFlag("--no-progress")) {
      parsed.noProgress = true;
    } else if (cur.matchFlag("--break-lock")) {
      parsed.breakLock = true;
    } else if (cur.matchFlag("-j", "--jobs")) {
      parsed.jobsPassed = true;
      if (!cur.nextValue("--jobs", val) || !parseJobsOption(val, parsed.jobs)) {
        return false;
      }
    } else if (cur.matchFlag("--progress-interval")) {
      if (!cur.nextValue("--progress-interval", val) ||
          !parseIntervalOption(val, parsed.progressIntervalMs)) {
        return false;
      }
    } else if (cur.isOption()) {
      stderr.writefln("Unknown flag '%s' for sync.", cur.front());
      return false;
    } else {
      if (parsed.targetRoot.length > 0) {
        stderr.writefln("Unexpected argument '%s'.", cur.front());
        return false;
      }
      parsed.targetRoot = cur.take();
    }
  }
  return validateSyncArgs(parsed);
}

int handleSyncCommand(
  ref DbContext ctx,
  string[] args,
  in OutputOptions opts
) {
  if (!requireWritable(ctx)) {
    return 1;
  }

  SyncArgs syncArgs;
  if (!parseSyncArgs(args, syncArgs)) {
    return 1;
  }

  RootRepository rootRepo = RootRepository(ctx.db);
  Root[] toSync;
  if (!resolveSyncTargets(rootRepo, syncArgs, toSync)) {
    return 1;
  }

  const MonoTime startMono = MonoTime.currTime;
  const SyncRunConfig runCfg = SyncRunConfig(syncArgs, opts);
  const SyncRunResult res = (syncArgs.allFlag && syncArgs.jobs != 1
      && toSync.length > 1)
    ? runParallelSync(ctx, toSync, runCfg)
    : runSequentialSync(ctx, toSync, runCfg);

  if (res.syncStarted) {
    const elapsed = MonoTime.currTime - startMono;
    info(opts, format("Total time: %s", formatDuration(elapsed)));
  }

  return res.hadError ? 1 : 0;
}

SyncRunResult runParallelSync(
  ref DbContext ctx,
  in Root[] toSync,
  in SyncRunConfig cfg
) {
  const uint numWorkers = (cfg.syncArgs.jobs == 0)
    ? totalCPUs
    : cfg.syncArgs.jobs;
  auto pool = new TaskPool(numWorkers);
  scope (exit) {
    pool.finish(true);
  }

  auto mtx = new Mutex();
  bool hadError = false;
  bool anyStarted = false;

  foreach (root; pool.parallel(toSync)) {
    try {
      Database threadDb = openWorkerDatabase(ctx.dbPath, ctx.busyTimeoutMs);
      scope (exit) {
        threadDb.close();
      }

      SyncRunContext threadCtx = SyncRunContext(
        cfg.syncArgs, cfg.opts, null, false, mtx
      );
      const bool success = syncSingleRoot(threadDb, root, threadCtx);
      synchronized (mtx) {
        if (!success) {
          hadError = true;
        }
        if (threadCtx.syncStarted) {
          anyStarted = true;
        }
      }
    } catch (Exception e) {
      syncLog(mtx, {
        hadError = true;
        stderr.writefln("Error syncing root '%s': %s", root.name, e.msg);
      });
    }
  }

  return SyncRunResult(hadError, anyStarted);
}

SyncRunResult runSequentialSync(
  ref DbContext ctx,
  in Root[] toSync,
  in SyncRunConfig cfg
) {
  ConsoleProgressReporter reporter = null;
  if (cfg.opts.format == OutputFormat.console && !cfg.syncArgs.noProgress) {
    reporter = new ConsoleProgressReporter(
      cfg.opts, cfg.syncArgs.progressIntervalMs
    );
  }

  SyncRunContext runCtx = SyncRunContext(cfg.syncArgs, cfg.opts, reporter);
  bool hadError = false;
  foreach (ref const root; toSync) {
    if (!syncSingleRoot(ctx.db, root, runCtx)) {
      hadError = true;
    }
  }

  return SyncRunResult(hadError, runCtx.syncStarted);
}

private:

struct SyncRunContext {
  SyncArgs syncArgs;
  OutputOptions opts;
  ConsoleProgressReporter reporter = null;
  bool syncStarted = false;
  Mutex logMutex = null;
}

bool parseJobsOption(string valStr, out uint jobs) {
  try {
    jobs = to!uint(valStr);
    return true;
  } catch (Exception) {
    stderr.writefln(
      "Invalid --jobs value '%s'. Expected non-negative integer.", valStr
    );
    return false;
  }
}

bool parseIntervalOption(string valStr, out uint intervalMs) {
  try {
    intervalMs = to!uint(valStr);
    if (intervalMs > 0) {
      return true;
    }
  } catch (Exception) {
  }
  stderr.writefln(
    "Invalid --progress-interval value '%s'. Expected positive integer.",
    valStr
  );
  return false;
}

bool validateSyncArgs(in SyncArgs parsed) {
  if (parsed.jobsPassed && !parsed.allFlag) {
    stderr.writeln("Warning: Option --jobs/-j has no effect without --all.");
  }
  if (!parsed.allFlag && parsed.targetRoot.length == 0) {
    stderr.writeln(
      "Usage: listremo sync <name|pattern> [options] OR --all [pattern]"
    );
    return false;
  }
  return true;
}

bool resolveSyncTargets(
  ref RootRepository rootRepo,
  in SyncArgs syncArgs,
  out Root[] toSync
) {
  if (syncArgs.allFlag) {
    if (syncArgs.targetRoot.length == 0) {
      toSync = rootRepo.findByPattern("%");
      return true;
    }
    toSync = rootRepo.findByPattern(syncArgs.targetRoot);
    if (toSync.length == 0) {
      stderr.writefln(
        "Error: No roots match pattern '%s'.", syncArgs.targetRoot
      );
      return false;
    }
    return true;
  }

  if (!resolveRoots(rootRepo, syncArgs.targetRoot, toSync)) {
    return false;
  }
  if (toSync.length > 1) {
    import std.algorithm.iteration : map;
    import std.array : join;

    const string names = toSync.map!(r => r.name).join(", ");
    stderr.writefln(
      "Error: Pattern '%s' matches multiple roots (%s). " ~
      "Use --all to sync all matching roots.",
      syncArgs.targetRoot,
      names
    );
    return false;
  }
  return true;
}

void syncLog(Mutex mtx, scope void delegate() action) {
  if (mtx !is null) {
    synchronized (mtx) {
      action();
    }
  } else {
    action();
  }
}

bool syncSingleRoot(
  ref Database db,
  const ref Root root,
  ref SyncRunContext runCtx
) {
  SyncLockRepository lockRepo = SyncLockRepository(db);
  if (!acquireRootLock(lockRepo, root, runCtx)) {
    return false;
  }
  scope (exit) {
    lockRepo.releaseLock(root.id, thisProcessID, getLocalHostName());
  }

  runCtx.syncStarted = true;
  syncLog(runCtx.logMutex, {
    info(
      runCtx.opts,
      format("Syncing root '%s' (%s)...", root.name, root.path)
    );
  });

  return executeScan(db, root, runCtx);
}

bool acquireRootLock(
  ref SyncLockRepository lockRepo,
  const ref Root root,
  ref SyncRunContext runCtx
) {
  const LockRequest req = LockRequest(
    root.id,
    thisProcessID,
    getLocalHostName(),
    Clock.currTime.toUnixTime()
  );
  SyncLockInfo existing;
  bool acquired = lockRepo.acquireLock(req, existing);
  if (!acquired && runCtx.syncArgs.breakLock) {
    lockRepo.breakLock(root.id);
    acquired = lockRepo.acquireLock(req, existing);
  } else if (!acquired && existing.hostname == req.hostname &&
             !isPidAlive(existing.pid)) {
    syncLog(runCtx.logMutex, {
      stderr.writefln(
        "Warning: Clearing stale sync lock on root '%s' " ~
        "(PID %d on %s is no longer active).",
        root.name,
        existing.pid,
        existing.hostname
      );
    });
    lockRepo.breakLock(root.id);
    acquired = lockRepo.acquireLock(req, existing);
  }

  if (!acquired) {
    reportLockConflict(root, existing, runCtx);
  }
  return acquired;
}

void reportLockConflict(
  const ref Root root,
  in SyncLockInfo existing,
  ref SyncRunContext runCtx
) {
  syncLog(runCtx.logMutex, {
    stderr.writefln(
      "Error: Root '%s' is currently being synced by PID %d on host '%s' " ~
      "(started %s).",
      root.name,
      existing.pid,
      existing.hostname,
      formatUnixTime(existing.startedAt)
    );
    stderr.writeln(
      "Use 'listremo sync <name> --break-lock' if the process was terminated."
    );
  });
}

bool executeScan(
  ref Database db,
  const ref Root root,
  ref SyncRunContext runCtx
) {
  SyncOptions syncOpts;
  syncOpts.force = runCtx.syncArgs.forceFlag;
  syncOpts.forceHash = runCtx.syncArgs.forceHash;
  if (runCtx.reporter !is null) {
    syncOpts.onProgress = &runCtx.reporter.update;
  }
  syncOpts.onIssue = (const ref SyncIssue issue) {
    syncLog(runCtx.logMutex, {
      if (runCtx.reporter !is null) {
        runCtx.reporter.clear();
      }
      stderr.writefln("Warning: %s", issue.describe());
    });
  };

  try {
    const SyncResult stats = syncRoot(db, root, syncOpts);
    reportSyncOutcome(stats, runCtx);
    return stats.errors.length == 0;
  } catch (Exception e) {
    syncLog(runCtx.logMutex, {
      if (runCtx.reporter !is null) {
        runCtx.reporter.clear();
      }
      stderr.writefln("Error syncing root '%s': %s", root.name, e.msg);
    });
    return false;
  }
}

void reportSyncOutcome(in SyncResult stats, ref SyncRunContext runCtx) {
  syncLog(runCtx.logMutex, {
    if (runCtx.reporter !is null) {
      runCtx.reporter.clear();
    }
    info(
      runCtx.opts,
      format(
        "  Done: %d files, %d dirs, %d reused hashes.",
        stats.fileCount,
        stats.dirCount,
        stats.reusedHashes
      )
    );
    if (stats.errors.length > 0) {
      stderr.writefln("  Completed with %d error(s):", stats.errors.length);
      foreach (ref const err; stats.errors) {
        stderr.writefln("    - %s", err.describe());
      }
    }
  });
}

unittest {
  SyncArgs syncArgs;
  assert(parseSyncArgs(["sync", "myroot", "--force-hash"], syncArgs));
  assert(syncArgs.targetRoot == "myroot");
  assert(syncArgs.forceHash);
  assert(!syncArgs.forceFlag);
  assert(!syncArgs.allFlag);

  SyncArgs syncForce;
  assert(parseSyncArgs(["sync", "myroot", "--force"], syncForce));
  assert(syncForce.targetRoot == "myroot");
  assert(syncForce.forceFlag);
  assert(!syncForce.forceHash);

  SyncArgs syncAll;
  assert(
    parseSyncArgs(["sync", "--all", "--force", "--force-hash"], syncAll)
  );
  assert(syncAll.allFlag);
  assert(syncAll.forceFlag);
  assert(syncAll.forceHash);

  SyncArgs syncAllPattern;
  assert(parseSyncArgs(["sync", "myroot", "--all"], syncAllPattern));
  assert(syncAllPattern.allFlag);
  assert(syncAllPattern.targetRoot == "myroot");

  SyncArgs syncAllPrefix;
  assert(parseSyncArgs(["sync", "--all", "backup%"], syncAllPrefix));
  assert(syncAllPrefix.allFlag);
  assert(syncAllPrefix.targetRoot == "backup%");

  SyncArgs missingSyncTarget;
  assert(!parseSyncArgs(["sync"], missingSyncTarget));

  SyncArgs tooManyArgs;
  assert(!parseSyncArgs(["sync", "r1", "r2"], tooManyArgs));

  SyncArgs unknownFlagArgs;
  assert(!parseSyncArgs(["sync", "--bogus"], unknownFlagArgs));

  SyncArgs syncBreakLockArgs;
  assert(parseSyncArgs(["sync", "myroot", "--break-lock"], syncBreakLockArgs));
  assert(syncBreakLockArgs.breakLock);

  SyncArgs syncJobsArgs;
  assert(parseSyncArgs(["sync", "--all", "-j", "4"], syncJobsArgs));
  assert(syncJobsArgs.jobs == 4);

  SyncArgs syncProgArgs;
  assert(
    parseSyncArgs(
      ["sync", "myroot", "--no-progress", "--progress-interval", "500"],
      syncProgArgs
    )
  );
  assert(syncProgArgs.targetRoot == "myroot");
  assert(syncProgArgs.noProgress);
  assert(syncProgArgs.progressIntervalMs == 500);

  SyncArgs syncInvalidInterval;
  assert(
    !parseSyncArgs(
      ["sync", "myroot", "--progress-interval", "notanumber"],
      syncInvalidInterval
    )
  );

  SyncArgs syncMissingInterval;
  assert(
    !parseSyncArgs(
      ["sync", "myroot", "--progress-interval"],
      syncMissingInterval
    )
  );

  SyncArgs intervalZeroArgs;
  assert(
    !parseSyncArgs(
      ["sync", "norm_root", "--progress-interval", "0"], intervalZeroArgs
    )
  );

  SyncArgs jobsArgs;
  assert(parseSyncArgs(["sync", "norm_root", "-j", "4"], jobsArgs));
  assert(jobsArgs.jobsPassed);
}
