"use strict";
// bin/worker-dispatch/workers/issue-close-finalize/state.js
//
// D3: the durable state file is UNTRUSTED INPUT, exactly like the payload.
//
// issue-close-finalize is the only multi-pass worker in the family. Between two
// passes the whole conversation state lives in a JSON file under the plans
// directory, and the dispatcher is a fresh process each time. So everything the
// payload validator does for `payload` this module must do for the state file's
// CONTENT — same capability types, same fail-closed posture, same rejection of
// unknown keys. A state file that grew a field, changed owner_repo, or came from
// another session is refused before any child process starts.
//
// Three separate jobs, deliberately kept apart (CPR-SC):
//
//   1. validateState()   — type/constraint table over the state object itself.
//                          Every field goes through capability.checkField, the
//                          same function payload validation uses, so the two can
//                          never drift. Unknown top-level keys AND unknown
//                          g5_history[] element keys are rejected: an attacker
//                          who can add a key can otherwise stage data for a
//                          future reader of this file.
//   2. readBinding()     — the session rebinding record. A 3-way match between
//                          payload, state file and binding record. Without it a
//                          state_file_path that merely LOOKS right for this
//                          session (the basename check in capability.js) could
//                          have been produced by a different session against a
//                          different repo.
//   3. writeInitial()    — the only writer. State file and binding record are
//                          both written tmp -> rename via fsguard.renameWithin,
//                          so a reader never observes a half-written file.
//
// The `state_file_path` BASENAME contract (<sid>-finalize-state-<root>.json) is
// already enforced at payload-validation time by the `state-file-for-session`
// capability type. This module deliberately does not re-implement it; it owns
// content and binding, not naming.
//
// Path comparison uses anchor.samePath, never `===`. Callers legitimately hand
// us `/c/git/...` (MSYS), `C:/git/...` and `C:\git\...` forms for the same file;
// a string compare would reject the honest case while still being no stronger
// against the dishonest one. samePath resolves + case-normalizes.

const fs = require("fs");
const crypto = require("crypto");
const { checkField } = require("../../capability");
const { samePath, realAbs } = require("../../anchor");

const SCHEMA_VERSION = 3;

// The closed triage vocabulary. `stuck_*` is open-ended by design (the chain
// scripts name the step they got stuck at) but bounded in shape.
const TRIAGE_FIXED = [
  "resume_e",
  "resume_h",
  "resume_j",
  "auto_close_path",
  "admin_close_path",
  "meta_pending_subs",
];
const TRIAGE_STUCK_RE = /^stuck_[a-z0-9_]{1,32}$/;
const MERGE_COMMIT_RE = /^[0-9a-f]{0,40}$/;

// field -> capability spec. `required:false` fields may be absent but, when
// present, are validated exactly like the required ones.
const STATE_FIELDS = {
  schema_version: { type: "int", required: true, min: SCHEMA_VERSION, max: SCHEMA_VERSION },
  root_issue_number: { type: "int", required: true, min: 1 },
  current_issue_number: { type: "int", required: true, min: 1 },
  issue_repo: { type: "repo-ref", required: false },
  owner_repo: { type: "owner-repo", required: true },
  agents_config_dir: { type: "anchor-acd", required: true },
  main_worktree_path: { type: "anchor-main-root", required: true },
  merge_commit: { type: "text", required: false, max: 64 },
  phase: { type: "enum:init_done|awaiting_recursion|terminal", required: true },
  triage_action: { type: "text", required: true, max: 64 },
  g5_loop_iteration: { type: "int", required: true, min: 0, max: 1000 },
  g5_history: { type: "__array__", required: false },
  proposal_counters: { type: "__counters__", required: true },
};

const G5_MAX_ITEMS = 64;

