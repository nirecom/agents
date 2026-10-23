#!/usr/bin/env node
// tests/hooks/feature-2631-confirm-size.js
// Tests: hooks/confirm-checkpoint.js, hooks/lib/size-limits.js, hooks/lib/size-session-gate.js, hooks/lib/confirm-deny-counter.js, hooks/workflow-state/plan-artifact-owner.js
// Tags: scope:issue-specific, size-limits, hook, pre-tool-use, confirm, plan-artifact, block, layer:TL2
// TL3 gap (what this test does NOT catch):
// - the real Claude Code host firing confirm-checkpoint on the CONFIRM echo and showing or skipping the dialog
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
"use strict";
// #2631 stage 4, PreToolUse: a CONFIRM_<STAGE> echo whose plan artifact is over HARD is denied
// (sent back to the planner) before the dialog, whatever CONFIRM_<STAGE> says; at or under HARD
// the dialog proceeds, with WARN advice above WARN. The size deny never touches the #2513 deny
// counter, is disabled for WORKFLOW_OFF, and judges the owner's file in a resumed session.
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
// dialog(r) — the plain confirm dialog: no deny, the plan file shown to the user.
const dialog = (r) => r.decision !== "block" && /Plan file:/.test(r.msg);

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

caseBegin("C4-size-deny-is-not-counted", "hooks/lib/confirm-deny-counter.js");
F.run("C4", () => {
  const counter = F.load("hooks/lib/confirm-deny-counter.js");
  const n = C.HARD.detail + 1;
  const sid = C.session("detail", n);
  F.check("fixture premise: counter seeded to 1", counter.bump(sid, "detail") === 1, counter.read(sid, "detail"));
  for (let i = 1; i <= 3; i++) denies(`size deny #${i} still denies (no deny cap)`, C.confirm(sid, "detail"), sid, "detail", n);
  F.check("the #2513 deny counter stays at 1", counter.read(sid, "detail") === 1, counter.read(sid, "detail"));
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

caseBegin("C7-resumed-session-judges-the-owner-file", "hooks/workflow-state/plan-artifact-owner.js");
F.run("C7", () => {
  const n = C.HARD.detail + 1;
  const U = F.newSid();
  C.writePlan(U, "detail", C.planOf(n));
  const D = C.session("detail", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  denies("upstream_session_id: U's detail at HARD+1 denies in D", C.confirm(D, "detail"), U, "detail", n);

  const X = F.newSid();
  const xText = C.planOf(n);
  C.writePlan(X, "detail", xText);
  const sha = require("crypto").createHash("sha256").update(xText).digest("hex");
  const approval = {
    kind: "plan_approval", step: "detail", source: "confirm-sentinel", reason: "fixture approval",
    artifact_sha256: sha, artifact_session_id: X, artifact_hash_status: "recorded", provenance: "declared", origin: "test-fixture",
  };
  const D2 = C.session("detail", null, { events: [approval] });
  denies("plan_approvals artifact_session_id: X's detail at HARD+1 denies in D2", C.confirm(D2, "detail"), X, "detail", n);

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
// owner and no file, the own file is never shown (path unavailable).
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
  F.check("upstream without a file -> 'Plan ready (file path unavailable)', never L's own intent", l.msg.includes("Plan ready (file path unavailable)") && !l.msg.includes(`${L}-intent.md`), l.raw);
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
  F.check("the deny is not the plain dialog", !/Plan file:/.test(r.msg), r.raw);
});
caseEnd();

caseBegin("C11-no-owner-and-no-own-file-stays-path-unavailable", "hooks/confirm-checkpoint.js");
F.run("C11", () => {
  const lone = C.session("intent", null);
  const r = C.confirm(lone, "intent");
  F.check("no upstream, no own file: the dialog says the path is unavailable", r.msg.includes(UNAVAILABLE), r.raw);
  const D = C.session("detail", null, { top: { upstream_session_id: F.newSid(), upstream_copy_seq: 0 } });
  const d = C.confirm(D, "detail");
  F.check("upstream without a file: the dialog says the path is unavailable", d.msg.includes(UNAVAILABLE) && d.decision !== "block", d.raw);
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
caseBegin("C13-upstream-without-plan-is-owner-missing-not-the-own-path", "hooks/workflow-state/plan-artifact-owner.js");
F.run("C13", () => {
  const CK = F.load("hooks/confirm-checkpoint.js");
  const plans = process.env.WORKFLOW_PLANS_DIR;
  const U = F.newSid();
  const D = C.session("outline", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  const o = F.load("hooks/workflow-state/plan-artifact-owner.js").resolvePlanArtifactOwner(D, "outline", undefined, { plansDir: plans });
  F.check("resolver: U's path, exists:false, via owner-missing", o.via === "owner-missing" && o.ownerSid === U && o.exists === false &&
    path.resolve(o.path) === path.resolve(C.planPath(U, "outline")), JSON.stringify(o));
  const got = CK.resolveArtifact("outline", D, plans);
  F.check("resolveArtifact(D) -> null (neither the missing U path nor D's own path)", got === null, String(got));
});
caseEnd();

// Order: the owner-resolved file beats the turn marker; the marker is only a fallback.
caseBegin("C14-owner-file-wins-over-the-turn-marker", "hooks/confirm-checkpoint.js");
F.run("C14", () => {
  const CK = F.load("hooks/confirm-checkpoint.js");
  const TM = F.load("hooks/lib/turn-marker.js");
  const plans = process.env.WORKFLOW_PLANS_DIR;
  const markerFile = path.join(F.work(), `marker-${F.newSid()}-detail.md`);
  require("fs").writeFileSync(markerFile, C.planOf(3));
  const U = F.newSid();
  const uPath = C.writePlan(U, "detail", C.planOf(4));
  const D = C.session("detail", null, { top: { upstream_session_id: U, upstream_copy_seq: 0 } });
  TM.writeTurnMarker(D, { suffix: "detail", absPath: markerFile });
  const got = CK.resolveArtifact("detail", D, plans);
  F.check("both exist: resolveArtifact returns U's file, not the marker path", path.resolve(String(got)) === path.resolve(uPath), String(got));
  const U2 = F.newSid();
  const D2 = C.session("detail", null, { top: { upstream_session_id: U2, upstream_copy_seq: 0 } });
  TM.writeTurnMarker(D2, { suffix: "detail", absPath: markerFile });
  const got2 = CK.resolveArtifact("detail", D2, plans);
  F.check("control: owner file missing, marker path unrelated to the owner -> null", got2 === null, String(got2));
  const U3 = F.newSid();
  const D3 = C.session("detail", null, { top: { upstream_session_id: U3, upstream_copy_seq: 0 } });
  TM.writeTurnMarker(D3, { suffix: "detail", absPath: C.planPath(U3, "detail") });
  const got3 = CK.resolveArtifact("detail", D3, plans);
  F.check("owner file missing, marker path equals the owner path -> returned", got3 !== null && path.resolve(String(got3)) === path.resolve(C.planPath(U3, "detail")), String(got3));
});
caseEnd();

process.chdir(savedCwd);
restore();
const failed = F.failureCount();
console.log(failed === 0 ? "ALL PASS" : `${failed} FAILED`);
process.exitCode = failed === 0 ? 0 : 1;
