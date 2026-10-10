"use strict";
// tests/bin/feature-2561-worker-child-roots/stage-one.js
// Run under tests/fixtures/spawn-record-preload.js. Loads the dispatcher modules of the given
// checkout copy and starts, record-only, every script and every external command each worker
// declares. Prints one JSON document describing what it asked for.
// Usage: stage-one.js <dispatcher checkout> <target main worktree> <target linked worktree>

const path = require("path");

const [checkoutRoot, targetMain, targetLinked] = process.argv.slice(2);
const report = { error: null, anchorsError: null, agentsMainRootResolved: false, workerCount: 0, declared: [] };
const finish = () => {
  process.stdout.write(`${JSON.stringify(report)}\n`);
  process.exit(0);
};

let anchorMod = null;
let spawnMod = null;
let registry = null;
try {
  anchorMod = require(path.join(checkoutRoot, "bin", "worker-dispatch", "anchor.js"));
  spawnMod = require(path.join(checkoutRoot, "bin", "worker-dispatch", "spawn.js"));
  registry = require(path.join(checkoutRoot, "hooks", "lib", "worker-dispatch-registry.js"));
} catch (e) {
  report.error = `modules did not load: ${e.message}`;
  finish();
}

// Three git probes run for real: the two behind the anchors, and the lazy one that finds the
// agents main worktree. That one is memoised, so it must answer before record-only withholds it.
const anchors = anchorMod.resolveAnchors(targetMain);
report.anchorsError = anchors.error;
if (anchors.error !== null) finish();
report.agentsMainRootResolved = anchorMod.resolveAgentsMainRoot() !== null;
process.env.SPAWN_RECORD_MODE = "record-only";

function commandFor(rel, external) {
  if (rel.endsWith(".py") && external.includes("uv")) return "uv";
  if (rel.endsWith(".sh") && external.includes("bash")) return "bash";
  if (external.includes("node")) return "node";
  return external.includes("bash") ? "bash" : external[0];
}

function attempt(entry, item, opts) {
  process.env.SPAWN_RECORD_TAG = `${item.worker}|${item.kind}|${item.name}`;
  try {
    spawnMod.run(entry, Object.assign({ anchors, args: [] }, opts));
  } catch (e) {
    item.threw = e.message;
  }
  report.declared.push(item);
}

report.workerCount = registry.WORKER_NAMES.length;
for (const worker of registry.WORKER_NAMES) {
  const entry = registry.workers[worker];
  const external = entry.binaries.external;
  const scripts = entry.binaries.scripts;
  for (const name of Object.keys(scripts)) {
    const decl = scripts[name];
    const command = commandFor(decl.rel, external);
    const cwd = decl.anchor === "family-worktree" ? targetLinked : targetMain;
    const item = { worker, kind: "script", name, anchor: decl.anchor, rel: decl.rel, command, threw: null };
    attempt(entry, item, { command, script: name, cwd });
  }
  for (const command of external) {
    const item = { worker, kind: "external", name: command, anchor: null, rel: null, command, threw: null };
    attempt(entry, item, { command, cwd: targetMain });
  }
}
finish();