// Element keys are exhaustive in both directions: all seven required, nothing
// else tolerated.
const G5_ELEMENT_FIELDS = {
  iteration: { type: "int", min: 0, max: 1000 },
  issue_number: { type: "__int_like__" },
  proposal_status: { type: "enum:ok|skipped|none" },
  proposal_parent: { type: "__int_or_null__" },
  user_decision: { type: "__decision_or_null__" },
  g5_3a_completed: { type: "bool" },
  recursion_completed: { type: "bool" },
};

const DECISIONS = ["accept", "decline", "llm_declined", "skipped"];
const COUNTER_KEYS = ["accepted", "declined", "skipped"];

// The binding record's five load-bearing fields. `created_at` is metadata for a
// human reading the directory and is not part of the match.
const BINDING_FIELDS = [
  "session_id",
  "root_issue_number",
  "owner_repo",
  "main_worktree_path",
  "state_file_path",
];

function isInt(v) {
  return typeof v === "number" && Number.isInteger(v);
}

function checkG5Element(el, index, anchors) {
  if (el === null || typeof el !== "object" || Array.isArray(el)) {
    return `g5_history[${index}] must be an object`;
  }
  for (const key of Object.keys(el)) {
    if (!Object.prototype.hasOwnProperty.call(G5_ELEMENT_FIELDS, key)) {
      return `g5_history[${index}] has an unknown field '${key}'`;
    }
  }
  for (const [key, spec] of Object.entries(G5_ELEMENT_FIELDS)) {
    if (!Object.prototype.hasOwnProperty.call(el, key)) {
      return `g5_history[${index}] is missing '${key}'`;
    }
    const v = el[key];
    if (spec.type === "__int_like__") {
      // The initial template seeds issue_number as a string; later passes may
      // carry a number. Both are accepted, neither loosely.
      const ok = isInt(v) ? v >= 1 : typeof v === "string" && /^[0-9]{1,12}$/.test(v) && Number(v) >= 1;
      if (!ok) return `g5_history[${index}].issue_number must be a positive integer or its decimal string`;
      continue;
    }
    if (spec.type === "__int_or_null__") {
      if (v === null) continue;
      if (!isInt(v) || v < 1) return `g5_history[${index}].${key} must be a positive integer or null`;
      continue;
    }
    if (spec.type === "__decision_or_null__") {
      if (v === null) continue;
      if (typeof v !== "string" || !DECISIONS.includes(v)) {
        return `g5_history[${index}].${key} must be null or one of ${DECISIONS.join("|")}`;
      }
      continue;
    }
    const res = checkField(v, spec, anchors, {});
    if (res.error) return `g5_history[${index}].${key} ${res.error}`;
  }
  return null;
}

function checkCounters(v) {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    return "proposal_counters must be an object";
  }
  for (const key of Object.keys(v)) {
    if (!COUNTER_KEYS.includes(key)) return `proposal_counters has an unknown field '${key}'`;
  }
  for (const key of COUNTER_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(v, key)) {
      return `proposal_counters is missing '${key}'`;
    }
    if (!isInt(v[key]) || v[key] < 0) {
      return `proposal_counters.${key} must be a non-negative integer`;
    }
  }
  return null;
}

