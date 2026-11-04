"use strict";
// Shared fixture for the #2920 workflow-abort tests (tests/{hooks,bin}/feature-2920-*.js). Not a
// test on its own. Every path resolves against the dirs the caller pinned (harness isolate() or
// an explicit env), so nothing here reaches a real state store.
//
// The aborted states are built at the stream level (rawAbort / seedAborted): the event is pushed
// straight into the state file, as a release that knows the kind would have written it. A consumer
// test therefore exercises the consumer alone, not the writer in workflow-abort.js.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const fwd = (p) => String(p).replace(/\\/g, "/");
const rel = (r) => fwd(path.join(ROOT, r));
const mod = (r) => require(path.join(ROOT, r));
const io = () => mod("hooks/workflow-state/state-io");
const R = () => require("../../lib/state-handoff-record-fixture");

const ABORT_MODULE = "hooks/workflow-state/workflow-abort.js";
const CTX = { cwd: "/fixture/abort", git_branch: "feature/abort", transcript_path: "/fixture/t/abort.jsonl" };

const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json");
const raw = (sid) => JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
const bytes = (sid) => (fs.existsSync(statePath(sid)) ? fs.readFileSync(statePath(sid), "utf8") : null);
const writeRaw = (sid, obj) => fs.writeFileSync(statePath(sid), JSON.stringify(obj, null, 2));

// abortEvent(origin, extra) — a well-formed workflow_aborted event (no seq / at).
function abortEvent(origin, extra) {
  const e = { kind: "workflow_aborted", reason: "test abort", origin, provenance: "declared" };
  if (origin !== "abort-sentinel") e.heir_session_id = "heir-2920";
  return Object.assign(e, extra || {});
}

// abortModule() — the module under test; a missing module fails the calling case with its name.
function abortModule() {
  try {
    return mod(ABORT_MODULE);
  } catch (e) {
    throw new Error(`${ABORT_MODULE} not loadable: ${String(e.message).split("\n")[0]}`, { cause: e });
  }
}

// seedPlain(sid) — a freshly created state with workflow_init complete.
function seedPlain(sid, ctx) {
  const s = io();
  s.writeState(sid, s.createInitialState(sid, ctx || CTX));
  s.markStep(sid, "workflow_init", "complete");
  return raw(sid);
}

// pushStep(sid, step, status, at) — a raw step_status event (no boundary checks), e.g. a
// delivered merge_to_main or a stale in_progress write_code.
function pushStep(sid, step, status, at) {
  const ev = { kind: "step_status", step, status, provenance: "observed", origin: "fixture-2920" };
  if (at) ev.at = at;
  return R().pushEvents(sid, [ev]);
}

// rawAbort(sid, origin, extra) — appends a workflow_aborted event to the stream as written.
function rawAbort(sid, origin, extra) {
  return R().pushEvents(sid, [abortEvent(origin, extra)]);
}

// seedAborted(sid, origin, extra) — seedPlain + rawAbort.
function seedAborted(sid, origin, extra) {
  seedPlain(sid);
  rawAbort(sid, origin, extra);
  return raw(sid);
}

const abortEventsOf = (sid) => raw(sid).events.filter((e) => e && e.kind === "workflow_aborted");

// handoverEvent(heirSid, extra) — a well-formed workflow_abort_handover event (no seq / at).
function handoverEvent(heirSid, extra) {
  return Object.assign({ kind: "workflow_abort_handover", heir_session_id: heirSid, origin: "adopt-auto", provenance: "declared" }, extra || {});
}
const handoverEventsOf = (sid) => raw(sid).events.filter((e) => e && e.kind === "workflow_abort_handover");

module.exports = {
  ROOT, fwd, rel, mod, io, R, ABORT_MODULE, CTX, statePath, raw, bytes, writeRaw,
  abortEvent, abortModule, seedPlain, pushStep, rawAbort, seedAborted, abortEventsOf,
  handoverEvent, handoverEventsOf,
};
