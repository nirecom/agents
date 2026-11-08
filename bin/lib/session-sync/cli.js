"use strict";
// session-sync-engine CLI (#2658). Exit: 0 ok, 1 failure, 2 usage, 3 projects/.git missing, 4 busy.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { toWindowsPath } = require("../../../hooks/lib/branch-diff");
const G = require("./git");
const proc = require("./proc");
const lock = require("./lock");
const state = require("./state");
const integrate = require("./integrate");
const { restoreAll } = require("./mtime");

const ENGINE = path.join(__dirname, "..", "..", "session-sync-engine");
const ACTIONS = new Set(["push", "pull", "reset", "status", "startup", "restore-mtime"]);
const USAGE = "usage: session-sync-engine <push|pull|reset|status|startup|restore-mtime> [--claude-dir D] [--plans-dir P]"
  + " [--quiet] [--deadline-ms N] [--skip-fetch] [--dry-run [--dry-run-style touch|set]]";
const SUMMARY = {
  push: { ok: "Pushed session data.", "no-change": "No changes to push." },
  pull: { ok: "Pulled session data.", "no-change": "Pulled session data." },
  reset: { ok: "Reset to remote state.", "no-change": "Reset to remote state." },
};
const DAY_MS = 24 * 60 * 60 * 1000;

class UsageError extends Error {}

function parse(argv) {
  const o = { quiet: false, skipFetch: false, dryRun: false, style: "touch", deadlineMs: 3000 };
  const value = (i, name) => {
    if (i >= argv.length) throw new UsageError(`${name} needs a value`);
    return argv[i];
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--claude-dir") o.claudeDir = value(++i, a);
    else if (a === "--plans-dir") o.plansDir = value(++i, a);
    else if (a === "--quiet") o.quiet = true;
    else if (a === "--skip-fetch") o.skipFetch = true;
    else if (a === "--dry-run") o.dryRun = true;
    else if (a === "--dry-run-style") o.style = value(++i, a);
    else if (a === "--deadline-ms") o.deadlineMs = Number(value(++i, a));
    else if (a.startsWith("-") || o.action !== undefined) throw new UsageError(`unknown argument: ${a}`);
    else o.action = a;
  }
  if (!ACTIONS.has(o.action)) throw new UsageError(o.action ? `unknown action: ${o.action}` : "missing action");
  if (!["touch", "set"].includes(o.style)) throw new UsageError(`unknown --dry-run-style: ${o.style}`);
  if (!Number.isFinite(o.deadlineMs) || o.deadlineMs <= 0) throw new UsageError("--deadline-ms needs a positive number");
  o.claudeDir = toWindowsPath(o.claudeDir || path.join(os.homedir(), ".claude"));
  o.plansDir = toWindowsPath(o.plansDir || require("../../../hooks/lib/workflow-plans-dir.js").getWorkflowPlansDir());
  o.dir = path.join(o.claudeDir, "projects");
  o.gitDir = path.join(o.dir, ".git");
  return o;
}

async function sync(o) {
  const startedAt = new Date().toISOString();
  const r = await integrate.run({ action: o.action, dir: o.dir, claudeDir: o.claudeDir, plansDir: o.plansDir, skipFetch: o.skipFetch });
  state.record(o.gitDir, Object.assign({ action: o.action, quiet: o.quiet, startedAt }, r));
  if (r.result === "ok" || r.result === "no-change") {
    if (!o.quiet) process.stdout.write(`${SUMMARY[o.action][r.result]}\n`);
    return 0;
  }
  if (!o.quiet) process.stderr.write(`session-sync ${o.action} ${r.result}: ${r.error || "unknown error"}\n`);
  return r.result === "busy" ? 4 : 1;
}

