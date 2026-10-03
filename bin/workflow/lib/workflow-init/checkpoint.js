"use strict";

const fs = require("fs");
const path = require("path");
const { controlPath, diagnoseControlMigration } = require("../../../../hooks/workflow-state/state-io/control-dir");

const CHECKPOINT_VERSION = 3; // #2087 → #2063

// #2063: this path is emitted as CHECKPOINT= and pasted into a shell command by the
// agent, where a Windows backslash is an escape character rather than a separator.
// Forward slashes are a valid separator for every fs API on Windows; on POSIX a
// backslash is an ordinary filename byte, so the rewrite is confined to win32.
// Throws when the session control dir cannot be resolved (symlink, failed migration).
function checkpointPath(sessionId) {
  const joined = controlPath(sessionId, "wi-checkpoint.json", { forWrite: true });
  return path.sep === "\\" ? joined.split("\\").join("/") : joined;
}

function makeInitialState() {
  return {
    issues: [],
    repo_map: {},
    sid_pass: null,
    // #2063: {[issueNumber]: gh issue view --json …,comments payload}. A version-3
    // entry always carries `comments`; its absence is corruption, not a legacy shape.
    issue_json_cache: {},
    wip_results: {},
    label_sets: {},
    force_path_b: false,
    path_decision: null,
    // #1305 adopt-prior-state: the offered donor and the user's answer.
    adopt_candidate: null,
    adopt_decision: null,
    // #2087: {number, ownerRepo} offered by the pending meta_select ask.
    meta_select_offered: [],
    // #2087: meta parents not covered by the pending meta_select ask.
    meta_select_pending: [],
    // #2063: issues the user reopened. The override outlives a refetch, so it is
    // applied to the fresh payload instead of being written into the cached one.
    reopen_state_override: [],
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

// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
// deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/
// A CHECKPOINT= printed before the update names the plans-dir file that migration has since moved.
function migratedResumePath(ckptPath) {
  const m = /^(.+)-wi-checkpoint\.json$/.exec(path.basename(String(ckptPath || "")));
  if (!m) return null;
  try {
    const moved = controlPath(m[1], "wi-checkpoint.json");
    return fs.existsSync(moved) ? moved : null;
  } catch (e) {
    diagnoseControlMigration(e, "workflow-init");
    return null;
  }
}
// --- END temporary: plans-dir control files -> workflow control dir migration ---

function readCheckpoint(requestedPath) {
  const ckptPath = requestedPath && !fs.existsSync(requestedPath)
    ? migratedResumePath(requestedPath) || requestedPath
    : requestedPath;
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
    // data rides along so the caller can recover the stale session's issue numbers.
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
