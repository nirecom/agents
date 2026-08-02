"use strict";
// Age-based sweep of the workflow directory: stale state files, transient .tmp
// leftovers, and session-scoped marker files. Entrypoint-private to state-io.js.

const fs = require("fs");
const path = require("path");
const { getWorkflowDir, normalizeStateVersion } = require("./core");

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

    if (
      file.endsWith(".workflow-off") ||
      file.endsWith(".worktree-off") ||
      file.endsWith(".issue-close-verified") ||
      file.endsWith(".next-step-paused") ||
      file.endsWith(".off-clearance") ||
      file.endsWith(".background-work") ||
      file.endsWith(".awaiting-user")
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

module.exports = { cleanupZombies };
