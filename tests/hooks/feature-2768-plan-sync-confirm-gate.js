"use strict";
// tests/hooks/feature-2768-plan-sync-confirm-gate.js
// Tests: hooks/lib/plan-sync/commit-push.js, hooks/confirm-checkpoint.js
// Tags: scope:issue-specific, TL2, plan-sync, turn-commit, confirm-checkpoint, presentation-receipt, pre-confirm-audit, supervisor-audit
// #2768 T25: a same-turn replacement keeps the blob URL byte-identical, so the presentation receipt
// and the confirm gate pass as before; the auth backoff keeps published plans confirmable.
// #2853 P1-P8: the plan CONFIRM echo waits for a settled (or accepted) pre-confirm audit; P8 repeats it on every plan stage.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the real timing between the transcript's prompt record and UserPromptSubmit (the PROMPT_SKEW_MS premise)
// - which transcript a real subagent hook input points to (turn context is passed in-process here)
// - whether the model actually prints the TURN_DIFF_DUTY line (no live model is driven)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const path = require("node:path");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const { seedReceipt, receiptExists } = require("../lib/presentation-receipt-seed");
// #2853: the intent CONFIRM echo needs the intent's pre-confirm audit settled on the current plan.
const PCA = require("../lib/pre-confirm-audit-settle");
const CE = require("../lib/confirm-env-fixture");
const THROW_PRELOAD = F.slash(path.join(__dirname, "..", "lib", "artifact-key-throw-preload.js"));
const ACCEPT_SENTINEL = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";

// One plans dir at WORKFLOW_PLANS_DIR: the receipt seed and the hook resolve the plan there.
const repo = F.makeRepo("cg", { dir: F.slash(process.env.WORKFLOW_PLANS_DIR) });

