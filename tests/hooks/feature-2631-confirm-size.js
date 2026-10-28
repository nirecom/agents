#!/usr/bin/env node
// tests/hooks/feature-2631-confirm-size.js
// Tests: hooks/confirm-checkpoint.js, hooks/lib/size-limits.js, hooks/lib/size-session-gate.js, hooks/workflow-state/plan-artifact-owner.js
// Tags: scope:issue-specific, size-limits, hook, pre-tool-use, confirm, plan-artifact, block, layer:TL2
// TL3 gap (what this test does NOT catch):
// - the real Claude Code host firing confirm-checkpoint on the CONFIRM echo and showing or skipping the dialog
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
"use strict";
// #2631 stage 4, PreToolUse: a CONFIRM_<STAGE> echo whose plan artifact is over HARD is denied
// (sent back to the planner) before the dialog, whatever CONFIRM_<STAGE> says; at or under HARD
// the dialog proceeds, with WARN advice above WARN. The size deny is disabled for WORKFLOW_OFF and
// judges the owner's file in a resumed session. Every echo follows a presentation receipt (#2729).
// The Stop-hook side: feature-2631-confirm-size-stop.js.

const path = require("path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const savedCwd = process.cwd();
const C = require("./feature-2631-confirm-size/fixture");
const { F } = C;
process.chdir(F.work());
const OFF_CFG = C.cfg("off", { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "off", PLAN_LANG: "english", PLAN_SYNC_REMOTE_URL: "" });
const boundary = (n) => new RegExp(`(^|[^0-9])${n}([^0-9]|$)`);

function denies(name, r, sid, stage, value) {
  const base = path.basename(C.planPath(sid, stage));
  const need = [base, String(value), String(C.HARD[stage]), C.SEND_BACK];
  const miss = need.filter((n) => !r.reason.includes(n));
  F.check(name, r.deny && miss.length === 0, `missing ${JSON.stringify(miss)} in ${r.raw}`);
}
// dialog(r) — the plain confirm dialog: no deny, "[<stage>] <plan path>" shown to the user.
const dialog = (r) => r.decision !== "block" && /^\[(intent|outline|detail)\] (?!plan-file=none)\S/.test(r.msg);

caseBegin("C1-over-hard-denies-per-stage", "hooks/confirm-checkpoint.js");
F.run("C1", () => {
  for (const stage of ["intent", "outline", "detail"]) {
    const n = C.HARD[stage] + 1;
    const sid = C.session(stage, n);
    denies(`${stage}: HARD+1 (${n}) denies the CONFIRM echo with the send-back reason`, C.confirm(sid, stage), sid, stage, n);
  }
});
caseEnd();

caseBegin("C2-at-hard-proceeds-with-warn-advice", "hooks/confirm-checkpoint.js");
F.run("C2", () => {
  for (const stage of ["intent", "outline", "detail"]) {
    const h = C.HARD[stage];
    const r = C.confirm(C.session(stage, h), stage);
    F.check(`${stage}: exactly HARD (${h}) proceeds to the dialog`, dialog(r), r.raw);
    F.check(`${stage}: over WARN adds WARN advice naming ${h}`, /WARN/.test(r.ctx) && boundary(h).test(r.ctx), r.raw);
    const w = C.confirm(C.session(stage, C.WARN[stage]), stage);
    F.check(`${stage}: exactly WARN (${C.WARN[stage]}) proceeds without advice`, dialog(w) && !/WARN/.test(w.ctx), w.raw);
  }
});
caseEnd();

caseBegin("C3-confirm-off-still-denies-over-hard", "hooks/confirm-checkpoint.js");
F.run("C3", () => {
  for (const stage of ["outline", "detail"]) {
    const ok = C.session(stage, C.HARD[stage]);
    const control = C.confirm(ok, stage, { cfg: OFF_CFG });
    F.check(`${stage}: control: CONFIRM_${stage.toUpperCase()}=off at HARD skips the dialog`,
      control.decision !== "block" && control.msg.includes(`CONFIRM_${stage.toUpperCase()}=off`), control.raw);
    const n = C.HARD[stage] + 1;
    const sid = C.session(stage, n);
    denies(`${stage}: CONFIRM_${stage.toUpperCase()}=off still denies HARD+1`, C.confirm(sid, stage, { cfg: OFF_CFG }), sid, stage, n);
  }
});
caseEnd();

// intent has no off waiver (plan-gate.js): CONFIRM_INTENT=off still shows the dialog at HARD.
caseBegin("C3-intent-confirm-off-has-no-waiver-and-still-denies-over-hard", "hooks/confirm-checkpoint.js");
F.run("C3-intent", () => {
  const intentOff = C.cfg("intent-off", { CONFIRM_INTENT: "off", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", PLAN_LANG: "english", PLAN_SYNC_REMOTE_URL: "" });
  const h = C.HARD.intent;
  const control = C.confirm(C.session("intent", h), "intent", { cfg: intentOff });
  F.check("intent: control: CONFIRM_INTENT=off at HARD still proceeds to the dialog (no off waiver)",
    dialog(control) && !control.msg.includes("CONFIRM_INTENT=off"), control.raw);
  const n = h + 1;
  const sid = C.session("intent", n);
  denies("intent: CONFIRM_INTENT=off still denies HARD+1", C.confirm(sid, "intent", { cfg: intentOff }), sid, "intent", n);
});
caseEnd();

caseBegin("C4-size-deny-repeats-and-precedes-the-receipt", "hooks/confirm-checkpoint.js");
F.run("C4", () => {
  const n = C.HARD.detail + 1;
  const sid = C.session("detail", n);
  for (let i = 1; i <= 3; i++) denies(`size deny #${i} still denies (no deny cap)`, C.confirm(sid, "detail"), sid, "detail", n);
  denies("without a presentation receipt the size deny still comes first", C.confirm(sid, "detail", { present: false }), sid, "detail", n);
});
caseEnd();

caseBegin("C5-workflow-off-disables-the-size-deny", "hooks/lib/size-session-gate.js");
F.run("C5", () => {
  const n = C.HARD.detail + 1;
  const off = C.session("detail", n);
  F.writeMarker(off, "workflow-off");
  const r = C.confirm(off, "detail");
  F.check("WORKFLOW_OFF session: HARD+1 proceeds to the dialog", dialog(r), r.raw);
  const on = C.session("detail", n);
  denies("control: the same plan in a started session denies", C.confirm(on, "detail"), on, "detail", n);
});
caseEnd();

caseBegin("C5b-never-started-session-skips-the-size-deny", "hooks/lib/size-session-gate.js");
F.run("C5b", () => {
  const n = C.HARD.detail + 1;
  const fresh = F.newSid();
  C.writePlan(fresh, "detail", C.planOf(n));
  const r = C.confirm(fresh, "detail");
  F.check("no workflow state: HARD+1 is not size-denied", !(r.deny && r.reason.includes(C.SEND_BACK)), r.raw);
  F.check("no workflow state: HARD+1 reaches the dialog, with no deny or block of any kind", dialog(r) && !r.deny && r.decision !== "block", r.raw);
  const on = C.session("detail", n);
  denies("control: the same plan in a started session denies", C.confirm(on, "detail"), on, "detail", n);
});
caseEnd();

// The symmetric half of C5b: the state file exists, but no step is self-recorded settled.
caseBegin("C5c-state-without-settled-step-skips-the-size-deny", "hooks/lib/size-session-gate.js");
F.run("C5c", () => {
  const fs = require("fs");
  const lc = F.load("hooks/workflow-state/lifecycle.js");
  const n = C.HARD.detail + 1;
  const at = new Date().toISOString();
  const variants = [
    { name: "empty event stream", events: [] },
    { name: "only an in_progress lookahead mark", events: [{ kind: "step_status", step: "workflow_init", status: "in_progress", provenance: "observed", origin: "postuse-in-flight", at, seq: 1 }] },
  ];
  for (const v of variants) {
    const sid = F.newSid();
    const statePath = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
    const state = { version: 5, session_id: sid, created_at: at, session_start_context: { cwd: F.work(), git_branch: "feature/f2631-fixture" }, events: v.events };
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
    C.writePlan(sid, "detail", C.planOf(n));
    F.check(`${v.name}: premise: the state file exists and holds no self-recorded settlement`,
      fs.existsSync(statePath) && lc.hasSelfRecordedStepSettlement(JSON.parse(fs.readFileSync(statePath, "utf8"))) === false, statePath);
    const r = C.confirm(sid, "detail");
    F.check(`${v.name}: HARD+1 is not size-denied (exempt)`, !(r.deny && r.reason.includes(C.SEND_BACK)), r.raw);
    F.check(`${v.name}: HARD+1 reaches the dialog, with no deny or block of any kind`, dialog(r) && !r.deny && r.decision !== "block", r.raw);
  }
  const on = C.session("detail", n);
  denies("control: the same plan in a started session denies", C.confirm(on, "detail"), on, "detail", n);
});
caseEnd();

caseBegin("C7-resumed-session-judges-the-owner-file", "hooks/workflow-state/plan-artifact-owner.js");
F.run("C7", () => {
  const n = C.HARD.detail + 1;
  const U = F.newSid();
  C.writePlan(U, "detail", C.planOf(n));
  const D = C.session("detail", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  denies("upstream_session_id: U's detail at HARD+1 denies in D", C.confirm(D, "detail"), U, "detail", n);

  // #2748: first_session_id names the plan of every generation (an approval record is no candidate).
  const X = F.newSid();
  C.writePlan(X, "detail", C.planOf(n));
  const D2 = C.session("detail", null, { top: { first_session_id: X } });
  denies("first_session_id: X's detail at HARD+1 denies in D2", C.confirm(D2, "detail"), X, "detail", n);

  const U3 = F.newSid();
  C.writePlan(U3, "detail", C.planOf(C.HARD.detail));
  const D3 = C.session("detail", null, { top: { upstream_session_id: U3, upstream_copy_seq: 0 } });
  const r = C.confirm(D3, "detail");
  F.check("upstream at exactly HARD proceeds (no deny)", r.decision !== "block" && r.msg !== "", r.raw);
});
caseEnd();

// The dialog and the model-facing plan-link line name the owner's file in a resumed session.
const NO_FILE = "no plan file for this stage yet";
const UNAVAILABLE = "file path unavailable";
// A missing plan file is denied before any dialog (#2729): no "path unavailable" dialog exists.
const noFileDeny = (r) => r.deny && r.reason.includes("unverifiable-artifact") && !r.msg.includes(UNAVAILABLE);
caseBegin("C8-resumed-session-dialog-shows-the-owner-path", "hooks/confirm-checkpoint.js");
F.run("C8", () => {
  for (const stage of ["intent", "outline", "detail"]) {
    const U = F.newSid();
    const uPath = C.writePlan(U, stage, C.planOf(10));
    const D = C.session(stage, null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
    const r = C.confirm(D, stage);
    F.check(`${stage}: D's dialog shows U's plan file`, dialog(r) && r.msg.includes(path.basename(uPath)) && !r.msg.includes(UNAVAILABLE), r.raw);
    F.check(`${stage}: D's dialog never names a D-${stage}.md`, !r.msg.includes(`${D}-${stage}.md`), r.raw);
    F.check(`${stage}: the model-facing line names U's file, not "${NO_FILE}"`, r.ctx.includes(path.basename(uPath)) && !r.ctx.includes(NO_FILE), r.raw);
  }
});
caseEnd();

// #2631 SSOT: an existing upstream file wins even over the session's own file; with a declared
// owner and no file, the own file is never shown: the echo is denied (#2729 fail-closed).
caseBegin("C9-upstream-file-wins-over-the-own-file", "hooks/confirm-checkpoint.js");
F.run("C9", () => {
  const U = F.newSid();
  C.writePlan(U, "intent", C.planOf(10));
  const S = C.session("intent", 12, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  const r = C.confirm(S, "intent");
  F.check("both exist: the dialog shows U's intent, not S's own", dialog(r) && r.msg.includes(`${U}-intent.md`) && !r.msg.includes(`${S}-intent.md`), r.raw);
  F.check("the dialog carries no upstream-owner note", !/owned by session upstream/.test(r.msg + r.ctx), r.raw);
  const L = C.session("intent", 12, { top: { upstream_session_id: F.newSid(), upstream_copy_seq: 0 } });
  const l = C.confirm(L, "intent");
  F.check("upstream without a file -> denied (unverifiable-artifact), never L's own intent", l.deny && l.reason.includes("unverifiable-artifact") && !(l.msg + l.reason).includes(`${L}-intent.md`), l.raw);
  const P = C.session("intent", 12);
  const p = C.confirm(P, "intent");
  F.check("non-resumed session: the dialog shows its own intent", dialog(p) && p.msg.includes(`${P}-intent.md`), p.raw);
});
caseEnd();

caseBegin("C10-resumed-session-owner-over-hard-intent-denies", "hooks/confirm-checkpoint.js");
F.run("C10", () => {
  const n = C.HARD.intent + 1;
  const U = F.newSid();
  C.writePlan(U, "intent", C.planOf(n));
  const D = C.session("intent", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  const r = C.confirm(D, "intent");
  denies("U's intent at HARD+1 denies D's CONFIRM_INTENT (no fail-open to the dialog)", r, U, "intent", n);
  F.check("the deny is not the plain dialog", !dialog(r), r.raw);
});
caseEnd();

caseBegin("C11-no-owner-and-no-own-file-is-denied", "hooks/confirm-checkpoint.js");
F.run("C11", () => {
  const lone = C.session("intent", null);
  const r = C.confirm(lone, "intent");
  F.check("no upstream, no own file: the echo is denied (unverifiable-artifact)", noFileDeny(r), r.raw);
  const D = C.session("detail", null, { top: { upstream_session_id: F.newSid(), upstream_copy_seq: 0 } });
  const d = C.confirm(D, "detail");
  F.check("upstream without a file: the echo is denied (unverifiable-artifact)", noFileDeny(d), d.raw);
});
caseEnd();

// resolveArtifact in-process: every unresolvable input returns null instead of throwing.
caseBegin("C12-resolve-artifact-boundaries-fail-open", "hooks/confirm-checkpoint.js");
F.run("C12", () => {
  const CK = F.load("hooks/confirm-checkpoint.js");
  const plans = process.env.WORKFLOW_PLANS_DIR;
  const U = F.newSid();
  const uPath = C.writePlan(U, "outline", C.planOf(5));
  const D = C.session("outline", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  F.check("resolveArtifact(D) returns U's outline", path.resolve(String(CK.resolveArtifact("outline", D, plans))) === path.resolve(uPath), CK.resolveArtifact("outline", D, plans));
  F.check("missing plans dir -> null", CK.resolveArtifact("outline", D, path.join(F.work(), "no-such-plans")) === null, "non-null");
  F.check("session id outside the id class -> null", CK.resolveArtifact("outline", "bad id/..", plans) === null, "non-null");
  F.check("no session -> null", CK.resolveArtifact("outline", null, plans) === null, "non-null");
  const T = F.newSid();
  F.writeStartedState(T, { upstream_session_id: "../escape", upstream_copy_seq: 0 });
  F.check("malformed upstream_session_id -> null (never a path outside the plans dir)", CK.resolveArtifact("outline", T, plans) === null, "non-null");
});
caseEnd();

// The resolver names U's path as the write target before it exists; the dialog never shows it.
caseBegin("C13-upstream-without-plan-is-missing-not-the-own-path", "hooks/workflow-state/plan-artifact-owner.js");
F.run("C13", () => {
  const CK = F.load("hooks/confirm-checkpoint.js");
  const plans = process.env.WORKFLOW_PLANS_DIR;
  const U = F.newSid();
  const D = C.session("outline", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  const o = F.load("hooks/workflow-state/plan-artifact-owner.js").resolvePlanArtifactOwner(D, "outline", undefined, { plansDir: plans });
  F.check("resolver: U's path, exists:false, via missing", o.via === "missing" && o.ownerSid === U && o.exists === false &&
    path.resolve(o.path) === path.resolve(C.planPath(U, "outline")), JSON.stringify(o));
  const got = CK.resolveArtifact("outline", D, plans);
  F.check("resolveArtifact(D) -> null (neither the missing U path nor D's own path)", got === null, String(got));
});
caseEnd();

// Order: a marker of this turn first, else the owner file in the plans dir. A marker path that is
// not the owner path is still denied downstream: judge() binds the approval to the owner path.
caseBegin("C14-turn-marker-first-and-a-foreign-marker-is-denied", "hooks/confirm-checkpoint.js");
F.run("C14", () => {
  const CK = F.load("hooks/confirm-checkpoint.js");
  const TM = F.load("hooks/lib/turn-marker.js");
  const plans = process.env.WORKFLOW_PLANS_DIR;
  const markerFile = path.join(F.work(), `marker-${F.newSid()}-detail.md`);
  require("fs").writeFileSync(markerFile, C.planOf(3));
  const U = F.newSid();
  const uPath = C.writePlan(U, "detail", C.planOf(4));
  const D = C.session("detail", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  F.check("no marker: resolveArtifact returns U's owner file", path.resolve(String(CK.resolveArtifact("detail", D, plans))) === path.resolve(uPath), "not U's file");
  TM.writeTurnMarker(D, { suffix: "detail", absPath: markerFile });
  const got = CK.resolveArtifact("detail", D, plans);
  F.check("both exist: resolveArtifact returns this turn's marker path", path.resolve(String(got)) === path.resolve(markerFile), String(got));
  const r = C.confirm(D, "detail", { present: false });
  F.check("a marker path that is not the owner path is denied (unverifiable-artifact)", r.deny && r.reason.includes("unverifiable-artifact"), r.raw);
});
caseEnd();

process.chdir(savedCwd);
restore();
const failed = F.failureCount();
console.log(failed === 0 ? "ALL PASS" : `${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
