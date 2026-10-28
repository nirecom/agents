#!/usr/bin/env node
// tests/hooks/feature-2631-confirm-size-stop.js
// Tests: hooks/stop-confirm-plan-guard.js, hooks/lib/plan-artifact-lang.js, hooks/lib/size-limits.js, hooks/lib/size-session-gate.js, hooks/workflow-state/plan-artifact-owner.js
// Tags: scope:issue-specific, size-limits, hook, stop, confirm, plan-artifact, block, layer:TL2, ssot
// TL3 gap (what this test does NOT catch):
// - the real Claude Code host firing the Stop hook and continuing the turn on its block decision
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
"use strict";
// #2631 stage 4, Stop: the Layer 2 re-check of a confirmed plan and the #2650 continuation both
// block with "[confirm-plan] Layer 2/plan-size:" when the stage's artifact is over HARD; a
// WORKFLOW_OFF session is left alone. In a resumed session the size check and the PLAN_LANG
// re-lint read the owner's file (first_session_id / a legacy upstream_session_id, #2748).
// tests/hooks/fix-524-confirm-plan-guard.sh (layer2-cases.sh) stays the plan-lang regression.

const fs = require("fs");
const path = require("path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const savedCwd = process.cwd();
const C = require("./feature-2631-confirm-size/fixture");
const { F } = C;
process.chdir(F.work());
const X = require("./feature-2650-confirm-continuation/fixture");
const CONT = "[confirm-plan] continue:";

caseBegin("C6-layer2-over-hard-blocks", "hooks/stop-confirm-plan-guard.js");
F.run("C6 layer2", () => {
  for (const stage of ["intent", "outline", "detail"]) {
    const h = C.HARD[stage];
    const ok = C.stop(C.session(stage, h), C.layer2Transcript(stage));
    F.check(`${stage}: control: plan at HARD with the follow-up stops quietly`, C.quiet(ok), ok.raw);
    const sid = C.session(stage, h + 1);
    const r = C.stop(sid, C.layer2Transcript(stage));
    F.check(`${stage}: plan at HARD+1 blocks with the plan-size reason`,
      C.blockedWith(r, C.SIZE_PREFIX, [path.basename(C.planPath(sid, stage)), h + 1, h]), r.raw);
  }
  const off = C.session("detail", C.HARD.detail + 1);
  F.writeMarker(off, "workflow-off");
  const r = C.stop(off, C.layer2Transcript("detail"));
  F.check("WORKFLOW_OFF session: HARD+1 stops quietly", C.quiet(r), r.raw);
});
caseEnd();

// present(s) -> the #2650 presentation turn: the plan is written, the turn closes on its plan-link line.
function present(s) {
  const entries = [X.U("write the plan", "u-prompt"), X.A("a-write", X.W(s.plan)), X.TR("w1", "u-tr")];
  X.turnMarker(s.sid, s.stage, s.plan);
  entries.push(X.A("a-anchor", X.T("Here is the plan.\n\n" + s.line)));
  return X.writeTranscript(s.sid, entries);
}
// markStarted(sid) — adds the mark-step event the size session gate looks for to a #2650 state.
function markStarted(sid) {
  const p = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
  const st = JSON.parse(fs.readFileSync(p, "utf8"));
  st.events.push({ kind: "step_status", step: "workflow_init", status: "complete", provenance: "observed",
    origin: "mark-step", at: new Date().toISOString(), seq: st.events.length + 1 });
  fs.writeFileSync(p, JSON.stringify(st, null, 2));
}

caseBegin("C6-continuation-over-hard-blocks", "hooks/stop-confirm-plan-guard.js");
F.run("C6 continuation", () => {
  const h = C.HARD.detail;
  const ok = X.sessionAt("detail", { body: C.planOf(h) });
  markStarted(ok.sid);
  F.startedSanity(ok.sid);
  const rc = C.stop(ok.sid, present(ok));
  F.check("control: a presentation turn at HARD is continued", rc.rc === 2 && rc.reason.startsWith(CONT), rc.raw);
  const s = X.sessionAt("detail", { body: C.planOf(h + 1) });
  markStarted(s.sid);
  const r = C.stop(s.sid, present(s));
  F.check("a presentation turn at HARD+1 blocks with the plan-size reason (no continuation)",
    C.blockedWith(r, C.SIZE_PREFIX, [path.basename(s.plan), h + 1]), r.raw);
});
caseEnd();

caseBegin("C7-stop-resumed-session-reads-the-owner-file", "hooks/lib/plan-artifact-lang.js");
F.run("C7 stop", () => {
  const n = C.HARD.detail + 1;
  const U = F.newSid();
  C.writePlan(U, "detail", C.planOf(n));
  const D = C.session("detail", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  const r = C.stop(D, C.layer2Transcript("detail"));
  F.check("upstream_session_id: U's detail at HARD+1 blocks D's Stop",
    C.blockedWith(r, C.SIZE_PREFIX, [path.basename(C.planPath(U, "detail")), n]), r.raw);

  // #2748: first_session_id names the plan of every generation (an approval record is no candidate).
  const Xs = F.newSid();
  C.writePlan(Xs, "detail", C.planOf(n));
  const D2 = C.session("detail", null, { top: { first_session_id: Xs } });
  const r2 = C.stop(D2, C.layer2Transcript("detail"));
  F.check("first_session_id: X's detail at HARD+1 blocks D2's Stop",
    C.blockedWith(r2, C.SIZE_PREFIX, [path.basename(C.planPath(Xs, "detail")), n]), r2.raw);

  const U3 = F.newSid();
  C.writePlan(U3, "detail", C.planOf(C.HARD.detail));
  const D3 = C.session("detail", null, { top: { upstream_session_id: U3, upstream_copy_seq: 0 } });
  const r3 = C.stop(D3, C.layer2Transcript("detail"));
  F.check("upstream at exactly HARD stops quietly", C.quiet(r3), r3.raw);

  // PLAN_LANG=japanese makes an English body a violation (the fix-524 trigger).
  const ja = { PLAN_LANG: "japanese" };
  const own = C.session("detail", 10);
  const ro = C.stop(own, C.layer2Transcript("detail"), { env: ja });
  F.check("control: an own English detail under PLAN_LANG=japanese blocks with plan-lang",
    C.blockedWith(ro, C.LANG_PREFIX), ro.raw);
  const U4 = F.newSid();
  C.writePlan(U4, "detail", C.planOf(10));
  const D4 = C.session("detail", null, { top: { upstream_session_id: U4, upstream_copy_seq: 0 } });
  const r4 = C.stop(D4, C.layer2Transcript("detail"), { env: ja });
  F.check("plan-lang re-lint reads U's detail in D",
    C.blockedWith(r4, C.LANG_PREFIX, [path.basename(C.planPath(U4, "detail"))]), r4.raw);
  const U5 = F.newSid();
  C.writePlan(U5, "detail", C.JA_LINE.repeat(10));
  const D5 = C.session("detail", null, { top: { upstream_session_id: U5, upstream_copy_seq: 0 } });
  const r5 = C.stop(D5, C.layer2Transcript("detail"), { env: ja });
  F.check("a compliant upstream detail under PLAN_LANG=japanese stops quietly", C.quiet(r5), r5.raw);
});
caseEnd();

// One SSOT for both gates: a copied checkout whose size-limits.js says another detail HARD moves
// the CONFIRM deny and the Stop block together, for the same plan. Every number is read from the
// module; the original checkout is the control with the opposite verdicts.
caseBegin("C9-detail-limit-change-moves-confirm-and-stop-together", "hooks/lib/size-limits.js");
F.run("C9 ssot", () => {
  const { limitsTree } = require("./feature-2631-size-limits/mutate-limits");
  const base = F.load("hooks/lib/size-limits.js").LIMITS.detail;
  const dialog = (r) => r.decision !== "block" && /^\[detail\] (?!plan-file=none)\S/.test(r.msg);
  const denied = (r, needles) => r.deny && r.reason.includes(C.SEND_BACK) && needles.every((n) => r.reason.includes(String(n)));
  const lo = { warn: Math.floor(base.warn / 2), hard: Math.floor(base.hard / 2) };
  const hi = { warn: base.hard + 50, hard: base.hard + 100 };
  // name | changed limits | plan lines: over the changed HARD only (lowered) / over the original only (raised)
  for (const [name, lim, n] of [["lowered", lo, lo.hard + 1], ["raised", hi, base.hard + 1]]) {
    const t = limitsTree(path.join(F.work(), `tree-${name}`), "detail", lim.warn, lim.hard);
    F.check(`${name}: premise: the copied size-limits.js says detail ${lim.warn}/${lim.hard}`, t.ok, t.detail);
    if (!t.ok) continue;
    const tree = path.dirname(path.dirname(t.hook));
    const copied = require(path.join(tree, "hooks", "lib", "size-limits.js")).LIMITS.detail;
    const over = n > copied.hard;
    F.check(`${name}: premise: ${n} lines sit between the original HARD ${base.hard} and the copied HARD ${copied.hard}`,
      over !== (n > base.hard), JSON.stringify({ n, base, copied }));
    for (const [label, root, hard, blocks] of [["copied", tree, copied.hard, over], ["original (control)", F.ROOT, base.hard, n > base.hard]]) {
      const cs = C.session("detail", n);
      const rc = C.confirm(cs, "detail", { root });
      F.check(`${name} / ${label}: CONFIRM_DETAIL on a ${n}-line plan ${blocks ? `denies against HARD ${hard}` : "reaches the dialog"}`,
        blocks ? denied(rc, [path.basename(C.planPath(cs, "detail")), n, hard]) : dialog(rc) && !rc.deny, rc.raw);
      const ss = C.session("detail", n);
      const rs = C.stop(ss, C.layer2Transcript("detail"), { root });
      F.check(`${name} / ${label}: Stop on the same ${n}-line plan ${blocks ? `blocks against HARD ${hard}` : "stops quietly"}`,
        blocks ? C.blockedWith(rs, C.SIZE_PREFIX, [path.basename(C.planPath(ss, "detail")), n, hard]) : C.quiet(rs), rs.raw);
    }
  }
});
caseEnd();

// #2631 stage 9: an unknown session state (the size session gate cannot load the state reader, so
// readState throws, or the state file is corrupt) is checked, not exempt; a relint that skips (no
// readable plan) never blocks for size, so Layer 2 keeps passing an unjudgeable plan to the CONFIRM side.
const STATE_THROWS = { preload: C.THROW_PRELOAD, env: { F2631_THROW_MODULE: "hooks/workflow-state/state-io/core.js", F2631_THROW_PARENT: "hooks/lib/size-session-gate.js" } };
function gateStateUnder(sid, env) {
  const gate = JSON.stringify(path.join(F.ROOT, "hooks", "lib", "size-session-gate.js"));
  const r = require("child_process").spawnSync(process.execPath, ["-r", C.THROW_PRELOAD, "-e", `process.stdout.write(require(${gate}).sizeCheckState(${JSON.stringify(sid)}))`],
    { encoding: "utf8", timeout: 30000, env: Object.assign({}, process.env, env) });
  return r.stdout || `rc=${r.status} ${r.stderr}`;
}
function corruptSession(n) {
  const sid = F.newSid();
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`), "{ not json");
  if (n != null) C.writePlan(sid, "detail", C.planOf(n));
  return sid;
}

caseBegin("T1-unknown-session-state-blocks-over-hard", "hooks/stop-confirm-plan-guard.js");
F.run("T1", () => {
  const n = C.HARD.detail + 1;
  const sid = C.session("detail", n);
  const g = gateStateUnder(sid, STATE_THROWS.env);
  F.check("premise: under the preload the gate reports \"unknown\" (the injection reaches readState)", g === "unknown", g);
  F.check("premise: without the preload the same session is \"active\"", gateStateUnder(sid, { F2631_THROW_MODULE: "" }) === "active", "");
  const r = C.stop(sid, C.layer2Transcript("detail"), STATE_THROWS);
  F.check("readState throws, detail at HARD+1: blocks with the plan-size reason",
    C.blockedWith(r, C.SIZE_PREFIX, [path.basename(C.planPath(sid, "detail")), n]), r.raw);
  const ok = C.stop(C.session("detail", C.HARD.detail), C.layer2Transcript("detail"), STATE_THROWS);
  F.check("control: readState throws, detail at HARD: stops quietly", C.quiet(ok), ok.raw);
  const bad = corruptSession(n);
  const b = C.stop(bad, C.layer2Transcript("detail"));
  F.check("corrupt state, own detail at HARD+1: blocks with the plan-size reason",
    C.blockedWith(b, C.SIZE_PREFIX, [path.basename(C.planPath(bad, "detail")), n]), b.raw);
});
caseEnd();

caseBegin("T2-skipped-relint-never-blocks-for-size", "hooks/stop-confirm-plan-guard.js");
F.run("T2", () => {
  const dir = C.session("detail", null);
  fs.mkdirSync(C.planPath(dir, "detail"), { recursive: true });
  const d = C.stop(dir, C.layer2Transcript("detail"));
  F.check("started session, detail is a directory (relint unreadable): no plan-size block", !d.reason.startsWith(C.SIZE_PREFIX), d.raw);
  const none = C.stop(C.session("detail", null), C.layer2Transcript("detail"), STATE_THROWS);
  F.check("readState throws, no detail file (relint unreadable): no plan-size block", !none.reason.startsWith(C.SIZE_PREFIX), none.raw);
  const bad = C.stop(corruptSession(null), C.layer2Transcript("detail"));
  F.check("corrupt state, no detail file (relint unreadable): no plan-size block", !bad.reason.startsWith(C.SIZE_PREFIX), bad.raw);
});
caseEnd();

process.chdir(savedCwd);
restore();
const failed = F.failureCount();
console.log(failed === 0 ? "ALL PASS" : `${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
