"use strict";
// hooks/lib/shell-snapshot-repair.js — scan ~/.claude/shell-snapshots and rewrite a Windows-form
// PATH line to POSIX form in place (#2221). Shared by SessionStart and the PostToolUse(Failure)
// hook. Only the PATH line changes; the swap is compare-and-swap (a concurrent writer wins);
// nothing is ever deleted except our own *.repair.tmp; every path is fail-open, never a throw.
// Locating cygpath lives in cygpath-locate.js, the wording in shell-snapshot-notice.js.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { parsePathLine, classifyPathValue, planRepair, VERDICTS } = require("./shell-snapshot-path");
const { resolveCygpath, makeCygpathDeps } = require("./cygpath-locate");
const { formatRepairNotice, SWEEP_HOLDBACK_NOTE_MINUTES } = require("./shell-snapshot-notice");
const { createDeadline } = require("./hook-deadline");

const MIN_REPAIR_SLICE_MS = 300;
const MIN_SCAN_MS = 50;
const SESSION_START_HOOK_TIMEOUT_MS = 5000;
const SNAPSHOT_NAME_RE = /^snapshot-[^-]+-(\d{13})-.+\.sh$/;

function snapshotCreatedAtMs(name, stat) {
  const m = SNAPSHOT_NAME_RE.exec(String(name));
  return m ? Number(m[1]) : Number(stat && stat.mtimeMs);
}

function unlinkTmp(fsImpl, tmp) {
  try { fsImpl.unlinkSync(tmp); } catch (_) {
    try { fsImpl.chmodSync(tmp, 0o600); fsImpl.unlinkSync(tmp); } catch (_e) { /* best-effort */ }
  }
}

