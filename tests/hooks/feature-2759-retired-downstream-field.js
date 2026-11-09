#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/workflow-abort.js, bin/workflow/lib/next-step/quiet-exits.js
// Tags: TL2, workflow-state, workflow-abort, event-stream, migration, scope:issue-specific, pwsh-not-required
// #2759: the retired field of the abort events is still read from a stored stream and refused on
// every write; its spelling lives only in the temporary block below.
// TL3 gap (what this test does NOT catch):
// - a real state file of a release older than this change; the old events here are pushed raw.
// - the adopt and abort entry points that call workflow-abort.js (tests/bin/feature-2920-*).

const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const HOME_CWD = process.cwd();
const NEUTRAL = fs.mkdtempSync(path.join(os.tmpdir(), "f2759-field-"));
process.chdir(NEUTRAL);
after(() => {
  process.chdir(HOME_CWD);
  fs.rmSync(NEUTRAL, { recursive: true, force: true });
  restore();
});

const X = require("./feature-2920-workflow-abort/fixture");

// --- BEGIN temporary: retired-downstream-field -> downstream_session_id migration added 2026-11-07 ---
// deletion-condition: remove once 30 days (STATE_RETENTION_DAYS) have passed since merge and a grep of *.json under the state root and the old state dir for LEGACY_DOWNSTREAM_FIELD's value finds nothing; review by 2027-02-05
const OLD = "heir_session_id";
// --- END temporary: retired-downstream-field -> downstream_session_id migration ---

const NEW = "downstream_session_id";
const SECRET = "fixture-secret-value";
const AT = "2026-11-07T00:00:00.000Z";
const ev = () => X.mod("hooks/workflow-state/state-io/events");
const A = () => X.abortModule();
const quiet = () => X.mod("bin/workflow/lib/next-step/quiet-exits");
const apply = () => X.mod("hooks/workflow-state/inheritance/apply");

const named = (field, value) => ({ [field]: value });
const abortOf = (field, value) => Object.assign({ kind: "workflow_aborted", reason: "r", origin: "adopt-auto", provenance: "declared", at: AT }, field ? named(field, value) : {});
const sentinelAbort = () => ({ kind: "workflow_aborted", reason: "r", origin: "abort-sentinel", provenance: "declared", at: AT });
const handoverOf = (field, value) => Object.assign({ kind: "workflow_abort_handover", origin: "adopt-auto", provenance: "declared", at: AT }, named(field, value));
const seed = (sid, events) => {
  X.seedPlain(sid);
  if (events) X.R().pushEvents(sid, events);
};
const onDisk = (sid) => X.bytes(sid);
const annotation = { kind: "step_annotation", step: "research", key: "token", value: "t1", provenance: "observed", origin: "f2759" };

caseBegin("stored-retired-field-is-readable", "hooks/workflow-state/state-io/projection.js");
test("C1 a stored old abort and an old handover read under the new name, without the old key", () => {
  seed("c1-abort", [abortOf(OLD, "down-c1")]);
  const state = X.io().readState("c1-abort");
  assert.ok(state, "readState returns the state");
  assert.strictEqual(state.current.workflow_aborted[NEW], "down-c1");
  assert.ok(!Object.keys(state.current.workflow_aborted).includes(OLD), "the old key is not projected");
  seed("c1-handover", [sentinelAbort(), handoverOf(OLD, "down-c1h")]);
  assert.strictEqual(X.io().readState("c1-handover").current.workflow_aborted[NEW], "down-c1h");
});
test("C1 a file with the old key outside the exclusion still reads", () => {
  seed("c1-nested");
  const r = X.raw("c1-nested");
  r.session_start_context.nested = named(OLD, SECRET);
  X.writeRaw("c1-nested", r);
  assert.ok(X.io().readState("c1-nested"), "readState returns the state");
});
caseEnd();

