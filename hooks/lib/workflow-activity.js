"use strict";
// Provenance observation layer C: "is a workflow in flight right now?"
//
// Vocabulary-independent — it asks about the session, not about what the user
// typed — so it still classifies a turn when layers A and B are both silent.
//
// The raw record is the only admissible evidence: the synthesizing reader fills
// in the full 14-step map for a file that never contained one, which would make
// an unrelated state file look like a live workflow.

// ABSENCE vs IGNORANCE (the two must never collapse into one `false`). Layer C
// hands `inactive` straight to `user-explicit`, so anything the module merely
// FAILED to observe has to answer `active` — the unprivileged answer:
//   absence  no workflow session id, no state file on disk   → inactive (evidence)
//   ignorance a throw, an unreadable/corrupt file, a state    → active (fail-closed)
//            file whose shape we cannot interpret

const fs = require("fs");
const { readRawState, getStatePath } = require("../workflow-state/state-io");
const { resolveWorkflowSessionId } = require("./resolve-workflow-session-id");

const ACTIVE_STATUSES = new Set(["complete", "in_progress", "skipped"]);

// Does a state file physically exist for this session? Used only to tell
// "readRawState returned null because there is nothing" (absence) from
// "…because it could not be parsed" (ignorance) — readRawState collapses both.
function stateFileExists(wsid) {
  try {
    return fs.existsSync(getStatePath(wsid));
  } catch (e) {
    return true; // cannot even stat it → assume it is there and unreadable
  }
}

/**
 * IN FLIGHT vs FINISHED. "Some step is off `pending`" alone cannot answer this: a
 * session that ran to completion months ago satisfies it forever, so every later
 * turn on that machine would read as mid-workflow and layer C would never classify
 * anything again. A workflow is in flight only while it is PART WAY through — some
 * step already moved off `pending` AND some step has not yet. All-`pending` is a
 * session that never started; all-terminal is one that finished. Both are inactive.
 *
 * Stated over the step set rather than over a named terminal step, so it holds for
 * any workflow_type and survives changes to the step list (CPR-8).
 *
 * @returns {boolean} true while a workflow is part way through, and also whenever
 *   activity could not be determined at all.
 */
function isWorkflowActive() {
  let wsid = null;
  try {
    wsid = resolveWorkflowSessionId();
  } catch (e) {
    return true;
  }
  if (!wsid) return false;

  let raw = null;
  try {
    raw = readRawState(wsid);
  } catch (e) {
    return true;
  }
  // null from readRawState = "no file" OR "file there but unparseable" — only the
  // first is evidence of absence.
  if (raw === null || raw === undefined) return stateFileExists(wsid);
  if (typeof raw !== "object") return true;

  const steps = raw.steps && typeof raw.steps === "object" ? raw.steps : null;
  if (!steps) return true;

  const names = Object.keys(steps);
  if (names.length === 0) return false;

  let started = false;
  let unfinished = false;
  for (const name of names) {
    const entry = steps[name];
    // A malformed entry is a step whose status we cannot read — ignorance, not
    // evidence of completion. Count it as unfinished so it can only ever hold the
    // answer at `active`, never push it to `inactive`.
    if (!entry || typeof entry !== "object") {
      unfinished = true;
      continue;
    }
    if (ACTIVE_STATUSES.has(entry.status)) started = true;
    else unfinished = true;
  }
  return started && unfinished;
}

module.exports = { isWorkflowActive };