// Write the new text to a fresh tmp (wx: never reuse an existing name), re-read the original
// just before the rename, and give up when it changed: the other writer's content wins.
function replacePathLineAtomically(file, originalText, parsed, newValue, { fsImpl = fs, beforeSwap = null } = {}) {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.repair.tmp`);
  const newText = originalText.slice(0, parsed.lineStart) + "export PATH='" + newValue + "'" + parsed.eol + originalText.slice(parsed.lineEnd);
  let mode = 0o600;
  try { mode = fsImpl.statSync(file).mode & 0o777; } catch (_) { /* keep default */ }
  let fd;
  try { fd = fsImpl.openSync(tmp, "wx", mode); } catch (_) { return { ok: false, reason: "write-failed" }; }
  try {
    fsImpl.writeFileSync(fd, newText);
    try { fsImpl.fchmodSync(fd, mode); } catch (_) { /* mode is best-effort */ }
  } catch (_) {
    try { fsImpl.closeSync(fd); } catch (_e) { /* ignore */ }
    unlinkTmp(fsImpl, tmp);
    return { ok: false, reason: "write-failed" };
  }
  try { fsImpl.closeSync(fd); } catch (_) { /* ignore */ }
  try {
    if (beforeSwap) beforeSwap();
    if (fsImpl.readFileSync(file, "utf8") !== originalText) {
      unlinkTmp(fsImpl, tmp);
      return { ok: false, reason: "changed-during-repair" };
    }
    fsImpl.renameSync(tmp, file);
  } catch (_) {
    unlinkTmp(fsImpl, tmp);
    return { ok: false, reason: "write-failed" };
  }
  return { ok: true };
}

function judgeAndRepair(file, name, opts, state) {
  const { converterDeps, deadline, fsImpl, maxRepairsReached } = opts;
  const text = fsImpl.readFileSync(file, "utf8");
  const parsed = parsePathLine(text);
  const verdict = !parsed.found ? VERDICTS.NO_PATH_LINE : (!parsed.closed ? VERDICTS.UNPARSED : classifyPathValue(parsed.value));
  if (state.verdictBefore === null) state.verdictBefore = verdict;
  const out = (outcome, reason) => Object.assign({ name, verdictBefore: state.verdictBefore, outcome }, reason ? { reason } : {});
  if (verdict === VERDICTS.WINDOWS_UNREPAIRABLE) return out("unrepairable");
  if (verdict === VERDICTS.MISSING_CORE) return out("missing-core");
  if (verdict !== VERDICTS.WINDOWS_FORM) return out("none");
  if (maxRepairsReached) return out("deferred", "max-repairs");
  if (!converterDeps) return out("failed", "cygpath-unavailable");
  if (!deadline || deadline.remainingMs() < MIN_REPAIR_SLICE_MS) return out("deferred", "time-budget");
  let plan;
  try { plan = planRepair(parsed.value, converterDeps); } catch (e) {
    return (e && e.code === "time-budget") ? out("deferred", "time-budget") : out("failed", "conversion-failed");
  }
  if (!plan.ok) return out("failed", plan.reason);
  const r = replacePathLineAtomically(file, text, parsed, plan.value, { fsImpl });
  if (r.ok) return out("repaired");
  return r.reason === "changed-during-repair" ? null : out("failed", r.reason);
}

// One file. A compare-and-swap conflict is re-read and re-judged once.
function repairSnapshotFile(file, { converterDeps = null, deadline = null, platform = process.platform, fsImpl = fs, maxRepairsReached = false } = {}) {
  const name = path.basename(String(file));
  const state = { verdictBefore: null };
  const opts = { converterDeps, deadline, platform, fsImpl, maxRepairsReached };
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      const r = judgeAndRepair(file, name, opts, state);
      if (r) return r;
    }
    return { name, verdictBefore: state.verdictBefore, outcome: "failed", reason: "changed-during-repair" };
  } catch (_) {
    return { name, verdictBefore: state.verdictBefore, outcome: "failed", reason: "read-failed" };
  }
}

function emptyResults() {
  return { scanned: 0, unscanned: 0, repaired: [], failed: [], deferred: [], unrepairable: [], missingCore: 0, newest: null };
}

function listSnapshots(dir, createdAfterMs) {
  const files = [];
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith(".sh")) continue;
    const full = path.join(dir, name);
    let st;
    try { st = fs.lstatSync(full); } catch (_) { continue; }
    if (!st.isFile()) continue;
    const createdAt = snapshotCreatedAtMs(name, st);
    if (createdAfterMs !== null && createdAfterMs !== undefined && createdAt < createdAfterMs) continue;
    files.push({ name, full, createdAt });
  }
  return files.sort((a, b) => (b.createdAt - a.createdAt) || (a.name < b.name ? 1 : -1));
}

// Budgets are measured on the deadline's own clock: budgetMs is what this scan may spend
// on repairs; below MIN_SCAN_MS of the whole hook budget the rest is left unscanned.
function scanAndRepair({ homeDir, platform = process.platform, converterDeps = null, deadline, budgetMs = 0, maxRepairs = 5, createdAfterMs = null } = {}) {
  const res = emptyResults();
  try {
    const dir = path.join(homeDir, ".claude", "shell-snapshots");
    let st;
    try { st = fs.lstatSync(dir); } catch (_) { return res; }
    if (st.isSymbolicLink() || !st.isDirectory()) return res;
    const files = listSnapshots(dir, createdAfterMs);
    const startRemaining = deadline.remainingMs();
    const repairDeadline = {
      remainingMs: () => {
        const now = deadline.remainingMs();
        return Math.min(now, budgetMs - (startRemaining - now));
      },
    };
    for (let i = 0; i < files.length; i++) {
      if (deadline.remainingMs() < MIN_SCAN_MS) { res.unscanned = files.length - i; break; }
      const f = files[i];
      res.scanned++;
      const r = repairSnapshotFile(f.full, { converterDeps, deadline: repairDeadline, platform, maxRepairsReached: res.repaired.length >= maxRepairs });
      if (res.newest === null) res.newest = { name: f.name, verdictBefore: r.verdictBefore };
      if (r.outcome === "repaired") res.repaired.push(f.name);
      else if (r.outcome === "failed") res.failed.push({ name: f.name, reason: r.reason, verdictBefore: r.verdictBefore });
      else if (r.outcome === "deferred") res.deferred.push({ name: f.name, reason: r.reason });
      else if (r.outcome === "unrepairable") res.unrepairable.push(f.name);
      else if (r.outcome === "missing-core" && platform === "win32") res.missingCore++;
    }
  } catch (_) { /* fail-open: report what was gathered */ }
  return res;
}

// A spawn timeout that never outlives the repair budget nor the hook deadline.
function budgetTimeoutFor(deadline, budgetMs, reserveMs = 100) {
  const startRemaining = deadline.remainingMs();
  return () => {
    const now = deadline.remainingMs();
    const t = Math.min(now - reserveMs, budgetMs - (startRemaining - now));
    return t < 100 ? 0 : t;
  };
}

function converterFor(deadline, budgetMs) {
  const exe = resolveCygpath({ env: process.env, platform: process.platform, existsSync: fs.existsSync });
  return exe ? makeCygpathDeps(exe, { timeoutFor: budgetTimeoutFor(deadline, budgetMs) }) : null;
}

// SessionStart entry: no session lower bound (it also recovers what PostToolUse skipped).
function buildShellSnapshotNotice({ homeDir, source, deadline } = {}) {
  try {
    const dl = deadline || createDeadline({ hookTimeoutMs: SESSION_START_HOOK_TIMEOUT_MS });
    const budgetMs = dl.sliceMs(1500, 100);
    const results = scanAndRepair({ homeDir, platform: process.platform, converterDeps: converterFor(dl, budgetMs), deadline: dl, budgetMs });
    const nv = results.newest && results.newest.verdictBefore;
    const affectsCurrentSession = source !== "startup" && (nv === VERDICTS.WINDOWS_FORM || nv === VERDICTS.WINDOWS_UNREPAIRABLE);
    return formatRepairNotice(results, { trigger: "session-start", failedCommandExit127: false, affectsCurrentSession });
  } catch (_) {
    return [];
  }
}

module.exports = {
  MIN_REPAIR_SLICE_MS,
  SWEEP_HOLDBACK_NOTE_MINUTES,
  snapshotCreatedAtMs,
  replacePathLineAtomically,
  repairSnapshotFile,
  scanAndRepair,
  budgetTimeoutFor,
  converterFor,
  buildShellSnapshotNotice,
  resolveCygpath,
  makeCygpathDeps,
  formatRepairNotice,
};
