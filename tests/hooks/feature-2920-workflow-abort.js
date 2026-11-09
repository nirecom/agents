#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/workflow-abort.js, hooks/workflow-state.js
// Tags: TL2, workflow-state, workflow-abort, event-stream, regression-2920, scope:issue-specific, pwsh-not-required
// #2920 S1-S3: the workflow_aborted event kind (validation, projection) and the abort module
// (readWorkflowAbort / isWorkflowAborted / recordWorkflowAborted / selectAbortTargets), and the
// workflow_abort_handover that names the downstream of an adopted abort-sentinel abort.
// TL3 gap (what this test does NOT catch):
// - the sentinel / adopt / CLI entry points that call recordWorkflowAborted (other #2920 files).
// - a real release-to-release upgrade; the old release is an in-memory projection.js copy
//   with the workflow_aborted case cut out.

const { test, after } = require("node:test");
const assert = require("node:assert");
const { spawn } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const path = require("path");

const restore = isolate();
after(() => restore());

const X = require("./feature-2920-workflow-abort/fixture");
const ev = () => X.mod("hooks/workflow-state/state-io/events");
const proj = () => X.mod("hooks/workflow-state/state-io/projection");
const A = () => X.abortModule();

const at = "2026-11-04T00:00:00.000Z";
const withAt = (e) => Object.assign({ at }, e);
const valid = {
  "abort-sentinel": () => withAt(X.abortEvent("abort-sentinel")),
  "adopt-auto": () => withAt(X.abortEvent("adopt-auto")),
  "abort-cli": () => withAt(X.abortEvent("abort-cli")),
};
// rejects(base, patch) — the valid base passes validateEvent, and the patched copy is refused.
function rejects(base, patch, what) {
  ev().validateEvent(base);
  const bad = Object.assign({}, base, patch);
  for (const k of Object.keys(patch)) if (patch[k] === undefined) delete bad[k];
  assert.throws(() => ev().validateEvent(bad), (e) => e instanceof ev().InvalidEventError, what);
  return bad;
}
// streamOf(...events) — a synthetic state whose events carry seq 1..n.
function streamOf(events, top) {
  return Object.assign({ events: events.map((e, i) => Object.assign({ at, seq: i + 1 }, e)) }, top || {});
}
const stepEv = (step, status) => ({ kind: "step_status", step, status, provenance: "observed", origin: "fixture-2920" });

caseBegin("event-kind-and-origins", "hooks/workflow-state/state-io/events.js");
test("S1: EVENT_KINDS lists workflow_aborted and REQUIRED_FIELDS names reason", () => {
  assert.ok(ev().EVENT_KINDS.includes("workflow_aborted"), "EVENT_KINDS");
  assert.deepStrictEqual(ev().REQUIRED_FIELDS.workflow_aborted, ["reason"]);
});
test("S1: ABORT_ORIGINS is the three origins, frozen", () => {
  assert.deepStrictEqual(ev().ABORT_ORIGINS, ["abort-sentinel", "adopt-auto", "abort-cli"]);
  assert.ok(Object.isFrozen(ev().ABORT_ORIGINS), "frozen");
});
test("S1: each origin's well-formed event passes validateEvent", () => {
  for (const o of Object.keys(valid)) ev().validateEvent(valid[o]());
});
caseEnd();

caseBegin("event-validation-rejects", "hooks/workflow-state/state-io/events.js");
test("S1: an empty or blank reason is refused", () => {
  rejects(valid["abort-sentinel"](), { reason: "" }, "empty");
  rejects(valid["abort-sentinel"](), { reason: "   \t" }, "blank");
  rejects(valid["abort-sentinel"](), { reason: 42 }, "non-string");
  rejects(valid["abort-sentinel"](), { reason: undefined }, "missing");
});
test("S1: an origin outside ABORT_ORIGINS is refused", () => {
  rejects(valid["abort-sentinel"](), { origin: "session-inherit" }, "foreign origin");
});
test("S1: adopt-auto / abort-cli need a valid downstream_session_id", () => {
  for (const o of ["adopt-auto", "abort-cli"]) {
    rejects(valid[o](), { downstream_session_id: undefined }, `${o} without downstream`);
    rejects(valid[o](), { downstream_session_id: "../escape" }, `${o} traversal downstream`);
    rejects(valid[o](), { downstream_session_id: "" }, `${o} empty downstream`);
  }
});
test("S1: abort-sentinel must not carry downstream_session_id", () => {
  rejects(valid["abort-sentinel"](), { downstream_session_id: "downstream-2920" }, "sentinel with downstream");
});
test("S1 security: the refusal names fields, never the injected value", () => {
  const payload = "x$(touch /tmp/pwn)`id`\n\u0007" + "A".repeat(5000);
  const bad = rejects(valid["adopt-auto"](), { downstream_session_id: payload }, "injected downstream");
  try { ev().validateEvent(bad); } catch (e) {
    assert.ok(!String(e.message).includes("$(touch"), "message carries the value");
    assert.ok(String(e.message).length < 500, "message length");
  }
});
caseEnd();

