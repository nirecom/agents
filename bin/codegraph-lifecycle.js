#!/usr/bin/env node
// codegraph-lifecycle.js — init / sync / stop the CodeGraph index for one root.
//
// Called as `node <abs path> <verb> --path <dir> [--quiet]`. Every exit code
// but a usage error is 0, so a CodeGraph problem never halts the caller's
// pipeline; diagnostics are a single stderr line and stdout carries only a
// real state change. Health judgement lives in codegraph-lifecycle/
// index-health.js, daemon identity in process-identity.js, and the kill path
// in daemon-stop.js. Design: docs/architecture/claude-code.md.

process.removeAllListeners("warning");

const fs = require("fs");
const path = require("path");
const { spawnShimmedCli } = require("../hooks/lib/spawn-shimmed-cli");

const { classifyIndex, upstreamSeesInitialized } = require("./codegraph-lifecycle/index-health");
const { stopDaemon } = require("./codegraph-lifecycle/daemon-stop");
const { warn, report } = require("./codegraph-lifecycle/diagnostics");

const VERBS = ["init", "sync", "stop"];
const DERIVED_DB_FILES = ["codegraph.db-wal", "codegraph.db-shm"];
const STATUS_TIMEOUT_MS = 60000;

let quiet = false;

function parseArgs(argv) {
  let verb = null;
  let root = null;
  let wantQuiet = false;
  for (let i = 0; i < argv.length; i += 1) {
    if (i === 0) {
      verb = argv[i];
    } else if (argv[i] === "--path") {
      root = argv[i + 1];
      i += 1;
    } else if (argv[i] === "--quiet" || argv[i] === "-q") {
      wantQuiet = true;
    } else {
      return null;
    }
  }
  if (!VERBS.includes(verb)) return null;
  if (typeof root !== "string" || root.length === 0) return null;
  return { verb, root, quiet: wantQuiet };
}

// resolveRoot drops CWD dependence and prefers the filesystem's own spelling,
// so the string handed to codegraph and the string matched against a daemon
// command line are derived the same way.
function resolveRoot(raw) {
  const resolved = path.resolve(raw);
  try {
    return fs.realpathSync.native(resolved);
  } catch (_) {
    return resolved;
  }
}

// codegraphEnabled is the single implementation point of the fail-safe-OFF
// polarity shared with install/win/codegraph.ps1 and install/linux/codegraph.sh:
// an explicit lowercase `on` enables, and everything else — `off`, unset,
// empty, an unrecognized value, or a failure to read the config at all —
// resolves to OFF. A real environment variable outranks the .env file.
function codegraphEnabled() {
  try {
    require("../hooks/lib/load-env").loadDefaultEnv();
  } catch (_) {
    return false;
  }
  const raw = process.env.CODEGRAPH;
  if (typeof raw !== "string") return false;
  return raw.trim().toLowerCase() === "on";
}

// spawnCodegraph is the only door to the binary, so every invocation carries
// the same two guarantees: a bounded timeout, and the upstream telemetry
// opt-out install/codegraph-constants.txt ships to the MCP registration. The
// env is built per call, not at module load, because codegraphEnabled() may
// have populated process.env from .env in between.
function spawnCodegraph(args, options) {
  return spawnShimmedCli("codegraph", args, {
    ...options,
    env: { ...process.env, CODEGRAPH_TELEMETRY: "0", DO_NOT_TRACK: "1" },
    timeout: STATUS_TIMEOUT_MS,
  });
}

function codegraphOnPath() {
  const probe = spawnCodegraph(["--version"], { stdio: "ignore" });
  return !(probe.error && probe.error.code === "ENOENT");
}

function runCodegraph(args) {
  const result = spawnCodegraph(args, { stdio: "inherit" });
  return !result.error && result.status === 0;
}

// --- init ----------------------------------------------------------------

// statusHealthy is the only fallback for an index node:sqlite could not read.
// It asks the binary for the same two facts index-health reads directly, and a
// missing or partial answer counts as unhealthy.
function statusHealthy(root) {
  const result = spawnCodegraph(["status", "--json", root], { encoding: "utf8" });
  if (result.error || result.status !== 0) return false;
  let parsed = null;
  try {
    parsed = JSON.parse(String(result.stdout || ""));
  } catch (_) {
    return false;
  }
  if (!parsed || parsed.initialized !== true) return false;
  if (!(Number(parsed.nodeCount) > 0)) return false;
  return Boolean(parsed.index) && parsed.index.state === "complete";
}