// Returns null when the object satisfies the whole table, else one message.
// First failure wins: the caller reports it and refuses, so enumerating the
// rest would only widen what an untrusted file learns about the validator.
function validateState(state, anchors) {
  if (state === null || typeof state !== "object" || Array.isArray(state)) {
    return "state file must contain a JSON object";
  }
  for (const key of Object.keys(state)) {
    if (!Object.prototype.hasOwnProperty.call(STATE_FIELDS, key)) {
      return `state file has an unknown field '${key}'`;
    }
  }
  for (const [key, spec] of Object.entries(STATE_FIELDS)) {
    const present = Object.prototype.hasOwnProperty.call(state, key) && state[key] !== undefined;
    if (!present) {
      if (spec.required) return `state file is missing '${key}'`;
      continue;
    }
    const v = state[key];
    if (spec.type === "__array__") {
      if (!Array.isArray(v)) return `state file field 'g5_history' must be an array`;
      if (v.length > G5_MAX_ITEMS) return `state file field 'g5_history' exceeds ${G5_MAX_ITEMS} items`;
      for (let i = 0; i < v.length; i += 1) {
        const err = checkG5Element(v[i], i, anchors);
        if (err) return `state file ${err}`;
      }
      continue;
    }
    if (spec.type === "__counters__") {
      const err = checkCounters(v);
      if (err) return `state file ${err}`;
      continue;
    }
    const res = checkField(v, spec, anchors, {});
    if (res.error) return `state file field '${key}' ${res.error}`;
    if (key === "schema_version" && v !== SCHEMA_VERSION) {
      return `state file field 'schema_version' must be ${SCHEMA_VERSION}`;
    }
    if (key === "triage_action" && !TRIAGE_FIXED.includes(v) && !TRIAGE_STUCK_RE.test(v)) {
      return `state file field 'triage_action' is not a recognized triage action`;
    }
    if (key === "merge_commit" && !MERGE_COMMIT_RE.test(v)) {
      return `state file field 'merge_commit' must be a lowercase hex SHA or empty`;
    }
  }
  return null;
}

function bindingPath(ctx, sessionId, rootIssueNumber) {
  return ctx.path.join(
    ctx.anchors.plansDir,
    `${sessionId}-finalize-binding-${rootIssueNumber}.json`,
  );
}

function readJson(file) {
  let raw = null;
  try {
    raw = fs.readFileSync(realAbs(file), "utf8");
  } catch (_e) {
    return { error: "could not be read" };
  }
  try {
    // `raw` is returned alongside the parsed value: it is the compare-and-swap
    // token's source, and it must be the SAME bytes the validator judged.
    return { value: JSON.parse(raw), raw };
  } catch (_e) {
    return { error: "is not valid JSON" };
  }
}

// --- compare-and-swap ------------------------------------------------------
//
// The state file carries no version counter to swap on: schema_version is fixed
// at 3 and g5_loop_iteration advances on one branch only, so neither identifies
// a write. The token is therefore a digest of the exact bytes that passed
// validateState and checkBinding — any write by anyone changes them, whether or
// not it changed a counter, and the digest keeps the token small enough to hand
// to a child process on argv.
function tokenOf(raw) {
  return crypto.createHash("sha256").update(String(raw === null || raw === undefined ? "" : raw)).digest("hex");
}

// Re-read <file> and report whether it still holds the bytes `token` came from.
// Returns null when unchanged, else the conflict message. Callers use it twice:
// once before starting a pass (so a file swapped after validation cannot be
// acted on with this process's approval behind it) and once immediately before
// a write (so a concurrent pass's result is never silently overwritten).
function checkToken(file, token) {
  let raw = null;
  try {
    raw = fs.readFileSync(realAbs(file), "utf8");
  } catch (_e) {
    return "state file disappeared after it was validated";
  }
  if (tokenOf(raw) !== token) {
    return "state file changed after it was validated — another finalize pass is writing it";
  }
  return null;
}

// The 3-way match. Payload, state file and binding record must agree on all
// five fields; any one of them alone is forgeable by whoever can write one file.
function checkBinding(payload, state, ctx) {
  const sessionId = payload.session_id;
  if (typeof sessionId !== "string" || sessionId === "") {
    return "session_id is required to verify the finalize session binding";
  }
  const file = bindingPath(ctx, sessionId, payload.root_issue_number);
  const read = readJson(file);
  if (read.error) return `finalize session binding record ${read.error}`;
  const rec = read.value;
  if (rec === null || typeof rec !== "object" || Array.isArray(rec)) {
    return "finalize session binding record must contain a JSON object";
  }
  for (const key of BINDING_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(rec, key)) {
      return `finalize session binding record is missing '${key}'`;
    }
  }
  if (rec.session_id !== sessionId) {
    return "finalize session binding record belongs to a different session";
  }
  if (Number(rec.root_issue_number) !== Number(payload.root_issue_number)) {
    return "finalize session binding record is bound to a different root issue";
  }
  if (rec.owner_repo !== payload.owner_repo || rec.owner_repo !== state.owner_repo) {
    return "finalize session binding record owner_repo does not match payload and state";
  }
  if (!samePath(rec.main_worktree_path, ctx.anchors.mainRoot)) {
    return "finalize session binding record main_worktree_path does not match the resolved main-root";
  }
  if (!samePath(rec.main_worktree_path, state.main_worktree_path)) {
    return "finalize session binding record main_worktree_path does not match the state file";
  }
  if (!samePath(rec.state_file_path, payload.state_file_path)) {
    return "finalize session binding record points at a different state file";
  }
  if (Number(state.root_issue_number) !== Number(payload.root_issue_number)) {
    return "state file root_issue_number does not match the payload";
  }
  if (state.owner_repo !== payload.owner_repo) {
    return "state file owner_repo does not match the payload";
  }
  return null;
}