caseBegin("existing-session-append", "hooks/workflow-state/state-io/projection.js");
test("C2 an old event and an old current accept an append; the event stays and current drops the key", () => {
  const sid = "c2-append";
  seed(sid, [abortOf(OLD, "down-c2")]);
  const r = X.raw(sid);
  r.current = { workflow_aborted: named(OLD, "down-c2") };
  X.writeRaw(sid, r);
  X.io().appendEvents(sid, annotation);
  const after2 = X.raw(sid);
  assert.strictEqual(after2.events.find((e) => e.kind === "workflow_aborted")[OLD], "down-c2", "the stored event stays");
  assert.ok(after2.events.some((e) => e.kind === "step_annotation" && e.key === "token"), "the new event is there");
  assert.ok(!JSON.stringify(after2.current).includes(OLD), "the written current has no old key");
  assert.strictEqual(after2.current.workflow_aborted[NEW], "down-c2");
});
caseEnd();

// Each scenario places key k in one location: on disk first (`disk`) or through the write's patch.
const REFUSED_PLACES = [
  ["session_start_context nested", { patch: (r, k) => { r.session_start_context.nested = named(k, SECRET); } }],
  ["another top-level key, nested", { patch: (r, k) => { r.merge_base_baseline = { nested: named(k, SECRET) }; } }],
  ["a non-abort event key", { disk: (k) => Object.assign({ kind: "step_status", step: "research", status: "in_progress", provenance: "observed", origin: "f2759" }, named(k, SECRET)) }],
  ["an abort event's nested key", { disk: (k) => Object.assign(abortOf(NEW, "down-c3"), { detail: named(k, SECRET) }) }],
  ["an object naming an abort kind inside session_start_context", { patch: (r, k) => { r.session_start_context.nested = Object.assign({ kind: "workflow_aborted" }, named(k, SECRET)); } }],
];
function attemptWrite(sid, place, key) {
  seed(sid, place.disk ? [place.disk(key)] : undefined);
  const before = onDisk(sid);
  return { before, write: () => X.io().updateTopLevel(sid, (r) => { if (place.patch) place.patch(r, key); }) };
}

caseBegin("scan-refuses-retired-key", "hooks/workflow-state/state-io/projection.js");
REFUSED_PLACES.forEach(([label, place], i) => {
  test(`C3 ${label}: refused with the key name alone, and the file keeps every byte`, () => {
    attemptWrite(`c3-control-${i}`, place, "fixture_key").write();
    assert.ok(onDisk(`c3-control-${i}`).includes("fixture_key"), "the control key is written");
    const sid = `c3-refused-${i}`;
    const { before, write } = attemptWrite(sid, place, OLD);
    assert.throws(write, (e) => {
      assert.ok(e instanceof X.io().UnknownStateKeyError, `${e && e.name}: ${e && e.message}`);
      assert.ok(e.message.includes(OLD), `names the key: ${e.message}`);
      assert.ok(!e.message.includes(SECRET), `carries no value: ${e.message}`);
      return true;
    });
    assert.strictEqual(onDisk(sid), before, "the file is unchanged");
  });
});
caseEnd();

caseBegin("refused-session-exit", "hooks/workflow-state/state-io/projection.js");
test("C4 removing the key after a refusal lets the write through", () => {
  const sid = "c4-exit";
  seed(sid);
  const r = X.raw(sid);
  r.session_start_context.nested = named(OLD, SECRET);
  X.writeRaw(sid, r);
  const before = onDisk(sid);
  assert.throws(() => X.io().updateTopLevel(sid, () => {}), (e) => e instanceof X.io().UnknownStateKeyError);
  assert.strictEqual(onDisk(sid), before, "the refusal changes nothing");
  X.io().updateTopLevel(sid, (rec) => { delete rec.session_start_context.nested; });
  assert.ok(!onDisk(sid).includes(OLD), "the key is gone");
  assert.ok(X.io().readState(sid), "the state still reads");
});
caseEnd();

