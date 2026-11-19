"use strict";
// Shared fixture of the #2941 PM session tests (tests/{hooks,bin}/feature-2941-*.js and the
// PM cases appended to older suites). Not a test on its own; no case markers.
//
// The `pm` key is written raw, straight into the state file: until #2941 registers `pm` in
// PERSISTED_TOP_LEVEL_KEYS the normal writer throws on it, so a seeded PM state must not depend on
// the code under test. Every path resolves against WORKFLOW_STATE_DIR, which the caller pins
// (harness isolate() or an explicit env), so nothing here reaches a real state store.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const fwd = (p) => String(p).replace(/\\/g, "/");
const io = () => require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const CTX = { cwd: "/fixture/pm", git_branch: "main", transcript_path: "/fixture/t/pm.jsonl" };

// load(rel) -> the module, or a stand-in whose every property throws the load error, so a case
// against a source that does not exist yet fails with that reason instead of crashing the file.
function load(rel) {
  try {
    return require(path.join(ROOT, rel));
  } catch (e) {
    const msg = `cannot load ${rel}: ${String(e.message).split("\n")[0]}`;
    return new Proxy({}, { get: (_t, k) => (k === "then" ? undefined : () => { throw new Error(msg); }) });
  }
}

// uuid(n) -> a valid lower-case session id; the first 8 hex digits are the name suffix.
function uuid(n) {
  const h = Number(n).toString(16).padStart(8, "0").slice(-8);
  return `${h}-0000-4000-8000-${String(n).padStart(12, "0").slice(-12)}`;
}
const suffix = (sid) => ` sid-${sid.slice(0, 8)}`;

const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
const exists = (sid) => fs.existsSync(statePath(sid));
const raw = (sid) => JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
const writeRaw = (sid, obj) => fs.writeFileSync(statePath(sid), JSON.stringify(obj, null, 2));

// pm(o) -> a well-formed `pm` value (the detail plan's Steps 2 shape). issues takes numbers.
function pm(o = {}) {
  return {
    tag: o.tag || "PM-infra",
    issues: (o.issues || []).map((n) => (typeof n === "object" ? n : { number: n })),
    objective: o.objective === undefined ? "PM infra theme" : o.objective,
    current_since: o.current_since || "2026-11-01T00:00:00.000Z",
    upstream_session_id: o.upstream_session_id || null,
    assignment_log: o.assignment_log || [{ at: "2026-11-01T00:00:00.000Z", op: "init", issues: (o.issues || []).map((n) => ({ number: n })), reason: "fixture" }],
    sequence: o.sequence || { updated_at: null, tables: [] },
    archived_at: o.archived_at === undefined ? null : o.archived_at,
  };
}

// seedState(sid, { wfInit, ctx }) -> a freshly created state; wfInit "complete" / "in_progress"
// makes it a workflow session (readWorkflowBegun -> begun).
function seedState(sid, o = {}) {
  const s = io();
  s.writeState(sid, s.createInitialState(sid, o.ctx || CTX));
  if (o.wfInit) s.markStep(sid, "workflow_init", o.wfInit);
  return raw(sid);
}

// seedPm(sid, pmValue, opts) -> seedState + the raw `pm` key.
function seedPm(sid, pmValue, o = {}) {
  const st = seedState(sid, o);
  st.pm = pmValue;
  writeRaw(sid, st);
  return raw(sid);
}

const readPm = (sid) => (exists(sid) ? raw(sid).pm : undefined);
const wfInitStatus = (sid) => {
  const st = raw(sid);
  const w = st.current && st.current.steps && st.current.steps.workflow_init;
  return w ? w.status : "pending";
};

// persistedKeys() -> PERSISTED_TOP_LEVEL_KEYS as an array (whatever container projection.js uses).
function persistedKeys() {
  const k = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "projection.js")).PERSISTED_TOP_LEVEL_KEYS;
  return k instanceof Set ? [...k] : Array.isArray(k) ? k : Object.keys(k || {});
}

// wrapped(name, args) — the wrapped form Claude Code delivers for a typed slash command.
const wrapped = (name, args) => `<command-message>${name}</command-message>\n<command-name>/${name}</command-name>\n<command-args>${args}</command-args>`;

// recordedCrossSession() — a live cross-session message exactly as UserPromptSubmit received it
// (fixtures/cross-session-message-recorded.json; its `source` says where it was recorded).
function recordedCrossSession() {
  return JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "cross-session-message-recorded.json"), "utf8")).prompt;
}

// crossSession(body) — the recorded message with its body replaced: the recorded wrapper open tag and
// peer-msg v1 header line stay byte for byte, so only the body under test differs from the live payload.
function crossSession(body) {
  const rec = recordedCrossSession();
  const lines = rec.split("\n");
  const close = "</cross-session-message>";
  assert.ok(lines[0].startsWith("<cross-session-message ") && lines[1].startsWith("[peer-msg v1] ") && rec.endsWith(`\n${close}`), "the recorded cross-session fixture lost its wrapper");
  return `${lines[0]}\n${lines[1]}\n${body}\n${close}`;
}

module.exports = {
  ROOT, fwd, io, CTX, load, uuid, suffix, statePath, exists, raw, writeRaw, pm, seedState, seedPm,
  readPm, wfInitStatus, persistedKeys, wrapped, recordedCrossSession, crossSession,
};