function status(o) {
  const st = state.load(o.gitDir);
  const lines = [];
  const l = st.last;
  lines.push(l ? `last: ${l.action} ${l.result} at ${l.endedAt} (attempts ${l.attempts})${l.error ? ` - ${l.error}` : ""}` : "last: none");
  lines.push(`lastSuccess: push ${st.lastSuccess.push || "never"}, pull ${st.lastSuccess.pull || "never"}`);
  lines.push(`consecutiveFailures: ${st.consecutiveFailures}`);
  const sib = G.gitOut(o.dir, ["ls-files", "-z", "-c", "-o", "--exclude-standard", "--", "*.sync-conflict-*"]);
  const names = [...new Set((sib || "").split("\0").filter(Boolean))];
  lines.push(`conflictSiblings: ${names.length}`);
  for (const n of names) lines.push(`  ${n}`);
  lines.push(`mtimeRejected: ${st.mtimeRejected.count}${st.mtimeRejected.path ? ` (last: ${st.mtimeRejected.path})` : ""}`);
  lines.push(`writeDeferred: ${st.writeDeferred.count}${st.writeDeferred.path ? ` (last: ${st.writeDeferred.path})` : ""}`);
  lines.push(`writeBlocked: ${st.writeBlocked.count}${st.writeBlocked.path ? ` (last: ${st.writeBlocked.path})` : ""}`);
  const porcelain = G.gitOut(o.dir, ["status", "--porcelain", "-z", "--untracked-files=all"]);
  lines.push(`uncommitted: ${porcelain === null ? "unknown" : porcelain.split("\0").filter(Boolean).length}`);
  process.stdout.write(lines.join("\n") + "\n");
  return 0;
}

function warnIfStale(o) {
  const st = state.load(o.gitDir);
  const times = [st.lastSuccess.push, st.lastSuccess.pull].filter(Boolean).map((t) => Date.parse(t));
  const newest = times.length ? Math.max(...times) : null;
  if (st.consecutiveFailures >= 3) {
    process.stderr.write(`session-sync: ${st.consecutiveFailures} consecutive failures; run 'session-sync status'\n`);
  } else if (newest !== null && Date.now() - newest > DAY_MS) {
    process.stderr.write("session-sync: no successful sync in over 24 hours; run 'session-sync status'\n");
  }
}

// startup — bounded fetch in the foreground, then the pull detached in the background.
async function startup(o) {
  const startedAt = new Date().toISOString();
  const held = await lock.acquire(o.gitDir, { waitMs: 0 });
  if (!held) {
    state.record(o.gitDir, { action: "startup", quiet: o.quiet, startedAt, result: "busy", error: "lock held", attempts: 0 });
    return 0;
  }
  let r;
  try {
    r = await proc.run("git", ["-C", o.dir, "-c", `core.hooksPath=${G.NULL_DEV}`, "-c", "core.fsmonitor=false", ...G.fetchArgs()],
      { deadlineMs: o.deadlineMs, env: G.buildEnv() });
  } finally {
    await held.release();
  }
  const noRemoteMain = /couldn't find remote ref|could not find remote ref/i.test(r.stderr);
  if (r.timedOut || (r.code !== 0 && !noRemoteMain)) {
    const result = r.timedOut ? "timeout" : G.failureKind({ stderr: r.stderr });
    state.record(o.gitDir, { action: "startup", quiet: o.quiet, startedAt, result, error: r.stderr.trim() || "fetch failed", attempts: 1 });
  } else {
    const child = spawn(process.execPath, [ENGINE, "pull", "--skip-fetch", "--claude-dir", o.claudeDir, "--plans-dir", o.plansDir, "--quiet"],
      { detached: true, stdio: "ignore", windowsHide: true });
    child.unref();
  }
  warnIfStale(o);
  return 0;
}

async function main(argv) {
  let o;
  try {
    o = parse(argv);
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    process.stderr.write(`${e.message}\n${USAGE}\n`);
    return 2;
  }
  if (o.action === "restore-mtime") {
    restoreAll(o.dir, { dryRun: o.dryRun, style: o.style }, (s) => process.stdout.write(`${s}\n`), (s) => process.stderr.write(`${s}\n`));
    return 0;
  }
  if (!fs.existsSync(o.gitDir)) {
    if (!o.quiet) process.stderr.write(`Session sync not initialized: ${o.gitDir} not found; run session-sync-init first\n`);
    return 3;
  }
  if (o.action === "status") return status(o);
  if (o.action === "startup") return startup(o);
  return sync(o);
}

function runMain() {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
    process.stderr.write(`session-sync-engine: ${e && e.stack ? e.stack : e}\n`);
    process.exit(1);
  });
}

module.exports = { parse, main, runMain };