caseBegin("projection-fold", "hooks/workflow-state/state-io/projection.js");
test("S2: PROJECTION_KEYS lists workflow_aborted and a fresh state projects null", () => {
  assert.ok(proj().PROJECTION_KEYS.includes("workflow_aborted"), "PROJECTION_KEYS");
  assert.strictEqual(proj().projectState(streamOf([stepEv("workflow_init", "complete")])).workflow_aborted, null);
});
test("S2: an abort projects {origin, reason, downstream_session_id, recorded_at, seq}", () => {
  const p = proj().projectState(streamOf([stepEv("workflow_init", "complete"), X.abortEvent("adopt-auto")])).workflow_aborted;
  assert.ok(p && typeof p === "object", `projection: ${JSON.stringify(p)}`);
  assert.deepStrictEqual([p.origin, p.reason, p.downstream_session_id, p.recorded_at, p.seq], ["adopt-auto", "test abort", "downstream-2920", at, 2]);
});
test("S2: first-wins — a second abort does not replace the first", () => {
  const s = streamOf([X.abortEvent("abort-sentinel", { reason: "first" }), X.abortEvent("abort-cli", { reason: "second" })]);
  const p = proj().projectState(s).workflow_aborted;
  assert.deepStrictEqual(p && [p.origin, p.reason, p.seq], ["abort-sentinel", "first", 1]);
});
test("S2: an abort at or below upstream_copy_seq is ignored; one above it counts", () => {
  const evs = [stepEv("workflow_init", "complete"), X.abortEvent("abort-sentinel"), stepEv("research", "skipped")];
  assert.strictEqual(proj().projectState(streamOf(evs, { upstream_copy_seq: 2 })).workflow_aborted, null, "copied abort");
  const later = proj().projectState(streamOf(evs.concat([X.abortEvent("abort-cli")]), { upstream_copy_seq: 3 })).workflow_aborted;
  assert.deepStrictEqual(later && [later.origin, later.seq], ["abort-cli", 4], "own abort");
});
test("S2: cycle_boundary and reset do not clear the abort", () => {
  const s = streamOf([
    X.abortEvent("abort-sentinel"),
    { kind: "cycle_boundary", closed_cycle: 1, reason: "reinit-entry", provenance: "observed", origin: "fixture-2920" },
    { kind: "reset", from_step: "research", reason: "fixture", provenance: "declared", origin: "fixture-2920" },
  ]);
  const p = proj().projectState(s).workflow_aborted;
  assert.deepStrictEqual(p && [p.origin, p.seq], ["abort-sentinel", 1]);
});
test("S2: stripProjection drops workflow_aborted before persist", () => {
  const out = proj().stripProjection({ session_id: "s", events: [], workflow_aborted: { origin: "abort-cli" } });
  assert.ok(!("workflow_aborted" in out), "persisted copy carries the projection");
  assert.ok(proj().PROJECTION_KEYS.includes("workflow_aborted"), "PROJECTION_KEYS");
});
caseEnd();