// The single entry point for a non-initial pass: read, validate, rebind.
// Returns { error } or { state, token }. A caller that receives { error } MUST
// NOT spawn a child process — tests assert a spawn count of exactly 0 on every
// tamper scenario, which is the property that makes this a gate and not a lint.
// `token` is the compare-and-swap handle over the bytes just validated.
function loadValidated(payload, ctx) {
  const read = readJson(payload.state_file_path);
  if (read.error) return { error: `state file ${read.error}` };
  const stateErr = validateState(read.value, ctx.anchors);
  if (stateErr) return { error: stateErr };
  const bindErr = checkBinding(payload, read.value, ctx);
  if (bindErr) return { error: bindErr };
  return { state: read.value, token: tokenOf(read.raw) };
}

// tmp -> rename, both ends inside the plans directory, so fsguard can prove
// containment for each and a torn write is never observable.
//
// The temp name is UNIQUE PER WRITER. A fixed `<target>.tmp` is shared mutable
// state between every process writing this file: two concurrent passes each open
// it, interleave their bytes, and the loser's rename publishes a document neither
// of them composed — defeating the whole point of the tmp -> rename dance. pid
// plus random bytes makes the intermediate name private to one writer, so the
// only contended operation left is the rename itself, which is atomic.
function tmpNameFor(target) {
  return `${target}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
}

function writeAtomic(ctx, target, data) {
  const tmp = tmpNameFor(target);
  ctx.fsguard.writeFile(tmp, data);
  return ctx.fsguard.renameWithin(tmp, target);
}

// --- create lock -----------------------------------------------------------
//
// FIRST WRITE WINS below is an existence CHECK followed by an ACT, and two
// first-time passes running at once can both find nothing and both write — the
// second one's g5_history[0].g5_3a_completed:false landing on top of a chain that
// has already posted its proposal comment. The exclusive lock file closes that
// window: `wx` creation fails when the file exists, so exactly one pass at a time
// holds the check-through-create interval. Same technique and same
// `<target>.lock` naming as run-loop-step.js's lock over the loop passes (CPR-ORTH).
//
// The lock is created with plain fs because fsguard has no exclusive-create mode,
// so its path is put through fsguard's own containment check first — a lock file
// is still a write, and it must be provably inside a declared write scope.
//
// A pass that crashes leaves its lock behind forever; a lock older than one
// pass's budget therefore has no live owner and is reclaimed exactly once.
const LOCK_STALE_MS = 30000;

function tryAcquire(lockPath) {
  try {
    fs.writeFileSync(lockPath, String(process.pid), { flag: "wx" });
    return null;
  } catch (e) {
    return e && e.code ? e.code : "UNKNOWN";
  }
}

function acquireCreateLock(ctx, target) {
  const lockPath = `${target}.lock`;
  ctx.fsguard.assertWritable(lockPath);

  let code = tryAcquire(lockPath);
  if (code === "EEXIST") {
    let ageMs = LOCK_STALE_MS + 1;
    try {
      ageMs = Date.now() - fs.statSync(lockPath).mtimeMs;
    } catch (_e) {
      // Gone between the failed create and the stat — the owner finished.
      ageMs = LOCK_STALE_MS + 1;
    }
    if (ageMs > LOCK_STALE_MS) {
      try {
        fs.unlinkSync(lockPath);
      } catch (_e) {
        // Another pass reclaimed it first; the retry below decides.
      }
      code = tryAcquire(lockPath);
    }
  }
  if (code === null) return { lockPath };
  return {
    error:
      code === "EEXIST"
        ? "another finalize initial pass is creating this state file — retry"
        : `the finalize state file lock could not be acquired (${code})`,
  };
}

function releaseCreateLock(lockPath) {
  try {
    fs.unlinkSync(lockPath);
  } catch (_e) {
    // Already gone — nothing to release.
  }
}

// The refusal message for an initial pass over a chain that is already under way.
// Shared so the fast-fail pre-check in the worker and the authoritative check
// inside writeInitial() cannot describe the same condition differently (CPR-SSOT).
const ALREADY_INITIALIZED =
  "a finalize state file already exists for this session and root issue — the chain is already initialized; refusing to overwrite it (delete it deliberately to restart)";

// The existence half of FIRST WRITE WINS, exposed so runInitial() can fail before
// spawning run-initial.sh. That script performs EXTERNAL, IRREVERSIBLE mutations
// (parent-body updates, the G.5 prepare step) and used to run to completion before
// this module got a chance to refuse. The check stays inside writeInitial() too:
// this one is a fast-fail for the common case, that one — under the lock above —
// is what makes it correct when two passes race.
function alreadyInitialized(payload) {
  const statePath = payload.state_file_path;
  if (typeof statePath !== "string" || statePath === "") return false;
  return fs.existsSync(realAbs(statePath) || statePath);
}

// Written only by phase=initial, and only after the state object it describes
// has itself passed validateState. Order matters: the state file lands first,
// so a binding record never points at a file that does not exist.
//
// FIRST WRITE WINS. The initial pass is a CREATE, not an upsert: if a state file
// already exists at this path the chain for this session+root is already under
// way, and overwriting it would reset g5_history[0].g5_3a_completed to false —
// re-arming a proposal comment that has already been posted and cannot be
// un-posted. That is the same irreversible action the compare-and-swap protects
// on the loop_step and finalize_terminal passes; the initial pass gets the
// equivalent treatment here, expressed as existence rather than as a token
// because a create has no prior bytes to swap on. A caller that genuinely wants
// to restart deletes the state file deliberately.
function writeInitial(payload, ctx, state) {
  const stateErr = validateState(state, ctx.anchors);
  if (stateErr) return { error: `refusing to write an invalid state file: ${stateErr}` };

  const statePath = payload.state_file_path;
  const lock = acquireCreateLock(ctx, statePath);
  if (lock.error) return { error: lock.error };
  try {
    if (alreadyInitialized(payload)) return { error: ALREADY_INITIALIZED };
    writeAtomic(ctx, statePath, `${JSON.stringify(state, null, 2)}\n`);

    const record = {
      session_id: payload.session_id,
      root_issue_number: Number(payload.root_issue_number),
      owner_repo: state.owner_repo,
      main_worktree_path: ctx.anchors.mainRoot,
      state_file_path: statePath,
      created_at: new Date().toISOString(),
    };
    const recordPath = bindingPath(ctx, payload.session_id, payload.root_issue_number);
    writeAtomic(ctx, recordPath, `${JSON.stringify(record, null, 2)}\n`);

    return { statePath, recordPath };
  } finally {
    releaseCreateLock(lock.lockPath);
  }
}

module.exports = {
  SCHEMA_VERSION,
  TRIAGE_FIXED,
  TRIAGE_STUCK_RE,
  BINDING_FIELDS,
  ALREADY_INITIALIZED,
  alreadyInitialized,
  validateState,
  checkBinding,
  loadValidated,
  tokenOf,
  checkToken,
  writeInitial,
  bindingPath,
};
