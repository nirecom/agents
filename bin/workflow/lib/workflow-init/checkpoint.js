"use strict";

const fs = require("fs");
const path = require("path");

const CHECKPOINT_VERSION = 2; // #2087: PHASE_ORDER changed (meta-classify inserted
// before wip-check). A v1 checkpoint may have been written mid-pipeline under the
// OLD order, where the meta strip had not run yet when an ask_id like wip_conflict
// was raised; resuming it under the new order's hardcoded per-ask_id startPhase
// would skip meta-classify and misroute a meta issue as an ordinary one. The bump
// forces readCheckpoint() to return version_mismatch for every v1 checkpoint, which
// workflow-init-driver already handles safely: ignore it and restart from
// detect-issues using the positional issue tokens on the same invocation
// (workflow-init-driver:384-388).

function checkpointPath(plansDir, sessionId) {
  return path.join(plansDir, `${sessionId}-wi-checkpoint.json`);
}

function makeInitialState() {
  return {
    issues: [],
    repo_map: {},
    sid_pass: null,
    issue_json_cache: {},
    wip_results: {},
    label_sets: {},
    force_path_b: false,
    path_decision: null,
    // #1305 adopt-prior-state: the offered donor and the user's answer.
    adopt_candidate: null,
    adopt_decision: null,
    // #2087 meta-classify: {number, ownerRepo} of each sub-issue actually
    // offered by the pending meta_select ask, so applyAnswer can reject an
    // answer outside that set and resolve the choice in its own repository.
    meta_select_offered: [],
    // #2087 meta-classify: the meta parents NOT covered by the pending
    // meta_select ask; re-appended to state.issues on answer so they are
    // re-classified rather than dropped by first-parent-wins.
    meta_select_pending: [],
  };
}

function makeCheckpoint(sessionId, phase, askId, state) {
  return {
    version: CHECKPOINT_VERSION,
    session_id: sessionId,
    phase,
    ask_id: askId,
    state: Object.assign({}, state),
  };
}

function writeCheckpoint(ckptPath, sessionId, phase, askId, state) {
  const ckpt = makeCheckpoint(sessionId, phase, askId, state);
  fs.mkdirSync(path.dirname(ckptPath), { recursive: true });
  fs.writeFileSync(ckptPath, JSON.stringify(ckpt, null, 2), "utf8");
  return ckptPath;
}

function readCheckpoint(ckptPath) {
  if (!ckptPath || !fs.existsSync(ckptPath)) {
    return { error: "not_found", message: `Checkpoint not found: ${ckptPath}` };
  }
  let raw;
  try {
    raw = fs.readFileSync(ckptPath, "utf8");
  } catch (e) {
    return { error: "unreadable", message: `Cannot read checkpoint: ${e.message}` };
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    return { error: "malformed", message: `Malformed checkpoint JSON: ${e.message}` };
  }
  if (data.version !== CHECKPOINT_VERSION) {
    // `data` rides along on the mismatch so a caller can recover the stale
    // session's own issue numbers instead of discarding them outright (security
    // review HIGH: the documented --resume/--answer flow carries no positional
    // issue tokens, so a bare restart-from-detect-issues silently loses them).
    return { error: "version_mismatch", message: `Checkpoint version ${data.version} != expected ${CHECKPOINT_VERSION}`, data };
  }
  return { ok: true, data };
}

module.exports = {
  CHECKPOINT_VERSION,
  checkpointPath,
  makeInitialState,
  writeCheckpoint,
  readCheckpoint,
};