caseBegin("copy-of-session-upstream", "hooks/workflow-state/state-io/projection.js");
test("C5 an old event in a session-upstream copies, and the copy has no old key", () => {
  seed("c5-up", [abortOf(OLD, "down-c5")]);
  const r = X.raw("c5-up");
  r.current = { workflow_aborted: named(OLD, "down-c5") };
  X.writeRaw("c5-up", r);
  apply().applyInheritance("c5-down", AT, "c5-up");
  assert.ok(onDisk("c5-down"), "the copy is written");
  assert.ok(!onDisk("c5-down").includes(OLD), "no old key in the copy");
});
test("C5 a nested old key in a session-upstream refuses the copy and writes nothing", () => {
  seed("c5-ctl-up");
  const ctl = X.raw("c5-ctl-up");
  ctl.session_start_context.nested = named("fixture_key", SECRET);
  X.writeRaw("c5-ctl-up", ctl);
  apply().applyInheritance("c5-ctl-down", AT, "c5-ctl-up");
  assert.ok(onDisk("c5-ctl-down"), "the control copy is written");
  seed("c5-bad-up");
  const bad = X.raw("c5-bad-up");
  bad.session_start_context.nested = named(OLD, SECRET);
  X.writeRaw("c5-bad-up", bad);
  assert.throws(() => apply().applyInheritance("c5-bad-down", AT, "c5-bad-up"), (e) => e instanceof X.io().UnknownStateKeyError);
  assert.strictEqual(onDisk("c5-bad-down"), null, "the copy target is not written");
});
caseEnd();

function bothShapes(prefix, build) {
  const [newSid, oldSid] = [`${prefix}-new`, `${prefix}-old`];
  seed(newSid, build(NEW));
  seed(oldSid, build(OLD));
  return [newSid, oldSid];
}
caseBegin("old-and-new-read-alike", "bin/workflow/lib/next-step/quiet-exits.js");
for (const [label, prefix, build] of [
  ["abort", "c6-abort", (f) => [abortOf(f, "down-c6")]],
  ["handover", "c6-handover", (f) => [sentinelAbort(), handoverOf(f, "down-c6")]],
]) {
  test(`C6 ${label}: the read and the next-step verdict match between the two shapes`, () => {
    const [newSid, oldSid] = bothShapes(prefix, build);
    const newAbort = A().readWorkflowAbort(newSid);
    assert.strictEqual(newAbort && newAbort[NEW], "down-c6", "the new shape reads");
    assert.deepStrictEqual(A().readWorkflowAbort(oldSid), newAbort);
    const newExit = quiet().resolveQuietExit(newSid, X.io().readState(newSid));
    assert.strictEqual(newExit && newExit.action, "done", "a named downstream ends the session");
    assert.ok(newExit.hint.includes("down-c6"), newExit.hint);
    assert.deepStrictEqual(quiet().resolveQuietExit(oldSid, X.io().readState(oldSid)), newExit);
  });
}
caseEnd();

caseBegin("new-field-wins-over-old", "hooks/workflow-state/state-io/projection.js");
test("C7 an event with both fields reads the new one", () => {
  seed("c7-abort", [Object.assign(abortOf(NEW, "down-new"), named(OLD, "down-old"))]);
  assert.strictEqual(A().readWorkflowAbort("c7-abort")[NEW], "down-new", "abort");
  seed("c7-handover", [sentinelAbort(), Object.assign(handoverOf(NEW, "down-new"), named(OLD, "down-old"))]);
  assert.strictEqual(A().readWorkflowAbort("c7-handover")[NEW], "down-new", "handover");
});
caseEnd();

