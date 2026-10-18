#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io.js, hooks/lib/supervisor-state-writer/copy.js, hooks/workflow-state/inheritance/adopt.js, hooks/workflow-state/lifecycle.js, hooks/session-start.js, bin/lib/resume-session/render.js
// Tags: TL2, session-inherit, workflow-state, supervisor-state, event-stream, regression-2304, scope:issue-specific, pwsh-not-required
// #2304 (#2633 Step 2a): the session downstream receives a verbatim copy of the session upstream's
// state (only session_id / created_at change), bounded by upstream_copy_seq, with the revert events
// appended after the boundary in one write; the supervisor state is copied beside it.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2304-"));
process.on("exit", () => {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const F = require("./feature-2304-inheritance-state-copy/fixture");
const core = F.mod("hooks/workflow-state/state-io/core");
const writes = [];
const realWriteStateLocked = core.writeStateLocked;
core.writeStateLocked = function spiedWriteStateLocked(sid) {
  writes.push(sid);
  return realWriteStateLocked.apply(this, arguments);
};

let passed = 0;
let failed = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
function throwsIt(fn, what) {
  try { fn(); } catch (e) { return e; }
  throw new Error(`${what}: did not throw`);
}
const apply = () => F.mod("hooks/workflow-state/inheritance/apply");
const DEGRADED = { granularity: "context-independent-only" };
const STEP_FIELDS = ["kind", "step", "status", "key", "value", "provenance", "origin"];
const pick = (e) => STEP_FIELDS.map((k) => (e[k] === undefined ? "" : JSON.stringify(e[k]))).join("|");

caseBegin("verbatim-copy-up-to-the-boundary", "hooks/workflow-state/inheritance/apply.js");
{
  const up = F.seedUpstream("up-verbatim");
  const createdAt = F.seedDownstream("down-verbatim");
  let res = null;
  check("C1: applyInheritance(down, createdAt, upstreamSid) returns the new contract", () => {
    res = apply().applyInheritance("down-verbatim", createdAt, "up-verbatim");
    eq(res && res.upstream_session_id, "up-verbatim", "upstream_session_id");
    eq(res && res.granularity, "full", "granularity");
    eq(Array.isArray(res && res.inherited_steps), true, "inherited_steps is an array");
    eq(res && res.reverted_steps, [], "reverted_steps");
  });
  const down = F.raw("down-verbatim");
  check("C1: every upstream event is copied byte-for-byte (seq, at, origin, artifact_session_id, wsid)", () => {
    eq(down.upstream_copy_seq, up.events.length, "upstream_copy_seq");
    eq(F.pre(down), up.events, "events up to the boundary");
    const wsid = F.pre(down).find((e) => e.kind === "step_annotation" && e.key === "wsid");
    eq(wsid && [wsid.value, wsid.origin, wsid.provenance], ["wsid-up", "mark-step", "observed"], "wsid annotation");
    const pa = F.pre(down).find((e) => e.kind === "plan_approval");
    eq(pa && pa.artifact_session_id, "up-verbatim", "plan_approval artifact_session_id");
  });
  check("C1: only session_id and created_at change; upstream_session_id is set", () => {
    eq([down.session_id, down.created_at, down.upstream_session_id], ["down-verbatim", createdAt, "up-verbatim"], "identity");
    for (const k of ["closes_issues", "last_pushed_sha", "deliverable_type", "session_start_context"]) eq(down[k], up[k], k);
  });
  check("C1: no event anywhere carries inherited_from", () => {
    eq(down.events.filter((e) => Object.prototype.hasOwnProperty.call(e, "inherited_from")).length, 0, "inherited_from events");
  });
  check("C1: the stream after the copy is still contiguous and passes the integrity check", () => {
    F.mod("hooks/workflow-state/state-io/projection").assertStreamIntegrity(down.events);
  });
  check("C1: the upstream file is left untouched", () => eq(F.raw("up-verbatim"), up, "upstream state"));
}
caseEnd();

caseBegin("session-start-context-same-and-different", "hooks/workflow-state/inheritance/apply.js");
{
  check("C2: a downstream context equal to the upstream's keeps the upstream value", () => {
    const up = F.seedUpstream("up-ctx-same");
    const createdAt = F.seedDownstream("down-ctx-same", F.UP_CTX);
    apply().applyInheritance("down-ctx-same", createdAt, "up-ctx-same");
    eq(F.raw("down-ctx-same").session_start_context, up.session_start_context, "session_start_context");
    eq(F.raw("down-ctx-same").upstream_session_id, "up-ctx-same", "upstream_session_id");
  });
  check("C2: a downstream context that differs keeps the downstream value", () => {
    F.seedUpstream("up-ctx-diff");
    const ctx = { cwd: "/fixture/down", git_branch: "main", transcript_path: "/fixture/t/down.jsonl" };
    const createdAt = F.seedDownstream("down-ctx-diff", ctx);
    apply().applyInheritance("down-ctx-diff", createdAt, "up-ctx-diff");
    eq(F.raw("down-ctx-diff").session_start_context, ctx, "session_start_context");
  });
}
caseEnd();

caseBegin("supervisor-state-copied-or-absent", "hooks/lib/supervisor-state-writer/copy.js");
{
  check("C3: the upstream supervisor state lands at <downstream>.control with only session_id rewritten", () => {
    F.seedUpstream("up-sup");
    const sup = F.seedSupervisor("up-sup");
    const createdAt = F.seedDownstream("down-sup");
    const res = apply().applyInheritance("down-sup", createdAt, "up-sup");
    eq(res && res.supervisor_state, "copied", "supervisor_state");
    const copied = JSON.parse(fs.readFileSync(F.supervisorPath("down-sup"), "utf8"));
    eq(copied, Object.assign({}, sup, { session_id: "down-sup" }), "downstream supervisor state");
    eq(JSON.parse(fs.readFileSync(F.supervisorPath("up-sup"), "utf8")), sup, "upstream supervisor state");
  });
  check("C3: no upstream supervisor file reports absent and the inheritance still succeeds", () => {
    F.seedUpstream("up-nosup");
    const createdAt = F.seedDownstream("down-nosup");
    const res = apply().applyInheritance("down-nosup", createdAt, "up-nosup");
    eq(res && res.supervisor_state, "absent", "supervisor_state");
    eq(fs.existsSync(F.supervisorPath("down-nosup")), false, "downstream supervisor file created");
    eq(F.raw("down-nosup").upstream_session_id, "up-nosup", "workflow state copied");
  });
  check("C3: copySupervisorState reports absent / copied directly", () => {
    const copy = F.mod("hooks/lib/supervisor-state-writer/copy");
    eq(copy.copySupervisorState("up-direct-none", "down-direct-none"), "absent", "absent");
    F.seedSupervisor("up-direct");
    eq(copy.copySupervisorState("up-direct", "down-direct"), "copied", "copied");
    eq(JSON.parse(fs.readFileSync(F.supervisorPath("down-direct"), "utf8")).session_id, "down-direct", "session_id");
  });
  check("C3: a malformed upstream supervisor file reports failed and the workflow state still lands", () => {
    F.seedUpstream("up-supbad");
    F.seedSupervisor("up-supbad");
    fs.writeFileSync(F.supervisorPath("up-supbad"), "{not json");
    const createdAt = F.seedDownstream("down-supbad");
    const res = apply().applyInheritance("down-supbad", createdAt, "up-supbad");
    eq(res && res.supervisor_state, "failed", "supervisor_state");
    eq(fs.existsSync(F.supervisorPath("down-supbad")), false, "downstream supervisor file created");
    eq([F.raw("down-supbad").upstream_session_id, F.raw("down-supbad").upstream_copy_seq > 0], ["up-supbad", true], "workflow state copied");
  });
  check("C3: re-adopting the same upstream after its supervisor file vanished is allowed, absent, and keeps the earlier copy", () => {
    const adopt = F.mod("hooks/workflow-state/inheritance/adopt");
    F.seedUpstream("up-supgone");
    const sup = F.seedSupervisor("up-supgone");
    F.seedDownstream("down-supgone");
    const first = adopt.adoptState({ heirSid: "down-supgone", donorSid: "up-supgone" });
    eq(first && first.ok && first.inheritance.supervisor_state, "copied", "first adopt (" + show(first && first.error) + ")");
    fs.rmSync(F.supervisorPath("up-supgone"));
    const again = adopt.adoptState({ heirSid: "down-supgone", donorSid: "up-supgone" });
    eq(again && again.ok, true, "re-adopt ok (" + show(again && again.error) + ")");
    eq(again.inheritance.supervisor_state, "absent", "supervisor_state");
    eq(JSON.parse(fs.readFileSync(F.supervisorPath("down-supgone"), "utf8")), Object.assign({}, sup, { session_id: "down-supgone" }), "earlier downstream copy");
    eq(F.raw("down-supgone").upstream_copy_seq, F.raw("up-supgone").events.length, "upstream_copy_seq");
  });
}
caseEnd();

caseBegin("downstream-worktree-and-model-carry-forward", "hooks/workflow-state/inheritance/apply.js");
{
  check("C4: a downstream EnterWorktree recorded before the copy survives it and owns state.cwd", () => {
    F.seedUpstream("up-wt");
    const createdAt = F.seedDownstream("down-wt");
    F.S().appendEvents("down-wt", [F.worktreeEvent("/fixture/down-wt", "feature/down")]);
    apply().applyInheritance("down-wt", createdAt, "up-wt");
    const down = F.raw("down-wt");
    const carried = F.post(down).filter((e) => e.kind === "worktree");
    eq(carried.length, 1, "worktree events after the boundary");
    const st = F.S().readState("down-wt");
    eq([st.cwd, st.git_branch], ["/fixture/down-wt", "feature/down"], "projected cwd/branch");
  });
  check("C4: the downstream session_model is carried forward when the upstream has none", () => {
    F.seedUpstream("up-model");
    const createdAt = F.seedDownstream("down-model");
    F.S().recordSessionModel("down-model", { id: "claude-down", source: "payload" });
    apply().applyInheritance("down-model", createdAt, "up-model");
    eq(F.post(F.raw("down-model")).filter((e) => e.kind === "session_model").length, 1, "session_model after the boundary");
    eq(F.S().readState("down-model").session_model.id, "claude-down", "projected session_model");
  });
  check("C4: the upstream session_model is copied when the downstream has none", () => {
    F.seedUpstream("up-model2", { model: "claude-up" });
    const createdAt = F.seedDownstream("down-model2");
    apply().applyInheritance("down-model2", createdAt, "up-model2");
    eq(F.S().readState("down-model2").session_model.id, "claude-up", "projected session_model");
    eq(F.raw("down-model2").upstream_copy_seq > 0, true, "boundary recorded");
  });
}
caseEnd();

caseBegin("granularity-full-vs-degraded-reverts", "hooks/workflow-state/inheritance/apply.js");
{
  check("C5: full — cleanup is force-skipped after the boundary (#772) and nothing is reverted", () => {
    F.seedUpstream("up-full");
    const createdAt = F.seedDownstream("down-full");
    const res = apply().applyInheritance("down-full", createdAt, "up-full");
    eq(res && res.reverted_steps, [], "reverted_steps");
    const st = F.S().readState("down-full");
    eq([st.steps.cleanup.status, st.steps.cleanup.skip_reason], ["skipped", "inherited-from-prior-session"], "cleanup");
    eq(st.steps.write_tests.status, "complete", "write_tests kept");
    const tail = F.post(F.raw("down-full")).filter((e) => e.step === "cleanup").map((e) => e.kind);
    eq(tail, ["step_annotations_cleared", "step_status", "step_annotation"], "cleanup triple after the boundary");
  });
  check("C5: degraded — worktree-dependent steps and cleanup go pending with cause context", () => {
    F.seedUpstream("up-deg", { cleanup: "in_progress" });
    const createdAt = F.seedDownstream("down-deg", { cwd: "/fixture/elsewhere", git_branch: "main", transcript_path: null });
    const res = apply().applyInheritance("down-deg", createdAt, "up-deg", DEGRADED);
    eq(res && res.granularity, "context-independent-only", "granularity");
    const byStep = {};
    for (const r of (res && res.reverted_steps) || []) byStep[r && r.step] = r;
    for (const s of ["write_tests", "review_tests", "cleanup"]) {
      eq(byStep[s], { step: s, cause: "context", code: "worktree-dependent", trigger: null }, "reverted " + s);
    }
    eq(Object.keys(byStep).some((s) => ["workflow_init", "clarify_intent", "research"].includes(s)), false, "plan step reverted");
    const st = F.S().readState("down-deg");
    for (const s of ["write_tests", "review_tests", "cleanup"]) {
      eq([st.steps[s].status, st.steps[s].inherit_revert_reason], ["pending", "context:worktree-dependent"], s);
    }
    eq(st.steps.write_tests.wsid, undefined, "write_tests wsid survived the clear");
    eq([st.steps.clarify_intent.status, st.steps.research.skip_reason], ["complete", "nothing to survey"], "plan steps kept");
  });
  check("C5: degraded — revert events are backfilled session-inherit, in cleared → pending → reason order", () => {
    const tail = F.post(F.raw("down-deg")).filter((e) => e.step === "write_tests");
    eq(tail.map(pick), [
      ["step_annotations_cleared", "", "", "", "", "backfilled", "session-inherit"],
      ["step_status", "", "pending", "", "", "backfilled", "session-inherit"],
      ["step_annotation", "", "", "inherit_revert_reason", "context:worktree-dependent", "backfilled", "session-inherit"],
    ].map((row) => row.map((v, i) => (i === 1 ? JSON.stringify("write_tests") : v === "" ? "" : JSON.stringify(v))).join("|")), "write_tests revert events");
  });
  check("C5: inherit_revert_reason is a known step annotation key", () => {
    eq(F.mod("hooks/workflow-state/state-io/events").STEP_ANNOTATION_KEYS.includes("inherit_revert_reason"), true, "STEP_ANNOTATION_KEYS");
  });
}
caseEnd();

caseBegin("copied-events-are-not-this-sessions-own-action", "hooks/workflow-state/lifecycle.js");
{
  check("C6: isWorkflowStarted is false right after the copy and true after a genuine mark-step", () => {
    F.seedUpstream("up-started");
    const createdAt = F.seedDownstream("down-started");
    apply().applyInheritance("down-started", createdAt, "up-started");
    const down = F.raw("down-started");
    const genuineCopied = F.pre(down).filter((e) => e.kind === "step_status" && e.origin === "mark-step" && e.provenance === "observed");
    eq(genuineCopied.length > 0, true, "copied observed mark-step settlements present");
    const lifecycle = F.mod("hooks/workflow-state/lifecycle");
    eq(lifecycle.isWorkflowStarted("down-started"), false, "started right after the copy");
    F.S().markStep("down-started", "outline", "skipped", { skip_reason: "trivial" });
    eq(lifecycle.isWorkflowStarted("down-started"), true, "started after a genuine mark-step");
  });
}
caseEnd();

caseBegin("one-write-per-inheritance-and-throw-leaves-bytes", "hooks/workflow-state/inheritance/apply.js");
{
  check("C7: exactly one writeStateLocked call lands on the downstream per inheritance", () => {
    F.seedUpstream("up-once");
    const createdAt = F.seedDownstream("down-once");
    writes.length = 0;
    apply().applyInheritance("down-once", createdAt, "up-once");
    eq(writes.filter((s) => s === "down-once").length, 1, "downstream writes");
    eq(writes.filter((s) => s === "up-once").length, 0, "upstream writes");
    eq(F.raw("down-once").upstream_copy_seq > 0, true, "copy happened");
  });
  check("C7: a throw while composing the batch leaves the downstream bytes unchanged", () => {
    F.seedUpstream("up-throw");
    const createdAt = F.seedDownstream("down-throw");
    const before = F.bytes("down-throw");
    const ca = F.mod("hooks/workflow-state/completion-approval");
    const real = ca.completionBoundaryEventsForBatch;
    ca.completionBoundaryEventsForBatch = () => { throw new Error("injected compose failure"); };
    try {
      throwsIt(() => apply().applyInheritance("down-throw", createdAt, "up-throw"), "applyInheritance");
    } finally {
      ca.completionBoundaryEventsForBatch = real;
    }
    eq(F.bytes("down-throw"), before, "downstream bytes");
    apply().applyInheritance("down-throw", createdAt, "up-throw");
    eq(F.raw("down-throw").upstream_copy_seq > 0, true, "positive control: the same call succeeds once unpatched");
  });
}
caseEnd();

caseBegin("upstream-missing-or-corrupt-refuses", "hooks/workflow-state/inheritance/apply.js");
{
  const refuses = (label, upSid, prep) => check(`C8: ${label} — throws and writes nothing to the downstream`, () => {
    if (prep) prep(upSid);
    const down = "down-" + upSid;
    const createdAt = F.seedDownstream(down);
    const before = F.bytes(down);
    const supBefore = fs.existsSync(F.supervisorPath(down));
    throwsIt(() => apply().applyInheritance(down, createdAt, upSid), "applyInheritance");
    eq(F.bytes(down), before, "downstream bytes");
    eq(fs.existsSync(F.supervisorPath(down)), supBefore, "downstream supervisor file");
  });
  refuses("missing upstream state file", "up-missing", null);
  refuses("upstream stream with a seq gap", "up-seqgap", (sid) => { F.seedUpstream(sid); F.seedSupervisor(sid); F.corruptSeq(sid); });
  refuses("upstream file that is not JSON", "up-notjson", (sid) => fs.writeFileSync(F.statePath(sid), "{not json"));
  check("C8: an empty upstream stream copies nothing and still records boundary 0", () => {
    F.S().writeState("up-empty", F.S().createInitialState("up-empty", F.UP_CTX));
    const createdAt = F.seedDownstream("down-empty");
    apply().applyInheritance("down-empty", createdAt, "up-empty");
    const down = F.raw("down-empty");
    eq([down.upstream_session_id, down.upstream_copy_seq], ["up-empty", 0], "boundary");
    eq(F.post(down).every((e) => e.origin === "session-inherit"), true, "only revert events follow");
  });
}
caseEnd();

caseBegin("compose-appended-state-is-pure", "hooks/workflow-state/state-io/events.js");
{
  check("C9: composeAppendedState is exported from events.js and the state-io barrel", () => {
    eq(typeof F.mod("hooks/workflow-state/state-io/events").composeAppendedState, "function", "events.js");
    eq(typeof F.S().composeAppendedState, "function", "state-io.js");
  });
  check("C9: it returns {state, appended} with renumbered seq and performs no I/O", () => {
    const base = F.S().createInitialState("compose-pure", F.UP_CTX);
    base.events = [{ kind: "step_status", step: "workflow_init", status: "complete", provenance: "observed", origin: "mark-step", at: "2026-01-01T00:00:00.000Z", seq: 1 }];
    let seen = null;
    writes.length = 0;
    const out = F.S().composeAppendedState("compose-pure", base, (events, projection) => {
      seen = [events.length, projection.steps.workflow_init.status];
      return [{ kind: "step_status", step: "research", status: "skipped", provenance: "observed", origin: "mark-step" }];
    }, { now: "2026-02-02T00:00:00.000Z" });
    eq(seen, [1, "complete"], "builder arguments");
    eq(out.appended.map((e) => [e.seq, e.at, e.step]), [[2, "2026-02-02T00:00:00.000Z", "research"]], "appended");
    eq(out.state.events.map((e) => e.seq), [1, 2], "state seq");
    eq([fs.existsSync(F.statePath("compose-pure")), writes.length], [false, 0], "file written / writeStateLocked calls");
  });
  check("C9: a corrupt base stream or a throwing builder throws without writing", () => {
    eq(typeof F.S().composeAppendedState, "function", "composeAppendedState export");
    const base = F.S().createInitialState("compose-bad", F.UP_CTX);
    base.events = [{ kind: "step_status", step: "workflow_init", status: "complete", provenance: "observed", origin: "mark-step", at: "x", seq: 3 }];
    throwsIt(() => F.S().composeAppendedState("compose-bad", base, []), "corrupt base");
    base.events[0].seq = 1;
    throwsIt(() => F.S().composeAppendedState("compose-bad", base, () => { throw new Error("builder"); }), "builder throw");
    eq(fs.existsSync(F.statePath("compose-bad")), false, "file written");
  });
}
caseEnd();

caseBegin("append-events-regression-after-extraction", "hooks/workflow-state/state-io/events.js");
{
  const io = F.S();
  check("C10: appendEvents still stamps at, renumbers seq and returns the full stream", () => {
    io.writeState("append-reg", io.createInitialState("append-reg", F.UP_CTX));
    io.markStep("append-reg", "workflow_init", "complete");
    const out = io.appendEvents("append-reg", (events, cur) => (cur.steps.workflow_init.status === "complete"
      ? [{ kind: "step_status", step: "research", status: "skipped", provenance: "observed", origin: "mark-step" }] : []),
    { now: "2026-03-03T00:00:00.000Z" });
    eq(out.map((e) => e.seq), [1, 2], "seq");
    eq(out[1].at, "2026-03-03T00:00:00.000Z", "at");
    eq(F.raw("append-reg").events.length, 2, "persisted");
  });
  check("C10: an invalid event or a throwing builder leaves the bytes unchanged", () => {
    const before = F.bytes("append-reg");
    throwsIt(() => io.appendEvents("append-reg", [{ kind: "nope", provenance: "observed", origin: "x" }]), "invalid kind");
    throwsIt(() => io.appendEvents("append-reg", () => { throw new Error("builder"); }), "builder throw");
    eq(F.bytes("append-reg"), before, "bytes");
  });
  check("C10: an empty batch writes nothing", () => {
    const before = F.bytes("append-reg");
    writes.length = 0;
    io.appendEvents("append-reg", []);
    eq([F.bytes("append-reg") === before, writes.length], [true, 0], "unchanged / writes");
  });
}
caseEnd();

caseBegin("adopt-state-carries-the-new-contract", "hooks/workflow-state/inheritance/adopt.js");
{
  check("C11: adoptState hands back the new contract under inheritance", () => {
    F.seedUpstream("up-adopt");
    F.seedDownstream("down-adopt");
    const r = F.mod("hooks/workflow-state/inheritance/adopt").adoptState({ heirSid: "down-adopt", donorSid: "up-adopt" });
    eq(r && r.ok, true, "ok (" + show(r && r.error) + ")");
    eq(r.inheritance && [r.inheritance.upstream_session_id, r.inheritance.supervisor_state], ["up-adopt", "absent"], "inheritance");
    eq(F.raw("down-adopt").upstream_copy_seq, F.raw("up-adopt").events.length, "upstream_copy_seq");
  });
}
caseEnd();

caseBegin("render-describes-reverts-supervisor-and-plan-names", "bin/lib/resume-session/render.js");
{
  check("C12: renderUpstreamView names each reverted step, the supervisor outcome and the plan artifact owner", () => {
    const text = F.mod("bin/lib/resume-session/render").renderUpstreamView({
      upstream_session_id: "up-render", availability: "state-and-artifacts",
      inherit_result: { ok: true, inheritance: {
        upstream_session_id: "up-render", granularity: "context-independent-only",
        inherited_steps: ["workflow_init", "clarify_intent"],
        reverted_steps: [{ step: "write_tests", cause: "context", code: "worktree-dependent", trigger: null }],
        supervisor_state: "copied",
      } },
      transcript_tail: { available: false, reason: "fixture" },
    });
    eq(/\[object Object\]/.test(text), false, "object leaked into text");
    eq(text.includes("write_tests"), true, "reverted step named");
    eq(text.split("\n").some((l) => /supervisor/i.test(l) && l.includes("copied")), true, "supervisor line");
    eq(text.split("\n").some((l) => /plan artifact/i.test(l) && l.includes("up-render") && l !== "State file and plan artifacts are both present."), true, "plan artifact owner line");
  });
}
caseEnd();

caseBegin("session-start-corrupt-upstream-unlinks-state", "hooks/session-start.js");
{
  check("C13: a corrupt upstream stream makes session-start delete the new state file and say so on stderr", () => {
    F.seedUpstream("up-ss");
    F.corruptSeq("up-ss");
    const preload = path.join(SCRATCH, "force-upstream.js");
    fs.writeFileSync(preload, `const b = require(${JSON.stringify(path.join(F.ROOT, "hooks/workflow-state"))});\n` +
      "b.resolveInheritanceDonor = () => ({ donor: { session_id: 'up-ss' }, decision: 'inherited', candidateSessionId: 'up-ss', ancestors: [] });\n");
    const home = fs.mkdtempSync(path.join(SCRATCH, "home-"));
    const tbase = fs.mkdtempSync(path.join(SCRATCH, "transcripts-"));
    const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home, CLAUDE_TRANSCRIPT_BASE_DIR: tbase });
    delete env.CLAUDE_CODE_SESSION_ID;
    const run = spawnSync(process.execPath, ["-r", preload, path.join(F.ROOT, "hooks/session-start.js")], {
      cwd: home, env, encoding: "utf8", timeout: 60000,
      input: JSON.stringify({ session_id: "down-ss", source: "resume", transcript_path: path.join(tbase, "down-ss.jsonl") }),
    });
    eq(fs.existsSync(F.statePath("down-ss")), false, "downstream state file exists");
    eq(/inheritance failed for down-ss/.test(run.stderr || ""), true, "stderr names the failure (" + show(run.stderr) + ")");
  });
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
process.exitCode = failed === 0 ? 0 : 1;
