"use strict";

const fs = require("fs");
const path = require("path");

const CHECKPOINT_VERSION = 1;

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
    return { error: "version_mismatch", message: `Checkpoint version ${data.version} != expected ${CHECKPOINT_VERSION}` };
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