const SAMPLE = {
  step_status: { step: "research", status: "complete" },
  step_annotation: { step: "research", key: "token", value: "t1" },
  step_annotations_cleared: { step: "research" },
  worktree: { transition: "entered", git_branch: "fix/x", cwd: "/w", worktree_path: "/w", path_source: "tool_input" },
  session_model: { id: "model-fixture", source: "stop-hook" },
  complexity_evaluation: { level: "high", signals: ["S2-architecture"] },
  plan_approval: { step: "detail", source: "confirm-sentinel", reason: "approved", artifact_sha256: "ab12", artifact_session_id: "sfix", artifact_hash_status: "match" },
  plan_approval_revoked: { step: "detail", reason: "artifact changed" },
  reset: { from_step: "detail", reason: "user asked" },
  state_handoff_record: { cls: "A", origin: "auto-record", at_step: "-", record_key: "voc:k1", summary: "s", pointer: "p" },
  cycle_boundary: { closed_cycle: 1, reason: "reinit-entry" },
  workflow_aborted: { reason: "user stopped", origin: "abort-sentinel" },
  workflow_abort_handover: { [NEW]: "down-fixture", origin: "adopt-auto" },
};
const eventOf = (kind, over) => Object.assign({ kind, provenance: "observed", origin: "f2759" }, SAMPLE[kind], over);
const FORMS = Object.keys(SAMPLE).map((kind) => [kind, eventOf(kind)]).concat([
  ["workflow_aborted adopt-auto", eventOf("workflow_aborted", { origin: "adopt-auto", [NEW]: "down-fixture" })],
  ["workflow_aborted abort-cli", eventOf("workflow_aborted", { origin: "abort-cli", [NEW]: "down-fixture" })],
  ["workflow_abort_handover abort-cli", eventOf("workflow_abort_handover", { origin: "abort-cli" })],
]);
const without = (event, field) => { const c = Object.assign({}, event); delete c[field]; return c; };
const carriesNew = (event) => Object.prototype.hasOwnProperty.call(event, NEW);
// abort-sentinel refuses the new field for a reason of its own, so that form has no second control.
const newFieldAllowed = (event) => !(event.kind === "workflow_aborted" && event.origin === "abort-sentinel");

// The reason is what separates this refusal from the older checks that also throw on a bad field.
function assertRetiredRefusal(fn, what) {
  assert.throws(fn, (e) => {
    assert.ok(e instanceof ev().InvalidEventError, `${what}: ${e && e.name}: ${e && e.message}`);
    assert.match(e.message, /retired/i, `${what}: the reason is the retired field`);
    assert.ok(/downstream/i.test(e.message) || e.message.includes(OLD), `${what}: identifies the field: ${e.message}`);
    assert.ok(!e.message.includes(SECRET), `${what}: carries no value: ${e.message}`);
    return true;
  }, what);
}

