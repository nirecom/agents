#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/inheritance/adopt.js
// Tags: TL2, session-inherit, workflow-state, state-handoff-record, event-stream, regression-2652, scope:issue-specific, dup-group-keep:size-hard-limit, pwsh-not-required, regression-2920, workflow-abort
// #2652 S4: adopting (--from) a session-upstream whose state carries state handoff records — the
// records stay generation-local (not copied), the downstream's own records survive (re-)adoption
// and never trip the overwrite guard, and the upstream's records stay readable by sid.
// #2920 S4 / S8-(1): a workflow_aborted event is generation-local too, and adoptState aborts the
// upstream it adopts from (origin adopt-auto), reporting it in upstream_aborts.
// New file rather than an append: feature-2304-inheritance-state-copy.js is at 457 lines.
// TL3 gap (what this test does NOT catch):
// - the /resume-session --from CLI end to end; adoptState is called in-process here.

const { after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2652c-"));
after(() => {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const { check, eq, show } = require("./feature-2652-state-handoff/check");
const F = require("./feature-2304-inheritance-state-copy/fixture");
const R = require("../lib/state-handoff-record-fixture");
const adopt = F.mod("hooks/workflow-state/inheritance/adopt");
const { hasSelfRecordedStepSettlement } = F.mod("hooks/workflow-state/lifecycle");
const { assertStreamIntegrity } = F.mod("hooks/workflow-state/state-io/projection");

const isRecord = (e) => e && e.kind === "state_handoff_record";
const upRecords = [
  R.record({ cls: "A", at_step: "-", record_key: "up.decision", summary: "UP-RECORD-1", origin: "procedure-point", provenance: "declared" }),
  R.record({ cls: "C", at_step: "write_tests", record_key: "gate:block", summary: "UP-RECORD-2" }),
  R.record({ cls: "D", at_step: "review_tests", record_key: "up.auto", summary: "UP-RECORD-3", origin: "auto-record" }),
];
const own = (summary) => R.record({ cls: "E", at_step: "-", record_key: "down.own", summary, origin: "procedure-point", provenance: "declared" });
function adoptOk(heir, donor) {
  const r = adopt.adoptState({ heirSid: heir, donorSid: donor });
  if (!r || r.ok !== true) throw new Error(`adoptState(${heir} <- ${donor}) refused: ${show(r && r.error)}`);
  return r;
}

// U1 and U2 are seeded identically; U2 also carries state handoff records at the end of its stream.
F.seedUpstream("u-plain");
F.seedUpstream("u-records");
R.pushEvents("u-records", upRecords);
F.seedDownstream("d-plain");
F.seedDownstream("d-records");
let adoptError = null;
try { adoptOk("d-plain", "u-plain"); adoptOk("d-records", "u-records"); } catch (e) { adoptError = e.message; }
const adopted = () => { if (adoptError) throw new Error(adoptError); return [F.raw("d-plain"), F.raw("d-records")]; };

caseBegin("upstream-records-are-not-copied", "hooks/workflow-state/inheritance/apply.js");
{
  check("S4: control — adopting the record-free upstream works and passes the integrity check", () => {
    const [d1] = adopted();
    assertStreamIntegrity(d1.events);
    eq(d1.upstream_copy_seq, F.pre(d1).length, "upstream_copy_seq");
  });
  check("S4: the downstream carries none of the upstream's state handoff records", () => {
    const [, d2] = adopted();
    eq(d2.events.filter(isRecord).map((e) => e.summary), [], "records in the downstream");
  });
  check("S4: upstream_copy_seq is the last seq of the copied stream without the records", () => {
    const [d1, d2] = adopted();
    // #2920: adoptState appends an adopt-auto workflow_aborted event to the upstream after the copy; it is not part of the copied portion.
    const upNonRecord = F.raw("u-records").events.filter((e) => !isRecord(e) && e.kind !== "workflow_aborted").length;
    eq([d2.upstream_copy_seq, F.pre(d2).length], [upNonRecord, upNonRecord], "boundary / copied events");
    eq(d2.upstream_copy_seq, d1.upstream_copy_seq, "boundary equals the record-free adoption's");
    assertStreamIntegrity(d2.events);
  });
}
caseEnd();

caseBegin("judgments-unchanged-by-exclusion", "hooks/workflow-state/inheritance/adopt.js");
{
  check("S4: hasSelfRecordedStepSettlement and heirContextOf match the record-free adoption", () => {
    const [d1, d2] = adopted();
    eq([hasSelfRecordedStepSettlement(d2), adopt.heirContextOf(d2)], [hasSelfRecordedStepSettlement(d1), adopt.heirContextOf(d1)], "judgments");
  });
}
caseEnd();

caseBegin("downstream-own-records-survive-adoption", "hooks/workflow-state/inheritance/apply.js");
{
  check("S4: a record the downstream wrote before adopting survives adoption and re-adoption", () => {
    F.seedDownstream("d-own-before");
    R.pushEvents("d-own-before", [own("DOWN-BEFORE")]);
    adoptOk("d-own-before", "u-records");
    eq(F.post(F.raw("d-own-before")).filter(isRecord).map((e) => e.summary), ["DOWN-BEFORE"], "after the first adoption");
    adoptOk("d-own-before", "u-records");
    const d = F.raw("d-own-before");
    eq(d.events.filter(isRecord).map((e) => e.summary), ["DOWN-BEFORE"], "after re-adoption");
    assertStreamIntegrity(d.events);
  });
}
caseEnd();

caseBegin("own-records-do-not-trip-overwrite-guard", "hooks/workflow-state/inheritance/adopt.js");
{
  check("S4: control — a downstream-own step settlement after adoption still refuses re-adoption", () => {
    F.seedDownstream("d-own-step");
    adoptOk("d-own-step", "u-plain");
    F.S().markStep("d-own-step", "write_code", "complete");
    eq(adopt.checkOverwriteAllowed(F.raw("d-own-step"), "u-plain").ok, false, "checkOverwriteAllowed ok");
  });
  check("S4: a downstream holding only its own state handoff records may re-adopt, and keeps them", () => {
    F.seedDownstream("d-own-after");
    adoptOk("d-own-after", "u-records");
    R.pushEvents("d-own-after", [own("DOWN-AFTER")]);
    const v = adopt.checkOverwriteAllowed(F.raw("d-own-after"), "u-records");
    eq([v.ok, v.error], [true, null], "checkOverwriteAllowed");
    adoptOk("d-own-after", "u-records");
    eq(F.raw("d-own-after").events.filter(isRecord).map((e) => e.summary), ["DOWN-AFTER"], "records after re-adoption");
  });
}
caseEnd();

// seedInterleaved(sid, withRecords) — an upstream whose ordinary events have records between them
// (withRecords) or not (the control); both sides take the same ordinary steps in the same order.
function seedInterleaved(sid, withRecords) {
  const io = F.S();
  const between = (n) => { if (withRecords) R.pushEvents(sid, [R.record({ cls: "D", at_step: "-", record_key: `mid.${n}`, summary: `MID-RECORD-${n}`, origin: "auto-record" })]); };
  io.writeState(sid, io.createInitialState(sid, F.UP_CTX));
  io.appendEvents(sid, [F.worktreeEvent("/fixture/up-wt", "feature/up")]);
  between(1);
  io.markStep(sid, "workflow_init", "complete");
  between(2);
  io.markStep(sid, "research", "skipped", { skip_reason: "nothing to survey" });
  between(3);
  io.markStep(sid, "write_tests", "complete", { wsid: "wsid-up" });
}
const shapeOf = (e) => [e.kind, e.step, e.status];

caseBegin("copy-boundary-skips-interleaved-records", "hooks/workflow-state/inheritance/apply.js");
{
  seedInterleaved("u-interleave", true);
  seedInterleaved("u-interleave-ctl", false);
  F.seedDownstream("d-interleave");
  F.seedDownstream("d-interleave-ctl");
  let interleaveError = null;
  try { adoptOk("d-interleave-ctl", "u-interleave-ctl"); adoptOk("d-interleave", "u-interleave"); } catch (e) { interleaveError = e.message; }
  const both = () => { if (interleaveError) throw new Error(interleaveError); return [F.raw("d-interleave"), F.raw("d-interleave-ctl")]; };
  check("S4: fixture — the upstream really holds records between its ordinary events", () => {
    const evs = F.raw("u-interleave").events;
    const at = evs.map((e, i) => (isRecord(e) ? i : -1)).filter((i) => i >= 0);
    eq(at.length, 3, "records in the upstream");
    if (!at.every((i) => i > 0 && i < evs.length - 1)) throw new Error(`a record sits at the stream edge: ${show(at)}`);
  });
  check("S4: control — the record-free interleave upstream adopts and passes the integrity check", () => {
    const [, ctl] = both();
    assertStreamIntegrity(ctl.events);
    eq(ctl.upstream_copy_seq, F.pre(ctl).length, "upstream_copy_seq");
  });
  check("S4: the copied stream has no records and its seq runs 1..n without a gap", () => {
    const [d] = both();
    eq(d.events.filter(isRecord).map((e) => e.summary), [], "records in the downstream");
    eq(d.events.map((e) => e.seq), d.events.map((_, i) => i + 1), "seq");
    assertStreamIntegrity(d.events);
  });
  check("S4: upstream_copy_seq points at the copy of the upstream's last ordinary event", () => {
    const [d, ctl] = both();
    const upOrdinary = F.raw("u-interleave").events.filter((e) => !isRecord(e) && e.kind !== "workflow_aborted");
    eq([d.upstream_copy_seq, ctl.upstream_copy_seq], [upOrdinary.length, upOrdinary.length], "boundary / control boundary");
    const atBoundary = d.events.find((e) => e.seq === d.upstream_copy_seq);
    eq(atBoundary && shapeOf(atBoundary), shapeOf(upOrdinary[upOrdinary.length - 1]), "event at upstream_copy_seq");
    eq(F.pre(d).map(shapeOf), F.pre(ctl).map(shapeOf), "copied events against the control");
  });
}
caseEnd();

caseBegin("upstream-records-stay-readable", "hooks/workflow-state/inheritance/adopt.js");
{
  check("S4: after adoption, readStateHandoff(upstream sid) still returns the upstream's records", () => {
    adopted();
    let read;
    try { read = F.mod("hooks/lib/state-handoff-record").readStateHandoff; } catch (e) { throw new Error(`state handoff reader not loadable: ${e.message.split("\n")[0]}`, { cause: e }); }
    if (typeof read !== "function") throw new Error("readStateHandoff is not exported");
    const out = read("u-records");
    eq([out.entries.map((e) => e.summary), out.errors], [["UP-RECORD-1", "UP-RECORD-2", "UP-RECORD-3"], []], "readStateHandoff");
  });
}
caseEnd();

// #2920: the aborted upstreams are built at the stream level (raw event), so the copy is tested
// apart from the writer in workflow-abort.js.
const X = require("./feature-2920-workflow-abort/fixture");
const isAbort = (e) => e && e.kind === "workflow_aborted";
const abortsIn = (sid) => F.raw(sid).events.filter(isAbort);
const kinds = (v) => (v && typeof v[Symbol.iterator] === "function" && typeof v !== "string" ? Array.from(v).sort() : v);

caseBegin("aborted-upstream-copy-contract", "hooks/workflow-state/inheritance/apply.js");
{
  F.seedUpstream("u-aborted");
  X.rawAbort("u-aborted", "abort-sentinel");
  F.seedDownstream("d-from-aborted");
  let firstErr = null;
  let first = null;
  try { first = adoptOk("d-from-aborted", "u-aborted"); } catch (e) { firstErr = e.message; }
  check("#2920 fixture: the upstream holds the abort and reads as aborted", () => {
    eq(abortsIn("u-aborted").length, 1, "workflow_aborted events in the upstream");
    eq(X.abortModule().isWorkflowAborted("u-aborted"), true, "isWorkflowAborted(upstream)");
  });
  check("#2920 fixed 1: adopting from an aborted upstream is ok", () => { if (firstErr) throw new Error(firstErr); });
  check("#2920 fixed 2: the abort does not reach the downstream", () => {
    if (firstErr) throw new Error(firstErr);
    eq(abortsIn("d-from-aborted").length, 0, "workflow_aborted events in the downstream");
    eq(X.abortModule().isWorkflowAborted("d-from-aborted"), false, "isWorkflowAborted(heir)");
    assertStreamIntegrity(F.raw("d-from-aborted").events);
  });
  check("#2920 fixed 3: re-adopting from the same upstream is ok and leaves the downstream live", () => {
    adoptOk("d-from-aborted", "u-aborted");
    eq(abortsIn("d-from-aborted").length, 0, "workflow_aborted events after re-adoption");
    eq(X.abortModule().isWorkflowAborted("d-from-aborted"), false, "isWorkflowAborted(heir) after re-adoption");
  });
  check("#2920 handover: the sentinel-aborted upstream names the downstream once; the handover is not copied", () => {
    if (firstErr) throw new Error(firstErr);
    eq(first.upstream_aborts.map((a) => [a.sid, !!a.handover, a.recorded]), [["u-aborted", true, true]], "upstream_aborts");
    eq(X.handoverEventsOf("u-aborted").map((e) => [e.origin, e.heir_session_id]), [["adopt-auto", "d-from-aborted"]], "upstream handover events");
    eq(X.abortModule().readWorkflowAbort("u-aborted").heir_session_id, "d-from-aborted", "projected heir of the upstream");
    eq(X.handoverEventsOf("d-from-aborted").length, 0, "handover events in the downstream");
  });
}
caseEnd();

caseBegin("carried-kinds-single-source", "hooks/workflow-state/inheritance/adopt.js");
{
  check("#2920 S4: GENERATION_LOCAL_KINDS holds workflow_aborted; CARRIED_DOWNSTREAM_KINDS == CARRIED_RECORD_KINDS", () => {
    const apply = F.mod("hooks/workflow-state/inheritance/apply");
    eq(kinds(apply.GENERATION_LOCAL_KINDS), ["state_handoff_record", "workflow_abort_handover", "workflow_aborted"], "apply.GENERATION_LOCAL_KINDS");
    eq(kinds(apply.CARRIED_DOWNSTREAM_KINDS), ["state_handoff_record"], "apply.CARRIED_DOWNSTREAM_KINDS");
    eq(kinds(adopt.CARRIED_RECORD_KINDS), kinds(apply.CARRIED_DOWNSTREAM_KINDS), "adopt.CARRIED_RECORD_KINDS");
  });
}
caseEnd();

// adoptSoft(heir, donor) — adoptState's result, or {error} when it throws or refuses.
function adoptSoft(heir, donor) {
  try { return adoptOk(heir, donor); } catch (e) { return { error: e.message }; }
}
const recordedTrue = (r) => (Array.isArray(r.upstream_aborts) ? r.upstream_aborts.filter((a) => a && a.recorded === true).map((a) => a.sid) : null);

caseBegin("adopt-aborts-the-upstream", "hooks/workflow-state/inheritance/adopt.js");
{
  F.seedUpstream("u-auto");
  F.seedDownstream("d-auto");
  const r1 = adoptSoft("d-auto", "u-auto");
  check("S8-(1): adoptState reports the recorded upstream abort in upstream_aborts", () => {
    if (r1.error) throw new Error(r1.error);
    if (!Array.isArray(r1.upstream_aborts)) throw new Error(`upstream_aborts is not an array: ${show(r1.upstream_aborts)}`);
    eq(r1.upstream_aborts.map((a) => [a.sid, a.recorded]), [["u-auto", true]], "upstream_aborts");
  });
  check("S8-(1): the upstream carries one adopt-auto abort naming the heir", () => {
    eq(abortsIn("u-auto").map((e) => [e.origin, e.heir_session_id, e.reason]), [["adopt-auto", "d-auto", "adopted by d-auto"]], "upstream abort");
    eq(X.abortModule().isWorkflowAborted("d-auto"), false, "isWorkflowAborted(heir)");
  });
  const r2 = adoptSoft("d-auto", "u-auto");
  check("S8-(1) idempotency: a second adopt records no second abort", () => {
    if (r2.error) throw new Error(r2.error);
    eq(recordedTrue(r2), [], "upstream_aborts recorded:true on the second adopt");
    eq(abortsIn("u-auto").length, 1, "abort events in the upstream after the second adopt");
  });
  F.seedUpstream("u-delivered");
  X.pushStep("u-delivered", "merge_to_main", "complete");
  F.seedDownstream("d-delivered");
  const r3 = adoptSoft("d-delivered", "u-delivered");
  // A delivered upstream is refused by adoptState itself (legacy behavior, passes today); the abort
  // must come after a successful applyInheritance, so a refused adopt records nothing.
  check("S8-(1): a refused adopt (delivered upstream) aborts nothing", () => {
    if (!r3.error || !/delivered/.test(r3.error)) throw new Error(`expected a delivered refusal, got ${show(r3)}`);
    eq(abortsIn("u-delivered").length, 0, "abort events in the delivered upstream");
  });
}
caseEnd();

// failUpstreamWrites(sid, fn) — runs fn while every rename onto <sid>.json throws EIO (the atomic
// state write's last step), so recording the abort on that upstream fails; returns [result, fired].
function failUpstreamWrites(sid, fn) {
  const real = fs.renameSync;
  let fired = 0;
  fs.renameSync = function patched(from, to) {
    if (path.basename(String(to)) === `${sid}.json`) {
      fired += 1;
      throw Object.assign(new Error(`EIO: injected write failure on ${sid}.json`), { code: "EIO" });
    }
    return real.apply(fs, arguments);
  };
  try { return [fn(), fired]; } finally { fs.renameSync = real; }
}

caseBegin("adopt-upstream-record-failure", "hooks/workflow-state/inheritance/adopt.js");
{
  F.seedUpstream("u-wfail");
  F.seedDownstream("d-wfail");
  const upBefore = F.bytes("u-wfail");
  const [r, fired] = failUpstreamWrites("u-wfail", () => adoptSoft("d-wfail", "u-wfail"));
  check("S8-(1) error: an upstream write failure leaves adoptState ok", () => {
    if (r.error) throw new Error(r.error);
    eq(F.raw("d-wfail").upstream_session_id, "u-wfail", "the heir adopted the upstream");
  });
  check("S8-(1) error: upstream_aborts reports recorded:false with a reason", () => {
    if (!Array.isArray(r.upstream_aborts)) throw new Error(`upstream_aborts is not an array: ${show(r.upstream_aborts)}`);
    eq(r.upstream_aborts.map((a) => [a.sid, a.recorded]), [["u-wfail", false]], "upstream_aborts");
    const reason = r.upstream_aborts[0].reason;
    if (typeof reason !== "string" || reason.trim() === "") throw new Error(`no reason: ${show(r.upstream_aborts[0])}`);
  });
  check("S8-(1) error: the injection really hit the upstream write, which stays unchanged", () => {
    if (fired === 0) throw new Error("no write onto u-wfail.json was attempted: the failure was never injected");
    eq(F.bytes("u-wfail"), upBefore, "upstream state bytes");
    eq(abortsIn("u-wfail").length, 0, "abort events in the upstream");
  });
}
caseEnd();
