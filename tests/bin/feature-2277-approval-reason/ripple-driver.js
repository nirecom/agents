"use strict";
// #2277 driver: one case per APPROVAL_GATED_STEPS consumer once clarify_intent joins the
// gated set — reset (RESET_FROM sentinel), mark (next-step --mark), record-step-verdict,
// inheritance, reconcile-state. Modes: reset | mark | verdict | inherit | reconcile.

const path = require("path");
const F = require("../../hooks/feature-2277-plan-approval-gate/fixture");

const TOP = { closes_issues: [1] };
const MARK_HOOK = "hooks/workflow-mark.js";

function markHook(sid, command) {
  return F.runNode(MARK_HOOK, [], JSON.stringify({ session_id: sid, tool_name: "Bash", tool_input: { command },
    tool_response: { exit_code: 0, stdout: "", stderr: "" } }));
}
const events = (sid, pred) => (F.rawEvents(sid) || []).filter(pred);

function modeReset() {
  // RESET_FROM_outline force-completes clarify_intent: it must carry a reset-sentinel audit record.
  let sid = F.newSid("rs-ol");
  F.writePlan(sid, "intent"); F.writePlan(sid, "outline");
  F.writeState(sid, { workflow_init: "complete", clarify_intent: "complete", research: "complete", outline: "complete" },
    [{ step: "clarify_intent" }, { step: "outline" }], TOP);
  markHook(sid, 'echo "<<WORKFLOW_RESET_FROM_outline: fixture rollback reason>>"');
  F.check("reset from outline: outline back to pending", F.readStep(sid, "outline") === "pending", F.readStep(sid, "outline"));
  const audit = events(sid, (e) => e.kind === "plan_approval" && e.step === "clarify_intent" && e.source === "reset-sentinel");
  F.check("reset from outline: clarify_intent gets a reset-sentinel approval", audit.length === 1, JSON.stringify(audit));
  // RESET_FROM_clarify_intent takes clarify_intent out of complete: its approval is revoked.
  sid = F.newSid("rs-ci");
  F.writePlan(sid, "intent");
  F.writeState(sid, { workflow_init: "complete", clarify_intent: "complete", research: "complete" },
    [{ step: "clarify_intent" }], TOP);
  markHook(sid, 'echo "<<WORKFLOW_RESET_FROM_clarify_intent: fixture rollback reason>>"');
  F.check("reset from clarify_intent: clarify_intent back to pending",
    F.readStep(sid, "clarify_intent") === "pending", F.readStep(sid, "clarify_intent"));
  const revoked = events(sid, (e) => e.kind === "plan_approval_revoked" && e.step === "clarify_intent");
  F.check("reset from clarify_intent: the clarify_intent approval is revoked", revoked.length === 1, JSON.stringify(revoked));
}

function pendingIntent(tag) {
  const sid = F.newSid(tag);
  F.writePlan(sid, "intent");
  F.writeState(sid, { workflow_init: "complete", clarify_intent: "pending" }, [], TOP);
  return sid;
}

function modeMark() {
  const sid = pendingIntent("mk");
  const r = F.runNode("bin/workflow/next-step", ["--session", sid, "--mark", "clarify_intent"], "");
  F.check("--mark clarify_intent without approval exits non-zero", r.code !== 0, `exit=${r.code} out=${r.out}`);
  F.check("--mark clarify_intent refusal names WORKFLOW_CONFIRM_INTENT", r.err.includes("WORKFLOW_CONFIRM_INTENT"), r.err);
  F.check("--mark clarify_intent refusal never names WORKFLOW_CONFIRM_CLARIFY_INTENT",
    !r.err.includes("WORKFLOW_CONFIRM_CLARIFY_INTENT"), r.err);
  F.check("--mark clarify_intent leaves it pending", F.readStep(sid, "clarify_intent") === "pending", F.readStep(sid, "clarify_intent"));
}

function modeVerdict() {
  const { recordStepVerdict } = require(path.join(F.ROOT, "hooks/workflow-state/record-step-verdict.js"));
  const sid = pendingIntent("rv");
  let res;
  try { res = recordStepVerdict(sid, "clarify_intent", "complete", { gate: "advance" }); } catch (e) { res = { threw: e.message }; }
  F.check("recordStepVerdict clarify_intent complete without approval is refused as unapproved",
    res && res.ok === false && res.kind === "unapproved", JSON.stringify(res));
  const msg = (res && res.message) || "";
  F.check("recordStepVerdict refusal names WORKFLOW_CONFIRM_INTENT", msg.includes("WORKFLOW_CONFIRM_INTENT"), msg);
  F.check("recordStepVerdict refusal never names WORKFLOW_CONFIRM_CLARIFY_INTENT",
    !msg.includes("WORKFLOW_CONFIRM_CLARIFY_INTENT"), msg);
  F.check("recordStepVerdict leaves clarify_intent pending", F.readStep(sid, "clarify_intent") === "pending",
    F.readStep(sid, "clarify_intent"));
}

function modeInherit() {
  const { applyInheritance } = require(path.join(F.ROOT, "hooks/workflow-state/inheritance"));
  const WS = require(path.join(F.ROOT, "hooks/workflow-state"));
  const donor = F.newSid("inh-donor");
  F.writePlan(donor, "intent");
  F.writeState(donor, { workflow_init: "complete", clarify_intent: "complete", research: "complete" }, [], TOP);
  const heir = F.newSid("inh-heir");
  F.writeState(heir, {}, [], TOP);
  let threw = null;
  try { applyInheritance(heir, new Date().toISOString(), WS.readState(donor), {}); } catch (e) { threw = e.message; }
  F.check("inheritance: donor with no clarify_intent record is inheritable", threw === null, String(threw));
  F.check("inheritance: heir clarify_intent complete", F.readStep(heir, "clarify_intent") === "complete", F.readStep(heir, "clarify_intent"));
  const audit = events(heir, (e) => e.kind === "plan_approval" && e.step === "clarify_intent" && e.source === "session-inherit");
  F.check("inheritance: clarify_intent gets no session-inherit audit approval", audit.length === 0, JSON.stringify(audit));
  const { evaluateCompletionApproval } = require(path.join(F.ROOT, "hooks/workflow-state/completion-approval"));
  F.check("inheritance: heir clarify_intent stays unapproved until CONFIRM_INTENT",
    evaluateCompletionApproval(heir, "clarify_intent", WS.readState(heir)).approved === false, "approved");
}

function modeReconcile() {
  const sid = pendingIntent("rc");
  const r = F.runNode("bin/workflow/reconcile-state", ["--session", sid], "");
  F.check("reconcile-state: exits 0", r.code === 0, `exit=${r.code} err=${r.err}`);
  F.check("reconcile-state: intent.md alone does not complete clarify_intent",
    F.readStep(sid, "clarify_intent") === "pending", `${F.readStep(sid, "clarify_intent")} ${r.out}`);
  F.check("reconcile-state: reports the missing approval with WORKFLOW_CONFIRM_INTENT",
    /clarify_intent: pending \(evidence present, approval missing/.test(r.out) && r.out.includes("WORKFLOW_CONFIRM_INTENT"), r.out);
}

const mode = process.argv[2];
const MODES = { reset: modeReset, mark: modeMark, verdict: modeVerdict, inherit: modeInherit, reconcile: modeReconcile };
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
