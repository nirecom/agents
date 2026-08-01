"use strict";
// Age-based sweep of the workflow directory: stale state files, transient .tmp
// leftovers, and session-scoped marker files. Entrypoint-private to state-io.js.

const fs = require("fs");
const path = require("path");
const { getWorkflowDir } = require("./core");

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
    if (file.endsWith(".tmp")) {
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
      file.endsWith(".issue-provenance") ||
      file.endsWith(".issue-provenance-consumed") ||
      file.endsWith(".issue-provenance-result") ||
      file.endsWith(".session-transcript")
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

      const timestamps = [state.created_at]
        .concat(
          Object.values(state.steps || {}).map((s) => s && s.updated_at)
        )
        .filter(Boolean)
        .map((t) => new Date(t).getTime())
        .filter((t) => !isNaN(t));

      const maxTimestamp =
        timestamps.length > 0 ? Math.max(...timestamps) : 0;
      if (maxTimestamp < cutoff) {
        fs.unlinkSync(filePath);
      }
    } catch (e) {
      // unreadable or corrupt — skip
    }
  }
}

module.exports = { cleanupZombies };