caseBegin("every-kind-refuses-retired-field", "hooks/workflow-state/state-io/events.js");
test("C8 the table covers every EVENT_KINDS entry", () => {
  assert.deepStrictEqual(Object.keys(SAMPLE).sort(), [...ev().EVENT_KINDS].sort());
});
for (const [label, base] of FORMS) {
  test(`C8 ${label}: accepted without the old field, refused with it for that reason`, () => {
    const bare = without(base, NEW);
    assert.doesNotThrow(() => ev().validateEvent(Object.assign({}, base)), "control");
    assertRetiredRefusal(() => ev().validateEvent(Object.assign({}, bare, named(OLD, SECRET))), "old only");
    const withNew = carriesNew(base) ? base : Object.assign({}, base, named(NEW, "down-fixture"));
    if (newFieldAllowed(base)) assert.doesNotThrow(() => ev().validateEvent(Object.assign({}, withNew)), "control with the new field");
    assertRetiredRefusal(() => ev().validateEvent(Object.assign({}, withNew, named(OLD, SECRET))), "new plus old");
  });
}
test("C8 step_annotation: the old name as `key` is refused for that reason; another key passes", () => {
  assert.doesNotThrow(() => ev().validateEvent(eventOf("step_annotation", { key: "fixture_key" })), "control");
  assertRetiredRefusal(() => ev().validateEvent(eventOf("step_annotation", { key: OLD, value: SECRET })), "annotation key");
});
const WRITES = [
  ["step_status", (over) => eventOf("step_status", Object.assign({ status: "in_progress" }, over))],
  ["state_handoff_record", (over) => eventOf("state_handoff_record", over)],
];
for (const [kind, build] of WRITES) {
  test(`C8 appendEvents ${kind}: the control lands, the old field is refused and the file keeps every byte`, () => {
    const sid = `c8-${kind}`;
    seed(sid);
    X.io().appendEvents(sid, build({}));
    assert.ok(X.raw(sid).events.some((e) => e.kind === kind && e.origin !== "workflow-init"), "the control landed");
    const before = onDisk(sid);
    assertRetiredRefusal(() => X.io().appendEvents(sid, build(named(OLD, SECRET))), "old only");
    assertRetiredRefusal(() => X.io().appendEvents(sid, build(Object.assign(named(NEW, "down-fixture"), named(OLD, SECRET)))), "new plus old");
    assert.strictEqual(onDisk(sid), before, "the file is unchanged");
  });
}
test("C8 appendEvents step_annotation: an old-name key is refused and the file keeps every byte", () => {
  const sid = "c8-annotation";
  seed(sid);
  X.io().appendEvents(sid, eventOf("step_annotation", { key: "fixture_key" }));
  assert.ok(X.raw(sid).events.some((e) => e.key === "fixture_key"), "the control landed");
  const before = onDisk(sid);
  assertRetiredRefusal(() => X.io().appendEvents(sid, eventOf("step_annotation", { key: OLD, value: SECRET })), "annotation key");
  assert.strictEqual(onDisk(sid), before, "the file is unchanged");
});
test("C8 step_annotation with a null value: the old-name key is refused for that reason on validate and on append", () => {
  const nullValued = eventOf("step_annotation", { key: OLD, value: null });
  assertRetiredRefusal(() => ev().validateEvent(Object.assign({}, nullValued)), "annotation key, null value, validate");
  const sid = "c8-annotation-null";
  seed(sid);
  X.io().appendEvents(sid, eventOf("step_annotation", { key: "fixture_key", value: null }));
  assert.ok(X.raw(sid).events.some((e) => e.key === "fixture_key"), "the control landed");
  const before = onDisk(sid);
  assertRetiredRefusal(() => X.io().appendEvents(sid, nullValued), "annotation key, null value, append");
  assert.strictEqual(onDisk(sid), before, "the file is unchanged");
});
caseEnd();

caseBegin("new-writes-use-new-field", "hooks/workflow-state/workflow-abort.js");
test("C9 a sentinel abort carries neither field", () => {
  seed("c9-sentinel");
  assert.strictEqual(A().recordWorkflowAborted("c9-sentinel", { reason: "stop", origin: "abort-sentinel" }).recorded, true);
  const [event] = X.abortEventsOf("c9-sentinel");
  assert.ok(!(OLD in event) && !(NEW in event), JSON.stringify(event));
});
test("C9 the abort and the handover name the session-downstream in the new field only", () => {
  seed("c9-live");
  seed("c9-stopped", [sentinelAbort()]);
  seed("c9-down");
  X.R().setTopLevel("c9-down", { previous_session_ids: ["c9-live", "c9-stopped"], upstream_session_id: "c9-stopped" });
  const results = A().abortUpstreamsFor("c9-down", "adopt-auto", "adopted");
  assert.ok(results.every((r) => r.recorded), JSON.stringify(results));
  assert.deepStrictEqual(results.map((r) => r.sid).sort(), ["c9-live", "c9-stopped"]);
  const [aborted] = X.abortEventsOf("c9-live");
  assert.strictEqual(aborted[NEW], "c9-down");
  assert.ok(!(OLD in aborted), "abort event");
  const [handover] = X.handoverEventsOf("c9-stopped");
  assert.strictEqual(handover[NEW], "c9-down");
  assert.ok(!(OLD in handover), "handover event");
});
caseEnd();