// oldReleaseProjection() — an in-memory copy of projection.js with the workflow_aborted fold case cut
// out (an old release's projection), compiled at the real path so its relative requires resolve.
const NEW_CASE_RE = /\n[ \t]*case "workflow_aborted":[\s\S]*?(?=\n[ \t]*(?:case "|default:))/;
function oldReleaseProjection() {
  const Module = require("module");
  const file = path.join(X.ROOT, "hooks", "workflow-state", "state-io", "projection.js");
  const src = fs.readFileSync(file, "utf8");
  assert.ok(NEW_CASE_RE.test(src), "projection.js has no case \"workflow_aborted\" to cut (S2 not implemented)");
  const m = new Module(file, module);
  m.filename = file;
  m.paths = Module._nodeModulePaths(path.dirname(file));
  m._compile(src.replace(NEW_CASE_RE, ""), file);
  return m.exports;
}
caseBegin("old-release-compat", "hooks/workflow-state/state-io/projection.js");
test("compat: a projection without the workflow_aborted case reads an aborted stream without throwing", () => {
  const old = oldReleaseProjection();
  assert.ok(!NEW_CASE_RE.test(old.projectState.toString()), "the copy still knows the kind");
  const s = streamOf([stepEv("workflow_init", "complete"), X.abortEvent("abort-sentinel"), stepEv("research", "skipped")]);
  assert.doesNotThrow(() => old.assertStreamIntegrity(s.events), "assertStreamIntegrity of the copy");
  let p;
  assert.doesNotThrow(() => { p = old.projectState(s); }, "projectState of the copy");
  assert.strictEqual(p.steps.research.status, "skipped", "steps after the abort still fold");
  assert.ok(p.workflow_aborted === undefined || p.workflow_aborted === null, `the copy reads "not aborted": ${JSON.stringify(p.workflow_aborted)}`);
  // Control: the current projection does read the same stream as aborted.
  assert.strictEqual((proj().projectState(s).workflow_aborted || {}).origin, "abort-sentinel", "current projection");
});
test("compat: the copy also reads an adopt-auto abort (with downstream_session_id) without throwing", () => {
  assert.ok(ev().EVENT_KINDS.includes("workflow_aborted"), "the current EVENT_KINDS must list the kind the copy drops");
  const old = oldReleaseProjection();
  const s = streamOf([stepEv("workflow_init", "complete"), X.abortEvent("adopt-auto"), stepEv("research", "skipped")]);
  assert.doesNotThrow(() => old.assertStreamIntegrity(s.events));
  assert.strictEqual(old.projectState(s).steps.research.status, "skipped");
});
caseEnd();

caseBegin("read-and-predicate", "hooks/workflow-state/workflow-abort.js");
test("S3: isWorkflowAborted / readWorkflowAbort on an aborted state", () => {
  X.seedAborted("rp-aborted", "abort-sentinel");
  assert.strictEqual(A().isWorkflowAborted("rp-aborted"), true);
  const r = A().readWorkflowAbort("rp-aborted");
  assert.deepStrictEqual(r && [r.origin, r.reason], ["abort-sentinel", "test abort"]);
  const byState = A().readWorkflowAbort(X.io().readState("rp-aborted"));
  assert.deepStrictEqual(byState && byState.origin, "abort-sentinel", "state argument");
});
test("S3: isWorkflowAborted is false (never throws) for plain, absent, corrupt and bad sids", () => {
  assert.strictEqual(A().isWorkflowAborted("rp-aborted"), true, "control");
  X.seedPlain("rp-plain");
  fs.writeFileSync(X.statePath("rp-corrupt"), "{not json");
  for (const sid of ["rp-plain", "rp-absent", "rp-corrupt", "../rp-aborted", "a/b", "", null, undefined, 7, "x".repeat(4096)]) {
    assert.strictEqual(A().isWorkflowAborted(sid), false, `sid ${JSON.stringify(sid)}`);
  }
  assert.strictEqual(A().readWorkflowAbort("rp-plain"), null, "plain");
  assert.strictEqual(A().readWorkflowAbort("../rp-aborted"), null, "traversal");
});
test("S3: hooks/workflow-state.js re-exports the four functions", () => {
  const wf = X.mod("hooks/workflow-state");
  for (const n of ["isWorkflowAborted", "readWorkflowAbort", "recordWorkflowAborted", "selectAbortTargets",
    "selectHandoverTargets", "recordAbortHandover", "abortUpstreamsFor"]) {
    assert.strictEqual(typeof wf[n], "function", n);
    assert.strictEqual(wf[n], A()[n], `${n} is the same function`);
  }
});
caseEnd();

caseBegin("record-outcomes", "hooks/workflow-state/workflow-abort.js");
test("S3: recording on a started state appends one declared event", () => {
  X.seedPlain("rec-ok");
  const r = A().recordWorkflowAborted("rec-ok", { reason: "user stopped", origin: "abort-sentinel" });
  assert.strictEqual(r && r.recorded, true, JSON.stringify(r));
  const evs = X.abortEventsOf("rec-ok");
  assert.deepStrictEqual(evs.map((e) => [e.origin, e.reason, e.provenance, "downstream_session_id" in e]), [["abort-sentinel", "user stopped", "declared", false]]);
  assert.strictEqual(A().isWorkflowAborted("rec-ok"), true);
});
test("S3: an adopt-auto record carries the downstream sid", () => {
  X.seedPlain("rec-downstream");
  const r = A().recordWorkflowAborted("rec-downstream", { reason: "adopted by downstream-1", origin: "adopt-auto", downstreamSid: "downstream-1" });
  assert.strictEqual(r && r.recorded, true, JSON.stringify(r));
  assert.deepStrictEqual(X.abortEventsOf("rec-downstream").map((e) => e.downstream_session_id), ["downstream-1"]);
});
test("S3: no state -> no-state, and no file is created", () => {
  const r = A().recordWorkflowAborted("rec-none", { reason: "x", origin: "abort-sentinel" });
  assert.deepStrictEqual(r && [r.recorded, r.reason], [false, "no-state"]);
  assert.strictEqual(fs.existsSync(X.statePath("rec-none")), false, "state file created");
});
test("S3 idempotency: a second abort is already-aborted and the first wins", () => {
  X.seedPlain("rec-twice");
  A().recordWorkflowAborted("rec-twice", { reason: "first", origin: "abort-sentinel" });
  const r = A().recordWorkflowAborted("rec-twice", { reason: "second", origin: "abort-cli", downstreamSid: "downstream-2" });
  assert.deepStrictEqual(r && [r.recorded, r.reason], [false, "already-aborted"]);
  assert.deepStrictEqual(X.abortEventsOf("rec-twice").map((e) => e.reason), ["first"]);
});
test("S3: a delivered state (merge_to_main complete) -> delivered, nothing written", () => {
  X.seedPlain("rec-delivered");
  X.pushStep("rec-delivered", "merge_to_main", "complete");
  const before = X.bytes("rec-delivered");
  const r = A().recordWorkflowAborted("rec-delivered", { reason: "x", origin: "abort-sentinel" });
  assert.deepStrictEqual(r && [r.recorded, r.reason], [false, "delivered"]);
  assert.strictEqual(X.bytes("rec-delivered"), before, "state bytes changed");
  assert.strictEqual(A().isWorkflowAborted("rec-delivered"), false);
});
test("S3 security: a traversal sid records nothing and writes no file", () => {
  const outside = path.join(path.dirname(process.env.WORKFLOW_STATE_DIR), "escaped.json");
  X.seedPlain("rec-guard");
  const r = A().recordWorkflowAborted("../escaped", { reason: "x", origin: "abort-sentinel" });
  assert.strictEqual(r && r.recorded, false, JSON.stringify(r));
  assert.strictEqual(fs.existsSync(outside), false, "file written outside the state dir");
});
caseEnd();

caseBegin("record-concurrency", "hooks/workflow-state/workflow-abort.js");
function recordInChild(sid, reason) {
  const code = `const m=require(${JSON.stringify(X.rel(X.ABORT_MODULE))});` +
    "process.stdout.write(JSON.stringify(m.recordWorkflowAborted(process.argv[1],{reason:process.argv[2],origin:'abort-sentinel'})));";
  return new Promise((resolve) => {
    const env = Object.assign({}, process.env);
    delete env.CLAUDE_CODE_SESSION_ID;
    const c = spawn(process.execPath, ["-e", code, sid, reason], { env, cwd: process.env.WORKFLOW_STATE_DIR });
    let out = "";
    let err = "";
    c.stdout.on("data", (d) => { out += d; });
    c.stderr.on("data", (d) => { err += d; });
    c.on("close", (status) => resolve({ status, out, err }));
  });
}
test("S3: two processes racing on one sid record exactly one abort", { timeout: 60000 }, async () => {
  X.seedPlain("rec-race");
  const rs = await Promise.all([recordInChild("rec-race", "racer-1"), recordInChild("rec-race", "racer-2")]);
  for (const r of rs) assert.strictEqual(r.status, 0, r.err);
  const outs = rs.map((r) => JSON.parse(r.out));
  assert.deepStrictEqual(outs.map((o) => o.recorded).sort(), [false, true], JSON.stringify(outs));
  assert.strictEqual(X.abortEventsOf("rec-race").length, 1, "abort events");
  X.mod("hooks/workflow-state/state-io/projection").assertStreamIntegrity(X.raw("rec-race").events);
});
caseEnd();

caseBegin("select-targets", "hooks/workflow-state/workflow-abort.js");
const sids = (list) => (Array.isArray(list) ? list.map((t) => (typeof t === "string" ? t : t && t.sid)) : list);
function chain(prefix, opts) {
  const o = opts || {};
  const [a, b, c] = [`${prefix}-a`, `${prefix}-b`, `${prefix}-c`];
  X.seedPlain(a);
  if (o.aDelivered) X.pushStep(a, "merge_to_main", "complete");
  X.seedPlain(b);
  if (o.bAborted) X.rawAbort(b, "abort-sentinel");
  X.seedPlain(c);
  const s = X.raw(c);
  Object.assign(s, { previous_session_ids: [a, b], upstream_session_id: b, first_session_id: a });
  X.writeRaw(c, s);
  return { a, b, c };
}
test("S3: C->B->A with A delivered selects only B, and writes nothing", () => {
  const { a, b, c } = chain("sel1", { aDelivered: true });
  const before = [a, b, c].map(X.bytes);
  assert.deepStrictEqual(sids(A().selectAbortTargets(X.io().readState(c))), [b]);
  assert.deepStrictEqual([a, b, c].map(X.bytes), before, "selectAbortTargets wrote");
});
test("S3: undelivered, unaborted ancestors are all selected, oldest first; self never", () => {
  const { a, b, c } = chain("sel2");
  const got = sids(A().selectAbortTargets(X.io().readState(c)));
  assert.deepStrictEqual(got, [a, b]);
  assert.ok(!got.includes(c), "self selected");
});
test("S3: an already-aborted ancestor is not selected", () => {
  const { a, c } = chain("sel3", { bAborted: true });
  assert.deepStrictEqual(sids(A().selectAbortTargets(X.io().readState(c))), [a]);
});
test("S3: a state without ancestors selects nothing", () => {
  X.seedPlain("sel-root");
  assert.deepStrictEqual(sids(A().selectAbortTargets(X.io().readState("sel-root"))), []);
});
caseEnd();

// A downstream adopting an abort-sentinel-aborted session takes over its worktree: the
// workflow_abort_handover event names it, and the projection fills downstream_session_id from it.
caseBegin("handover-event", "hooks/workflow-state/state-io/events.js");
test("handover: the kind is listed, requires downstream_session_id, and only downstream-naming origins pass", () => {
  assert.ok(ev().EVENT_KINDS.includes("workflow_abort_handover"), "EVENT_KINDS");
  assert.deepStrictEqual(ev().REQUIRED_FIELDS.workflow_abort_handover, ["downstream_session_id"]);
  for (const origin of ["adopt-auto", "abort-cli"]) ev().validateEvent(withAt(X.handoverEvent("downstream-1", { origin })));
  const base = withAt(X.handoverEvent("downstream-1"));
  rejects(base, { origin: "abort-sentinel" }, "sentinel origin");
  rejects(base, { origin: "session-inherit" }, "foreign origin");
  rejects(base, { downstream_session_id: undefined }, "no downstream");
  rejects(base, { downstream_session_id: "../escape" }, "traversal downstream");
});
caseEnd();

caseBegin("handover-projection", "hooks/workflow-state/state-io/projection.js");
test("handover: fills downstream_session_id of a sentinel abort; origin/reason/seq stay first-wins", () => {
  const p = proj().projectState(streamOf([X.abortEvent("abort-sentinel", { reason: "first" }), X.handoverEvent("down-1")])).workflow_aborted;
  assert.deepStrictEqual(p && [p.origin, p.reason, p.seq, p.downstream_session_id], ["abort-sentinel", "first", 1, "down-1"]);
});
test("handover: ignored without an abort, after a downstream is named, and at or below upstream_copy_seq", () => {
  assert.strictEqual(proj().projectState(streamOf([X.handoverEvent("down-1")])).workflow_aborted, null, "no abort");
  const twice = proj().projectState(streamOf([X.abortEvent("abort-sentinel"), X.handoverEvent("down-1"), X.handoverEvent("down-2")])).workflow_aborted;
  assert.strictEqual(twice && twice.downstream_session_id, "down-1", "first handover wins");
  const b = proj().projectState(streamOf([X.abortEvent("adopt-auto"), X.handoverEvent("down-1")])).workflow_aborted;
  assert.strictEqual(b && b.downstream_session_id, "downstream-2920", "an adopt-auto downstream is kept");
  const copied = streamOf([stepEv("workflow_init", "complete"), X.abortEvent("abort-sentinel"), X.handoverEvent("down-1")], { upstream_copy_seq: 3 });
  assert.strictEqual(proj().projectState(copied).workflow_aborted, null, "copied abort and handover");
});
caseEnd();

caseBegin("handover-record-and-select", "hooks/workflow-state/workflow-abort.js");
test("handover: recordAbortHandover names the downstream once on a sentinel abort", () => {
  X.seedAborted("ho-ok", "abort-sentinel");
  const r = A().recordAbortHandover("ho-ok", { origin: "adopt-auto", downstreamSid: "down-ok" });
  assert.deepStrictEqual(r && [r.recorded, r.reason], [true, null], JSON.stringify(r));
  assert.strictEqual(A().readWorkflowAbort("ho-ok").downstream_session_id, "down-ok");
  const again = A().recordAbortHandover("ho-ok", { origin: "adopt-auto", downstreamSid: "down-2" });
  assert.deepStrictEqual(again && [again.recorded, again.reason], [false, "already-handed-over"]);
  assert.strictEqual(X.handoverEventsOf("ho-ok").length, 1, "handover events");
});
test("handover: refused on a live, a scenario-B, and an absent session; nothing written", () => {
  X.seedPlain("ho-live");
  X.seedAborted("ho-b", "adopt-auto");
  const before = ["ho-live", "ho-b"].map(X.bytes);
  assert.strictEqual(A().recordAbortHandover("ho-live", { origin: "adopt-auto", downstreamSid: "d" }).reason, "not-aborted");
  assert.strictEqual(A().recordAbortHandover("ho-b", { origin: "adopt-auto", downstreamSid: "d" }).reason, "already-handed-over");
  assert.deepStrictEqual(["ho-live", "ho-b"].map(X.bytes), before, "state bytes changed");
  assert.strictEqual(A().recordAbortHandover("ho-none", { origin: "adopt-auto", downstreamSid: "d" }).reason, "no-state");
  assert.strictEqual(fs.existsSync(X.statePath("ho-none")), false, "state file created");
});
test("handover: selectHandoverTargets picks only unclaimed sentinel-aborted ancestors", () => {
  const { b, c } = chain("ho-sel", { bAborted: true });
  assert.deepStrictEqual(sids(A().selectHandoverTargets(X.io().readState(c))), [b]);
  A().recordAbortHandover(b, { origin: "adopt-auto", downstreamSid: c });
  assert.deepStrictEqual(sids(A().selectHandoverTargets(X.io().readState(c))), [], "after the handover");
});
test("handover: abortUpstreamsFor aborts the live ancestor and hands over the sentinel-aborted one", () => {
  const { a, b, c } = chain("ho-all", { bAborted: true });
  const got = A().abortUpstreamsFor(c, "abort-cli", "fixture");
  assert.deepStrictEqual(got.map((r) => [r.sid, !!r.handover, r.recorded]), [[a, false, true], [b, true, true]], JSON.stringify(got));
  assert.deepStrictEqual([a, b].map((s) => A().readWorkflowAbort(s).downstream_session_id), [c, c]);
  assert.strictEqual(A().readWorkflowAbort(b).origin, "abort-sentinel", "origin stays first-wins");
});
caseEnd();