// quarantineIsSafe gates the one destructive step in this file. The three name
// asserts pin the slot to <root>/.codegraph/broken, and the two lstat checks
// refuse a link — on the slot itself or on the .codegraph directory holding
// it — so a junction can never lend the rmSync below reach outside the root.
function quarantineIsSafe(root, indexDir, slot) {
  if (path.basename(slot) !== "broken") return false;
  if (path.basename(path.dirname(slot)) !== ".codegraph") return false;
  if (path.resolve(path.dirname(path.dirname(slot))) !== path.resolve(root)) return false;
  try {
    const dirStat = fs.lstatSync(indexDir);
    if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) return false;
  } catch (_) {
    return false;
  }
  try {
    if (fs.lstatSync(slot).isSymbolicLink()) return false;
  } catch (_) {
    /* an absent slot is the normal first-quarantine case */
  }
  return true;
}

// quarantine renames the unusable DB aside instead of deleting it, then lets
// upstream `init -y` treat the root as fresh. The slot name is fixed so
// quarantines replace rather than pile up. Returns false when it declined, in
// which case it has already warned and nothing was moved.
function quarantine(root) {
  const indexDir = path.join(root, ".codegraph");
  const slot = path.join(indexDir, "broken");
  if (!quarantineIsSafe(root, indexDir, slot)) {
    warn("refusing to quarantine the index for " + root + "; .codegraph/broken is not a plain directory inside the root.");
    return false;
  }
  try {
    fs.rmSync(slot, { recursive: true, force: true });
    fs.mkdirSync(slot, { recursive: true });
    fs.renameSync(path.join(indexDir, "codegraph.db"), path.join(slot, "codegraph.db"));
  } catch (_) {
    warn("could not set the unusable index for " + root + " aside; leaving it in place.");
    return false;
  }
  for (const name of DERIVED_DB_FILES) {
    const from = path.join(indexDir, name);
    try {
      fs.renameSync(from, path.join(slot, name));
    } catch (_) {
      try {
        fs.rmSync(from, { force: true });
      } catch (_) {
        /* an orphaned WAL sidecar is harmless once its DB is gone */
      }
    }
  }
  return true;
}

// rebuildOrBuild picks the verb the way upstream picks it. `init -y` returns
// without doing anything once a codegraph.db file merely exists, so a present
// but unusable index must be repaired with `index -q`, which deletes and
// recreates the database files. The daemon is stopped first because Windows
// refuses that delete while the file is held open.
function rebuildOrBuild(root) {
  if (!upstreamSeesInitialized(root)) {
    runCodegraph(["init", "-y", root]);
    return true;
  }
  stopDaemon(root, false);
  if (runCodegraph(["index", "-q", root])) return true;
  if (!quarantine(root)) return false;
  runCodegraph(["init", "-y", root]);
  return true;
}

// runInit converges the index and stops: at most one rebuild, at most one
// quarantine, one re-init, and a single re-read of the verdict. No retry loop
// lives here, so a permanently broken repo costs the same on every worktree.
function runInit(root) {
  const verdict = classifyIndex(root);
  if (verdict === "valid") return;
  if (verdict === "indexing") {
    warn("index for " + root + " is being built by another process; leaving it alone.");
    return;
  }
  if (verdict === "unverifiable" && statusHealthy(root)) return;
  if (!rebuildOrBuild(root)) return;
  if (classifyIndex(root) === "valid") {
    report("index ready for " + root);
  } else {
    warn("index for " + root + " is still unusable after a rebuild; codegraph_explore may return stale or empty results.");
  }
}

// --- sync ----------------------------------------------------------------

// runSync never repairs: it runs at every checkout and merge, so a wrong
// verdict must cost nothing. Only a fully verified index reaches the binary;
// an absent one is the ordinary state of a repo nobody indexed.
function runSync(root) {
  const verdict = classifyIndex(root);
  if (verdict === "valid") {
    runCodegraph(["sync", "-q", root]);
    return;
  }
  if (verdict === "absent") return;
  if (!quiet) {
    warn("index for " + root + " is " + verdict + "; skipping sync. Run codegraph-lifecycle.js init to rebuild it.");
  }
}

// --- entrypoint ----------------------------------------------------------

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options) {
    process.stderr.write("usage: codegraph-lifecycle.js <init|sync|stop> --path <dir> [--quiet]\n");
    process.exit(64);
  }
  quiet = options.quiet;
  // `stop` is exempt from the flag: it releases a daemon this framework started,
  // and the uninstall path runs it precisely because CODEGRAPH has turned off.
  if (options.verb !== "stop" && !codegraphEnabled()) process.exit(0);

  const root = resolveRoot(options.root);
  if (!codegraphOnPath()) {
    if (options.verb !== "stop") {
      warn("CODEGRAPH is on but the codegraph command was not found; skipping " + options.verb + ".");
    }
    process.exit(0);
  }

  if (options.verb === "init") runInit(root);
  else if (options.verb === "sync") runSync(root);
  else stopDaemon(root, true);
  process.exit(0);
}

main();