function marker(sid, rel, stage) {
  require(path.join(F.ROOT, "hooks", "lib", "turn-marker")).writeTurnMarker(sid, {
    absPath: path.resolve(F.absOf(repo, rel)), suffix: stage || "intent", ts: Date.now(), created_at: new Date().toISOString() });
}
const STAGES = ["intent", "outline", "detail"];
const STEP_OF = { intent: "clarify_intent", outline: "outline", detail: "detail" };
// The outline / detail flags are read from $AGENTS_MAIN_ROOT/.env only (#2729): a root with every plan stage ON.
let onRoot = null;
const confirmOnRoot = () => onRoot || (onRoot = CE.confirmEnvRoot(F.DIRS.cfg, { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" }));
// confirm(sid, mode) -> confirm-checkpoint output for the CONFIRM_INTENT echo under CONFIRM_INTENT=<mode> (default on).
// opts.command replaces the echo; opts.throwKey makes the plan-artifact key computation throw in the hook;
// opts.stage (outline / detail) echoes that stage's CONFIRM under a config root with every stage ON.
function confirm(sid, mode, opts) {
  const o = opts || {};
  const stage = o.stage || "intent";
  const input = { tool_name: "Bash", tool_input: { command: o.command || `echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}>>"` }, session_id: sid,
    transcript_path: F.txPath(sid) };
  const env = Object.assign({ CONFIRM_INTENT: mode || "on" }, stage === "intent" ? {} : { AGENTS_MAIN_ROOT: confirmOnRoot() },
    o.throwKey ? { CC_ARTIFACT_KEY_THROW: "1" } : {});
  const res = F.runNode("hooks/confirm-checkpoint.js", input, { env, unset: ["SHOW_PLAN_LINK_NO_AUTO_OPEN", "SHOW_PLAN_LINK_NO_SPAWN"],
    nodeArgs: o.throwKey ? ["--require", THROW_PRELOAD] : [] });
  const hso = (res.json && res.json.hookSpecificOutput) || {};
  return Object.assign(res, { decision: hso.permissionDecision || "", ctx: hso.additionalContext || "",
    msg: (res.json && res.json.systemMessage) || "",
    reason: String((res.json && res.json.reason) || hso.permissionDecisionReason || "") });
}
// workflowState(sid) -> a workflow state file with workflow_init complete. The hook skips the audit
// check for a session without one (it could never arm), so every P case that expects the check writes it.
function workflowState(sid) {
  const io = require(path.join(F.ROOT, "hooks", "workflow-state", "state-io"));
  io.writeState(sid, io.createInitialState(sid, { cwd: F.DIRS.neutral, git_branch: "fixture" }));
  io.markStep(sid, "workflow_init", "complete");
  return io.getStatePath(sid);
}
// published(tag, stage, opts) -> {sid, a}: a <stage> plan (default intent; opts.body replaces its text) pushed with a
// blob URL, its turn marker, its receipt and a workflow state file (opts.noState omits it). The earlier stages' plans
// are written locally only: the hook reads them solely as audit-key input (computeArtifactKey hashes the local file).
// The sid is UUID-shaped: with a state file the size check resolves the plan by first_session_id.
function published(tag, stage, opts) {
  const st = stage || "intent";
  const sid = require("node:crypto").randomUUID();
  if (!(opts && opts.noState)) workflowState(sid);
  for (const prev of STAGES.slice(0, STAGES.indexOf(st))) F.writePlan(repo, F.planName(sid, prev), `${tag} ${prev} body\n`);
  const a = F.planName(sid, st);
  const r = F.writeSync(repo, a, (opts && opts.body) || `${tag} body\n`);
  marker(sid, a, st);
  F.check(`${tag} receipt seeded`, r.status === "pushed" && r.url === F.blobUrl(a) && Boolean(reseed(sid, st, a)), JSON.stringify(r));
  return { sid, a };
}
// reseed(sid, stage, a) -> the receipt path, binding the blob URL the sync verified (the hook re-derives it on its own).
const reseed = (sid, stage, a) => seedReceipt(sid, stage, { link: { kind: "url", value: F.blobUrl(a) } });
// gateAt(sid, stage) -> the parsed `next-step --gate` output for a session sitting at <stage> (earlier stages approved).
function gateAt(sid, stage) {
  const D = require("./feature-2853-pre-confirm-audit/driver");
  const steps = { workflow_init: "complete", clarify_intent: "pending" };
  const approvals = [];
  for (const prev of STAGES.slice(0, STAGES.indexOf(stage))) {
    Object.assign(steps, { [STEP_OF[prev]]: "complete", research: "complete", [STEP_OF[stage]]: "pending" });
    approvals.push({ step: STEP_OF[prev] });
  }
  D.X.F.writeState(sid, steps, approvals);
  return D.gate(sid, { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" });
}
const reached = (c, a) => c.code === 0 && c.decision !== "deny" && c.msg.includes(F.blobUrl(a));
const accept = (sid, runId) => require(path.join(F.ROOT, "hooks/lib/supervisor-block-override")).recordReviewedVerdictAcceptance(sid,
  { runId, reason: "fixture: the user reviewed the findings and accepts them", actor: "test-fixture" });
const backoff = () => {
  F.git(repo.dir, ["config", "--local", "plansync.remoteStateUrl", F.config(repo.dir, "remote.origin.url")]);
  F.git(repo.dir, ["config", "--local", "plansync.authBackoffUntil", String(Date.now() + 600000)]);
};
const unbackoff = () => {
  for (const k of ["plansync.remoteStateUrl", "plansync.authBackoffUntil"]) F.git(repo.dir, ["config", "--local", "--unset", k], true);
};

try {
caseBegin("T25 same-turn replacement keeps the receipt and the CONFIRM gate", "hooks/lib/plan-sync/commit-push.js");
  F.guard("T25", () => {
    const sid = F.newSid("t25");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    const n0 = F.bareCount(repo);
    const r1 = F.writeSync(repo, a, "first\n", { turn });
    const r2 = F.writeSync(repo, a, "second\n", { turn });
    F.check("T25 both syncs pushed with the same blob URL", r1.url === F.blobUrl(a) && r2.status === "pushed" && r2.url === r1.url,
      JSON.stringify([r1, r2]));
    F.check("T25 the second sync replaced the first (bare +1)", F.bareCount(repo) === n0 + 1, F.bareCount(repo) - n0);
    F.check("T25 the replacement is on main", F.showAt(repo, "refs/heads/main", a) === "second", F.showAt(repo, "refs/heads/main", a));
    marker(sid, a);
    F.check("T25 receipt seeded with the blob URL", Boolean(seedReceipt(sid, "intent")), "no receipt");
    PCA.settle(sid, "intent", "CONTINUE");
    const c = confirm(sid);
    F.check("T25 confirm exit 0, not denied", c.code === 0 && c.decision !== "deny", c.out || c.err);
    F.check("T25 systemMessage shows the blob URL", c.msg.includes(F.blobUrl(a)), c.msg);
    F.check("T25 additionalContext carries the same blob URL", c.ctx.includes(F.blobUrl(a)), c.ctx);
  });
  // Intent has no off waiver (#2277): CONFIRM_INTENT=off still runs the gate, so the replaced plan's
  // receipt must pass it exactly as under on, with the same blob URL and no skip message.
  F.guard("T25 CONFIRM_INTENT=off", () => {
    const sid = F.newSid("t25off");
    const turn = F.newTurn(sid);
    const a = F.planName(sid, "intent");
    F.writeSync(repo, a, "first\n", { turn });
    const r2 = F.writeSync(repo, a, "second\n", { turn });
    F.check("T25off the replacement pushed with the blob URL", r2.status === "pushed" && r2.url === F.blobUrl(a), JSON.stringify(r2));
    marker(sid, a);
    F.check("T25off receipt seeded with the blob URL", Boolean(seedReceipt(sid, "intent")), "no receipt");
    PCA.settle(sid, "intent", "CONTINUE");
    const c = confirm(sid, "off");
    F.check("T25off intent is not skipped", c.code === 0 && !c.msg.includes("[confirm-skipped"), c.out || c.err);
    F.check("T25off confirm not denied", c.decision !== "deny", c.out || c.err);
    F.check("T25off systemMessage and additionalContext show the blob URL", c.msg.includes(F.blobUrl(a)) && c.ctx.includes(F.blobUrl(a)),
      c.out);
  });
caseEnd();
caseBegin("auth backoff keeps a published plan confirmable and an unpublished one fail-closed", "hooks/confirm-checkpoint.js");
  // The changed-content guard edits the plan this guard published ("published" is its v1 on the bare).
  const c1 = { sid: F.newSid("cgb") };
  c1.a = F.planName(c1.sid, "intent");
  F.guard("backoff: published plan", () => {
    const { sid, a } = c1;
    F.writeSync(repo, a, "published\n");
    try {
      backoff();
      const r = F.sync(repo, a);
      F.check("C1 published content keeps pushed + URL under the backoff", r.status === "pushed" && r.url === F.blobUrl(a), JSON.stringify(r));
      marker(sid, a);
      F.check("C1 receipt seeded", Boolean(seedReceipt(sid, "intent")), "no receipt");
      PCA.settle(sid, "intent", "CONTINUE");
      const c = confirm(sid);
      F.check("C1 confirm not denied, URL shown", c.code === 0 && c.decision !== "deny" && c.msg.includes(F.blobUrl(a)), c.out || c.err);
    } finally { unbackoff(); }
  });
  F.guard("backoff: changed content", () => {
    const { sid, a } = c1;
    try {
      backoff();
      const r = F.writeSync(repo, a, "v2 never sent\n");
      F.check("C1 changed content fails auth-backoff", r.status === "failed" && r.reason === "auth-backoff", JSON.stringify(r));
      F.check("C1 bare still holds v1", F.showAt(repo, "refs/heads/main", a) === "published", F.showAt(repo, "refs/heads/main", a));
      marker(sid, a);
      F.check("C1 no receipt for unpublished content", seedReceipt(sid, "intent") === null, "receipt seeded");
      PCA.settle(sid, "intent", "CONTINUE");
      const c = confirm(sid);
      F.check("C1 confirm denies the unpublished plan", c.code === 0 && c.decision === "deny", c.out || c.err);
    } finally { unbackoff(); }
  });
caseEnd();
// P5 reuses P1's plan: its intent audit stays unsettled and its receipt kept after P1's deny.
let p1 = null;
caseBegin("P1 unsettled intent audit: deny, keep the receipt", "hooks/confirm-checkpoint.js");
  F.guard("P1", () => {
    const { sid } = published("p1");
    const c = confirm(sid);
    F.check("P1 unsettled: denied", c.code === 0 && c.decision === "deny", c.out || c.err);
    F.check("P1 unsettled: receipt kept", receiptExists(sid, "intent"), "receipt consumed");
    F.check("P1 unsettled: reason says rerun next-step --gate", c.reason.includes("--gate"), c.reason);
    p1 = { sid };
  });
caseEnd();
// P3 accepts the run P2 denied on the same plan: P2's deny is P3's before-the-acceptance control.
let p2 = null;
caseBegin("P2 BLOCK verdict: deny", "hooks/confirm-checkpoint.js");
  F.guard("P2", () => {
    const { sid, a } = published("p2");
    const runId = PCA.settle(sid, "intent", "BLOCK");
    const c = confirm(sid);
    F.check("P2 BLOCK: denied", c.code === 0 && c.decision === "deny", c.out || c.err);
    F.check("P2 BLOCK: receipt kept", receiptExists(sid, "intent"), "receipt consumed");
    F.check("P2 BLOCK: reason carries the acceptance guidance", c.reason.includes(ACCEPT_SENTINEL), c.reason);
    p2 = { sid, a, runId };
  });
caseEnd();
caseBegin("P3 accepted BLOCK: the receipt check runs", "hooks/confirm-checkpoint.js");
  F.guard("P3", () => {
    const { sid, a, runId } = p2;
    const acc = accept(sid, runId) || {};
    F.check("P3 acceptance recorded", acc.ok === true, JSON.stringify(acc));
    const c = confirm(sid);
    F.check("P3 accepted BLOCK: dialog with the blob URL", reached(c, a), c.out || c.err);
  });
caseEnd();
caseBegin("P4 WARN and CONTINUE: the receipt check runs as before", "hooks/confirm-checkpoint.js");
  for (const v of ["WARN", "CONTINUE"]) {
    F.guard(`P4 ${v}`, () => {
      const { sid, a } = published(`p4${v.toLowerCase()}`);
      // Negative control: the same fixture before the settle is denied, so the pass below is the audit's doing.
      const pre = confirm(sid);
      F.check(`P4 ${v}: before the settle, denied by the audit`, pre.decision === "deny" && pre.reason.includes("[pre-confirm-audit]")
        && receiptExists(sid, "intent"), pre.out || pre.err);
      const runId = PCA.settle(sid, "intent", v);
      // CONFIRM first: gateAt writes a workflow state, after which this fixture's non-UUID plan name stops resolving.
      const c = confirm(sid);
      F.check(`P4 ${v}: dialog with the blob URL`, reached(c, a), c.out || c.err);
      if (v === "WARN") {
        // The approval presentation is built from the gate output: the WARN summary rides its own data line,
        // never GATE_HINT (subagent-written text is not an instruction); the hint names the run id only.
        const g = gateAt(sid, "intent");
        const summary = `fixture WARN summary for ${runId}`;
        F.check("P4 WARN: gate answers ask", g.action === "ask", g.out || g.err);
        F.check("P4 WARN: GATE_AUDIT_VERDICT=WARN", g.lines.GATE_AUDIT_VERDICT === "WARN", g.out);
        F.check("P4 WARN: GATE_AUDIT_RUN_ID names the WARN run", g.lines.GATE_AUDIT_RUN_ID === runId, g.out);
        F.check("P4 WARN: GATE_AUDIT_SUMMARY carries the WARN summary", g.lines.GATE_AUDIT_SUMMARY === summary, g.out);
        F.check("P4 WARN: GATE_HINT does not carry the summary text", !g.hint.includes(summary), g.hint || g.out);
        F.check("P4 WARN: GATE_HINT names the run id", g.hint.includes(runId), g.hint || g.out);
      }
    });
  }
caseEnd();
caseBegin("P8 every plan stage: unsettled and BLOCK deny, settled or accepted pass", "hooks/confirm-checkpoint.js");
  for (const stage of STAGES) {
    const tag = `[${stage}]`;
    F.guard(`P8 ${stage} unsettled / BLOCK / accepted`, () => {
      const { sid, a } = published(`p8${stage}u`, stage);
      const u = confirm(sid, "on", { stage });
      F.check(`P8 ${tag} unsettled: denied`, u.code === 0 && u.decision === "deny", u.out || u.err);
      F.check(`P8 ${tag} unsettled: receipt kept`, receiptExists(sid, stage), "receipt consumed");
      const runId = PCA.settle(sid, stage, "BLOCK");
      // Re-seed: each step judges its own CONFIRM, independent of whether the previous one spent the receipt.
      reseed(sid, stage, a);
      const b = confirm(sid, "on", { stage });
      F.check(`P8 ${tag} BLOCK: denied`, b.code === 0 && b.decision === "deny", b.out || b.err);
      F.check(`P8 ${tag} BLOCK: receipt kept`, receiptExists(sid, stage), "receipt consumed");
      F.check(`P8 ${tag} BLOCK: reason carries the acceptance guidance`, b.reason.includes(ACCEPT_SENTINEL), b.reason);
      const acc = accept(sid, runId) || {};
      F.check(`P8 ${tag} acceptance recorded`, acc.ok === true, JSON.stringify(acc));
      reseed(sid, stage, a);
      const c = confirm(sid, "on", { stage });
      F.check(`P8 ${tag} accepted BLOCK: dialog with the blob URL`, reached(c, a), c.out || c.err);
    });
    // Intent WARN / CONTINUE is P4's (same fixture shape, same confirm). One fixture per later stage: WARN is judged
    // first with no earlier run; CONTINUE then settles a newer run on the same plan, with the receipt re-seeded.
    if (stage === "intent") continue;
    F.guard(`P8 ${stage} WARN / CONTINUE`, () => {
      const { sid, a } = published(`p8${stage}s`, stage);
      for (const v of ["WARN", "CONTINUE"]) {
        if (v === "CONTINUE") reseed(sid, stage, a);
        PCA.settle(sid, stage, v);
        const c = confirm(sid, "on", { stage });
        F.check(`P8 ${tag} ${v}: dialog with the blob URL`, reached(c, a), c.out || c.err);
      }
    });
  }
caseEnd();
caseBegin("P5 a non-plan CONFIRM echo is not gated by the audit", "hooks/confirm-checkpoint.js");
  F.guard("P5", () => {
    const { sid } = p1;
    const c = confirm(sid, "on", { command: 'echo "<<WORKFLOW_CONFIRM_DOCS>>"' });
    F.check("P5 CONFIRM_DOCS with an unsettled intent audit: not denied", c.code === 0 && c.decision !== "deny", c.out || c.err);
    F.check("P5 the intent receipt is untouched", receiptExists(sid, "intent"), "receipt consumed");
  });
caseEnd();
// P7 reuses P6's published plan (its receipt kept by P6's deny); P7 settles its own BLOCK run over P6's CONTINUE.
let p6 = null;
caseBegin("P6 judgment error without acceptance: deny, keep the receipt", "hooks/confirm-checkpoint.js");
  F.guard("P6", () => {
    const { sid, a } = published("p6");
    PCA.settle(sid, "intent", "CONTINUE");
    const c = confirm(sid, "on", { throwKey: true });
    F.check("P6 error: denied (fail-closed)", c.code === 0 && c.decision === "deny", c.out || c.err);
    F.check("P6 error: receipt kept", receiptExists(sid, "intent"), "receipt consumed");
    F.check("P6 error: reason carries the acceptance guidance", c.reason.includes(ACCEPT_SENTINEL), c.reason);
    p6 = { sid, a };
  });
caseEnd();
caseBegin("P7 judgment error with an accepted last run: the receipt check runs", "hooks/confirm-checkpoint.js");
  F.guard("P7", () => {
    const { sid, a } = p6;
    const runId = PCA.settle(sid, "intent", "BLOCK");
    // Negative control: the BLOCK before its acceptance is denied under the same thrown key computation.
    const pre = confirm(sid, "on", { throwKey: true });
    F.check("P7 before the acceptance: denied", pre.decision === "deny" && receiptExists(sid, "intent"), pre.out || pre.err);
    const acc = accept(sid, runId) || {};
    F.check("P7 acceptance recorded", acc.ok === true, JSON.stringify(acc));
    const c = confirm(sid, "on", { throwKey: true });
    F.check("P7 error + accepted run: dialog with the blob URL", reached(c, a), c.out || c.err);
  });
caseEnd();
caseBegin("P9 no workflow state file: the audit check is skipped (it could never arm)", "hooks/confirm-checkpoint.js");
  F.guard("P9", () => {
    const { sid, a } = published("p9", "intent", { noState: true });
    const c = confirm(sid);
    F.check("P9 unsettled audit, no state file: dialog with the blob URL", reached(c, a), c.out || c.err);
    F.check("P9 no [pre-confirm-audit] deny", !c.reason.includes("[pre-confirm-audit]"), c.reason);
  });
caseEnd();
// offMarker(sid) -> the WORKFLOW_OFF marker the hooks read through isWorkflowOff(sid).
const offMarker = (sid) => require("node:fs").writeFileSync(
  path.join(require(path.join(F.ROOT, "hooks", "workflow-state")).getSessionStateDir(sid), `${sid}.workflow-off`), "fixture\n");
caseBegin("P10 WORKFLOW_OFF waives only the audit: the receipt and the size check still deny", "hooks/confirm-checkpoint.js");
  let p10 = null;
  F.guard("P10 audit waived", () => {
    const { sid, a } = published("p10");
    offMarker(sid);
    const c = confirm(sid);
    F.check("P10 unsettled audit under WORKFLOW_OFF: dialog with the blob URL", reached(c, a), c.out || c.err);
    const again = confirm(sid);
    F.check("P10 the spent receipt still denies under WORKFLOW_OFF", again.decision === "deny"
      && !again.reason.includes("[pre-confirm-audit]"), again.out || again.err);
    p10 = { sid, a };
  });
  // Same WORKFLOW_OFF session: a fresh receipt for the presented content, then the plan is changed and re-published.
  F.guard("P10 receipt mismatch", () => {
    const { sid, a } = p10;
    F.check("p10m receipt seeded", Boolean(reseed(sid, "intent", a)), "no receipt");
    F.writeSync(repo, a, "p10m body changed after the presentation\n");
    const c = confirm(sid);
    F.check("P10 a receipt for other content denies under WORKFLOW_OFF", c.decision === "deny"
      && !c.reason.includes("[pre-confirm-audit]"), c.out || c.err);
  });
  // The size check keeps its own rule (size-session-gate.js, #2631): WORKFLOW_OFF already exempted it before
  // #2853. With the marker an over-HARD plan is not size-denied; without it the same plan is.
  F.guard("P10 size HARD", () => {
    const big = Array.from({ length: 260 }, (_, i) => `line ${i}`).join("\n") + "\n";
    const { sid, a } = published("p10s", "intent", { body: big });
    PCA.settle(sid, "intent", "CONTINUE");
    for (const off of [false, true]) {
      if (off) { offMarker(sid); reseed(sid, "intent", a); }
      const c = confirm(sid);
      const sized = c.decision === "deny" && /plan-size|size/i.test(c.reason) && !c.reason.includes("[pre-confirm-audit]");
      F.check(`P10 over-HARD intent ${off ? "with" : "without"} WORKFLOW_OFF: size deny ${off ? "waived as before" : "applies"}`,
        off ? !sized && reached(c, a) : sized, c.reason || c.out || c.err);
    }
  });
caseEnd();
// An unreadable state file is not an absent one: the absence exemption (P9) does not apply, so an
// unsettled audit still denies. The supervisor state holding the audit fails closed the same way.
// P11 runs last and reuses P1's plan (unsettled, receipt kept) and P6/P7's plan (re-seeded, then settled).
caseBegin("P11 an unreadable state file keeps the audit deny, unlike an absent one", "hooks/confirm-checkpoint.js");
  F.guard("P11 workflow state", () => {
    const { sid } = p1;
    require("node:fs").writeFileSync(require(path.join(F.ROOT, "hooks", "workflow-state", "state-io")).getStatePath(sid), "{not json");
    const c = confirm(sid);
    F.check("P11 corrupt workflow state, unsettled audit: denied by the audit", c.code === 0 && c.decision === "deny"
      && c.reason.includes("[pre-confirm-audit]"), c.out || c.err);
    F.check("P11 corrupt workflow state: receipt kept", receiptExists(sid, "intent"), "receipt consumed");
  });
  F.guard("P11 supervisor state", () => {
    const { sid, a } = p6;
    F.check("p11s receipt seeded", Boolean(reseed(sid, "intent", a)), "no receipt");
    PCA.settle(sid, "intent", "CONTINUE");
    require("node:fs").writeFileSync(require(path.join(F.ROOT, "hooks", "lib", "supervisor-state-writer", "shared")).getStatePath(sid), "{not json");
    const c = confirm(sid);
    F.check("P11 corrupt supervisor state after a settle: denied by the audit", c.code === 0 && c.decision === "deny"
      && c.reason.includes("[pre-confirm-audit]"), c.out || c.err);
    F.check("P11 corrupt supervisor state: receipt kept", receiptExists(sid, "intent"), "receipt consumed");
  });
caseEnd();
} finally {
  F.finish();
  restore();
}
