"use strict";
// Driver for ../feature-2513-confirm-deny-no-approval.sh. Replays the host's hook order for one
// CONFIRM_<STAGE> echo: PreToolUse hooks/confirm-checkpoint.js first; only when it does not deny
// does the host run the tool and then PostToolUse hooks/workflow-mark.js. Then it reads what the
// echo left behind: the plan_approvals record, the check-plan-approval CLI, the Skill gate and
// next-step --advance. argv: <stage>. Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const F = require("../feature-2277-plan-approval-gate/fixture");

const STAGE = process.argv[2];
const STEP = { intent: "clarify_intent", outline: "outline", detail: "detail" }[STAGE];
const NEXT_SKILL = { intent: "make-outline-plan", outline: "make-detail-plan", detail: "write-tests" }[STAGE];
const TDIR = process.env.CDN_TDIR;
const ECHO = `echo "<<WORKFLOW_CONFIRM_${String(STAGE).toUpperCase()}: approve the ${STAGE} plan>>"`;
const ARMED = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" };
if (!STEP || !TDIR) { F.check("driver arguments", false, `stage=${STAGE} tdir=${TDIR}`); process.exit(0); }

const U = (text) => ({ type: "user", message: { role: "user", content: text } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
let seq = 0;

// newSession(tag) -> {sid, line}: a session sitting at STEP, every earlier gated stage approved.
function newSession(tag) {
  const sid = `2513ffff-${String(++seq).padStart(4, "0")}-4aaa-8bbb-${String(process.pid % 1e12).padStart(12, "0")}`;
  const steps = { workflow_init: "complete", clarify_intent: "pending" };
  const approvals = [];
  F.writePlan(sid, "intent");
  if (STEP !== "clarify_intent") {
    Object.assign(steps, { clarify_intent: "complete", research: "complete", outline: "pending" });
    approvals.push({ step: "clarify_intent" });
    F.writePlan(sid, "outline");
  }
  if (STEP === "detail") {
    Object.assign(steps, { outline: "complete", detail: "pending" });
    approvals.push({ step: "outline" });
    F.writePlan(sid, "detail");
  }
  F.writeState(sid, steps, approvals);
  const fwd = path.resolve(F.planPath(sid, STAGE)).replace(/\\/g, "/");
  return { sid, tag, line: `${STAGE}: \`${fwd}\` (no URL: plan-sync-off)` };
}

// The previous turn either ends on the plan-link line or never shows it; a real reply follows.
function transcript(s, presented) {
  const entries = [U("write the plan"), A(T("Here is the plan summary.")), A(T(presented ? s.line : "The plan is ready.")),
    U("looks good, go ahead")];
  const tp = path.join(TDIR, `t-${s.sid}-${++seq}.jsonl`);
  fs.writeFileSync(tp, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return tp;
}

// hostEcho(s, presented) -> {deny, pre, post}: PreToolUse, then PostToolUse only when not denied.
function hostEcho(s, presented) {
  const tool_input = { command: ECHO };
  // #2853: settle the stage's pre-confirm audit on the plan as it is now; this driver tests the Deny path.
  require("../../lib/pre-confirm-audit-settle").trySettle(s.sid, STAGE, "CONTINUE");
  const pre = F.runNode("hooks/confirm-checkpoint.js", [], JSON.stringify({ session_id: s.sid,
    transcript_path: transcript(s, presented), hook_event_name: "PreToolUse", cwd: TDIR, tool_name: "Bash", tool_input }), ARMED);
  let j = {};
  try { j = pre.out ? JSON.parse(pre.out) : {}; } catch (_) { j = {}; }
  const deny = !!(j.hookSpecificOutput && j.hookSpecificOutput.permissionDecision === "deny");
  const post = deny ? null : F.runNode("hooks/workflow-mark.js", [], JSON.stringify({ session_id: s.sid,
    hook_event_name: "PostToolUse", tool_name: "Bash", tool_input,
    tool_response: { exit_code: 0, stdout: "", stderr: "" } }), ARMED);
  return { deny, pre, post };
}

const approvalEvents = (sid) => (F.rawEvents(sid) || []).filter((e) => e && e.kind === "plan_approval" && e.step === STEP);
const cliVerdict = (sid) => F.runNode("bin/workflow/check-plan-approval", ["--session", sid, "--step", STEP], "", ARMED).out.trim();
const skillGate = (sid) => F.runNode("hooks/gate-plan-skill-advance.js", [], JSON.stringify({
  hook_event_name: "PreToolUse", tool_name: "Skill", tool_input: { skill: NEXT_SKILL }, session_id: sid }), ARMED);
const advance = (sid) => F.runNode("bin/workflow/next-step", ["--session", sid, "--advance", "--step", STEP, "--complete"], "", ARMED);
const gateDenies = (r) => /"permissionDecision"\s*:\s*"deny"/.test(r.out);

// #2729: the judge reads only the presentation receipt the Stop hook wrote; the transcript shape
// decides nothing. seed(s) stands in for that Stop hook (plan-sync off -> a path receipt).
const RS = require("../../lib/presentation-receipt-seed");
const seed = (s) => RS.seedReceipt(s.sid, STAGE);

// Denied echo: no record, nothing downstream may complete the stage.
{
  const s = newSession("denied");
  const h = hostEcho(s, false);
  F.check(`${STAGE} denied echo — confirm-checkpoint denies`, h.deny && h.pre.code === 0, h.pre.out + h.pre.err);
  F.check(`${STAGE} denied echo — no plan_approval event for ${STEP}`, approvalEvents(s.sid).length === 0, JSON.stringify(approvalEvents(s.sid)));
  F.check(`${STAGE} denied echo — check-plan-approval says unapproved`, cliVerdict(s.sid) === "APPROVAL=unapproved", cliVerdict(s.sid));
  const g = skillGate(s.sid);
  F.check(`${STAGE} denied echo — Skill gate denies ${NEXT_SKILL}`, g.code === 0 && gateDenies(g), g.out + g.err);
  const a = advance(s.sid);
  F.check(`${STAGE} denied echo — next-step --advance refuses (non-zero)`, a.code !== 0, `exit=${a.code}`);
  F.check(`${STAGE} denied echo — ${STEP} stays not complete`, F.readStep(s.sid, STEP) !== "complete", F.readStep(s.sid, STEP));
}

// #2729: the previous turn ends on the plan-link line, but no receipt exists -> still denied.
{
  const s = newSession("shape-only");
  const h = hostEcho(s, true);
  F.check(`${STAGE} presented transcript without a receipt — confirm-checkpoint denies`, h.deny && h.pre.code === 0, h.pre.out + h.pre.err);
  F.check(`${STAGE} presented transcript without a receipt — no plan_approval event`, approvalEvents(s.sid).length === 0, JSON.stringify(approvalEvents(s.sid)));
}

// Allowed control: same session shape plus the presentation receipt.
{
  const s = newSession("allowed");
  F.check(`${STAGE} allowed echo — receipt seeded`, !!seed(s), RS.receiptPath(s.sid, STAGE));
  const h = hostEcho(s, true);
  F.check(`${STAGE} allowed echo — confirm-checkpoint does not deny`, !h.deny && h.pre.code === 0, h.pre.out + h.pre.err);
  F.check(`${STAGE} allowed echo — workflow-mark PostToolUse ran`, h.post && h.post.code === 0, h.post && (h.post.out + h.post.err));
  const ev = approvalEvents(s.sid);
  F.check(`${STAGE} allowed echo — one confirm-sentinel approval bound to the plan hash`,
    ev.length === 1 && ev[0].source === "confirm-sentinel" && ev[0].artifact_sha256 === F.implSha(s.sid, STEP), JSON.stringify(ev));
  F.check(`${STAGE} allowed echo — check-plan-approval says approved`, cliVerdict(s.sid) === "APPROVAL=approved", cliVerdict(s.sid));
  const g = skillGate(s.sid);
  F.check(`${STAGE} allowed echo — Skill gate lets ${NEXT_SKILL} through`, g.code === 0 && !gateDenies(g), g.out + g.err);
  const a = advance(s.sid);
  F.check(`${STAGE} allowed echo — next-step --advance completes ${STEP}`, a.code === 0 && F.readStep(s.sid, STEP) === "complete",
    `exit=${a.code} status=${F.readStep(s.sid, STEP)} ${a.err}`);
}

// No cap: repeated echoes without a receipt keep denying (the 3rd is not let through).
{
  const s = newSession("no-cap");
  const r = [hostEcho(s, true), hostEcho(s, true), hostEcho(s, true)].map((h) => h.deny);
  F.check(`${STAGE} no cap — the 3rd echo without a receipt is still denied`, r.every(Boolean), JSON.stringify(r));
  F.check(`${STAGE} no cap — no plan_approval event`, approvalEvents(s.sid).length === 0, JSON.stringify(approvalEvents(s.sid)));
}

// Recovery: a denied echo, then a fresh presentation (receipt) in the same session records the approval.
{
  const s = newSession("recovered");
  const d = hostEcho(s, false);
  seed(s);
  const h = hostEcho(s, true);
  F.check(`${STAGE} recovery — deny first, then the echo with a receipt passes`, d.deny && !h.deny, JSON.stringify([d.deny, h.deny]));
  F.check(`${STAGE} recovery — exactly one approval, from the allowed echo`, approvalEvents(s.sid).length === 1, JSON.stringify(approvalEvents(s.sid)));
  F.check(`${STAGE} recovery — check-plan-approval says approved`, cliVerdict(s.sid) === "APPROVAL=approved", cliVerdict(s.sid));
  F.check(`${STAGE} recovery — the pass consumed the receipt`, !RS.receiptExists(s.sid, STAGE), RS.receiptPath(s.sid, STAGE));
  const again = hostEcho(s, true);
  F.check(`${STAGE} recovery — a re-echo after the consumed receipt is denied`, again.deny, again.pre.out);
}
