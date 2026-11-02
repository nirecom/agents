"use strict";
// Cycle SSOT (#2875): what a closed cycle leaves behind and how a re-init sets it aside.
// A cycle is closed once merge_to_main or final_report completed after the last cycle_boundary.
// closeCycleIfFinished archives the control files, appends the boundary event, and clears the
// write-once fields; it runs at the /workflow-init entry and, as a backstop, when a declaring gate
// completes workflow_init. At the entry it also returns every step to pending, the same batch as
// RESET_FROM workflow_init, so next-step sees a fresh cycle instead of a stale-state abort.
// Files move before the event, so an interrupted run converges on the next call.

const fs = require("fs");
const path = require("path");

const TERMINAL_STEPS = ["merge_to_main", "final_report"];

const CONTROL_FILES = [
  "final-report-env.json",
  "session-close-gate.json",
  "issue-close-outcome.json",
  /^finalize-state-.+\.json$/,
  /^finalize-binding-.+\.json$/,
];

const STATE_FIELD_CLEARERS = {
  session_worktree: (sid) => require("./state-io").recordSessionWorktree(sid, null),
  last_pushed_sha: (sid) => require("./state-io").clearLastPushedSha(sid),
  merge_base_baseline: (sid) => require("./merge-base-baseline").clearMergeBaseBaseline(sid),
  delivery_profile: (sid) => require("./state-io").clearDeliveryProfile(sid),
};

const ARCHIVE_DIRNAME = "cycle-archive";

const isControlFile = (name) => CONTROL_FILES.some((m) => (typeof m === "string" ? m === name : m.test(name)));

function lastBoundaryIndex(events) {
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i] && events[i].kind === "cycle_boundary") return i;
  }
  return -1;
}

function isClosedByEvents(events) {
  const list = Array.isArray(events) ? events : [];
  return list.slice(lastBoundaryIndex(list) + 1).some((e) =>
    e && e.kind === "step_status" && e.status === "complete" && TERMINAL_STEPS.includes(e.step));
}

function isPreviousCycleClosed(state) {
  return !!state && isClosedByEvents(state.events);
}

const nextCycleNumber = (events) => (Array.isArray(events) ? events : []).filter((e) => e && e.kind === "cycle_boundary").length + 1;

function moveFile(src, dst) {
  try {
    fs.renameSync(src, dst);
  } catch (_) {
    fs.copyFileSync(src, dst);
    fs.unlinkSync(src);
  }
}

function archiveControlFiles(sid, n) {
  const dir = require("./state-io/control-dir").sessionControlDir(sid, { forWrite: true });
  const names = fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isFile() && isControlFile(d.name));
  if (names.length === 0) return;
  const dest = path.join(dir, ARCHIVE_DIRNAME, String(n));
  fs.mkdirSync(dest, { recursive: true });
  for (const d of names) moveFile(path.join(dir, d.name), path.join(dest, d.name));
}

function boundaryEvents(events, current, reason) {
  if (!isClosedByEvents(events)) return [];
  const origin = "cycle-boundary";
  const out = [{ kind: "cycle_boundary", closed_cycle: nextCycleNumber(events), reason, provenance: "declared", origin }];
  if (reason !== "reinit-entry") return out;
  const steps = (current && current.steps) || {};
  for (const step of require("./state-io").VALID_STEPS) {
    if ((steps[step] ? steps[step].status : "pending") === "pending") continue;
    out.push({ kind: "step_annotations_cleared", step, provenance: "declared", origin });
    out.push({ kind: "step_status", step, status: "pending", provenance: "declared", origin });
  }
  return out;
}

function closeCycleIfFinished(sid, reason) {
  try {
    const io = require("./state-io");
    const state = io.readState(sid);
    if (!isPreviousCycleClosed(state)) return false;
    archiveControlFiles(sid, nextCycleNumber(state.events));
    let closed = false;
    io.appendEvents(sid, (events, current) => {
      const batch = boundaryEvents(events, current, reason);
      closed = batch.length > 0;
      return batch;
    });
    if (!closed) return false;
    for (const [field, clear] of Object.entries(STATE_FIELD_CLEARERS)) {
      try { clear(sid); } catch (e) {
        process.stderr.write(`cycle-state: clearing ${field} failed: ${e && e.message}\n`);
      }
    }
    return true;
  } catch (e) {
    process.stderr.write(`cycle-state: closing the previous cycle failed (${reason}): ${e && e.message}\n`);
    return false;
  }
}

module.exports = {
  CONTROL_FILES,
  STATE_FIELD_CLEARERS,
  ARCHIVE_DIRNAME,
  isPreviousCycleClosed,
  closeCycleIfFinished,
};
