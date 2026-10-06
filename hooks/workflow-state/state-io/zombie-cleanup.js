"use strict";
// Age-based sweep of the workflow directory: stale state files, transient .tmp
// leftovers, and session-scoped marker files. Entrypoint-private to state-io.js.

const fs = require("fs");
const path = require("path");
const { getWorkflowDir, normalizeStateVersion } = require("./core");
const { RECEIPT_DIR_SUFFIX } = require("../../lib/instructions-loaded-receipt");
const { WORKER_LOGS_DIRNAME } = require("./control-dir");

// Last moment this session showed a sign of life. Since #1733 that is `created_at`
// plus the newest `events[].at` — reading the retired `steps[*].updated_at` would
// see a long-running session as untouched since creation and DELETE it mid-run.
// v1 files are normalized first so a not-yet-migrated file is judged by the same rule.
function lastActivityMs(parsed) {
  let state = parsed;
  try {
    state = normalizeStateVersion(parsed);
  } catch (e) {
    state = parsed;
  }
  const events = state && Array.isArray(state.events) ? state.events : [];
  const timestamps = [state && state.created_at]
    .concat(events.map((e) => e && e.at))
    .filter(Boolean)
    .map((t) => new Date(t).getTime())
    .filter((t) => !isNaN(t));
  return timestamps.length > 0 ? Math.max(...timestamps) : 0;
}

const CONTROL_DIR_SUFFIX = ".control";
const CONTROL_RETENTION_DAYS = 30;

// <sid>.control/ (#2434): stale .tmp inside goes on the 24h rule; the directory itself
// only once <sid>.json is gone and nothing in it changed for CONTROL_RETENTION_DAYS.
function sweepControlDir(workflowDir, file, tmpCutoff) {
  const dir = path.join(workflowDir, file);
  const st = fs.lstatSync(dir);
  if (!st.isDirectory()) return;
  let newest = st.mtimeMs;
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    try {
      const est = fs.lstatSync(p);
      if (name.endsWith(".tmp") && est.mtimeMs < tmpCutoff) { fs.unlinkSync(p); continue; }
      newest = Math.max(newest, est.mtimeMs);
    } catch (e) {}
  }
  const sid = file.slice(0, -CONTROL_DIR_SUFFIX.length);
  if (fs.existsSync(path.join(workflowDir, `${sid}.json`))) return;
  if (newest < Date.now() - CONTROL_RETENTION_DAYS * 24 * 60 * 60 * 1000) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const WORKER_LOG_RETENTION_DAYS = 30;

// lstat throughout: a symlinked worker-logs dir or entry is never followed.
function sweepWorkerLogs(workflowDir, file) {
  const dir = path.join(workflowDir, file);
  if (!fs.lstatSync(dir).isDirectory()) return;
  const cutoff = Date.now() - WORKER_LOG_RETENTION_DAYS * 24 * 60 * 60 * 1000;
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    try {
      const est = fs.lstatSync(p);
      if (est.isFile() && est.mtimeMs < cutoff) fs.unlinkSync(p);
    } catch (e) {}
  }
}

function cleanupZombies(maxAgeDays = 7) {
  const workflowDir = getWorkflowDir();
  let files;
  try {
    files = fs.readdirSync(workflowDir);
  } catch (e) {
    return;
  }

  const cutoff = Date.now() - maxAgeDays * 24 * 60 * 60 * 1000;
  const tmpCutoff = Date.now() - 24 * 60 * 60 * 1000;

  for (const file of files) {
    const filePath = path.join(workflowDir, file);

    // Catches every transient write-then-rename leftover on the 24h cutoff,
    // including the token-minting forms `<sid>.off-clearance.tmp` and
    // `<sid>.off-clearance.mint.tmp`. Runs before the marker-suffix set below.
    // `.lock` joins `.tmp` on the same 24h rule: both are write-path debris a killed
    // writer leaves behind (#1733). Age is the ONLY safe handle — deleting a fresh
    // lock or another process's in-flight tmp corrupts the write it was meant to
    // tidy up after, and a lock whose payload never parsed has no pid to check.
    if (file.endsWith(".tmp") || file.endsWith(".lock")) {
      try {
        const st = fs.statSync(filePath);
        if (st.mtimeMs < tmpCutoff) fs.unlinkSync(filePath);
      } catch (e) {}
      continue;
    }

    // Receipt directories: one per session, holding one JSON entry per rule the
    // loader reported. Nothing else reclaims them, and the growth is invisible
    // because it lives under a dot-suffixed directory nobody lists. Suffix-exact
    // so a neighbouring name (`<sid>.instructions-loaded-notes`) is never claimed,
    // and removal is tolerant: unparseable or nested debris inside a stale
    // directory is exactly what this sweep exists to clear.
    if (file.endsWith(RECEIPT_DIR_SUFFIX)) {
      try {
        const st = fs.statSync(filePath);
        if (st.isDirectory() && st.mtimeMs < cutoff) {
          fs.rmSync(filePath, { recursive: true, force: true });
        }
      } catch (e) {}
      continue;
    }

    if (file.endsWith(CONTROL_DIR_SUFFIX)) {
      try { sweepControlDir(workflowDir, file, tmpCutoff); } catch (e) {}
      continue;
    }

    if (file === WORKER_LOGS_DIRNAME) {
      try { sweepWorkerLogs(workflowDir, file); } catch (e) {}
      continue;
    }

    if (
      file.endsWith(".workflow-off") ||
      file.endsWith(".worktree-off") ||
      file.endsWith(".issue-close-verified") ||
      file.endsWith(".next-step-paused") ||
      file.endsWith(".stall-reported") ||
      file.endsWith(".off-emergency-invoked") ||
      file.endsWith(".off-clearance") ||
      file.endsWith(".off-clearance.claimed")
    ) {
      try {
        const st = fs.statSync(filePath);
        if (st.mtimeMs < cutoff) fs.unlinkSync(filePath);
      } catch (e) {}
      continue;
    }

    if (!file.endsWith(".json")) continue;

    try {
      const raw = fs.readFileSync(filePath, "utf8");
      const state = JSON.parse(raw);
      if (lastActivityMs(state) < cutoff) fs.unlinkSync(filePath);
    } catch (e) {
      // Unreadable, corrupt, or a subdirectory — skip THIS entry only. The sweep
      // runs over every session's file on each SessionStart, so an uncaught throw
      // here would silently stop the whole directory from ever being reclaimed.
    }
  }
}

module.exports = { cleanupZombies, sweepWorkerLogs, WORKER_LOG_RETENTION_DAYS };
