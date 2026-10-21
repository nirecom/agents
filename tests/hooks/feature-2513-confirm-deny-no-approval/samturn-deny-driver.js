"use strict";
// #2650/#2729 same-turn variant of ./pipeline-driver.js. The presentation turn left a presentation
// receipt (seeded here in the Stop hook's place), confirm-checkpoint passes the echo to the ask
// dialog, and the user clicks Deny — so the host never runs PostToolUse. Then it checks that
// nothing recorded the approval and the pass consumed the receipt. argv: <stage>.
// Prints PASS|name / FAIL|name|detail lines.
const X = require("../feature-2650-confirm-continuation/fixture");
const RS = require("../../lib/presentation-receipt-seed");

const { U, A, T, W, TR, STOPFB, ECHO, show, check } = X;
const STAGE = process.argv[2];
const STEP = X.STEP[STAGE];
const NEXT_SKILL = { intent: "make-outline-plan", outline: "make-detail-plan", detail: "write-tests" }[STAGE];
const ARMED = X.gateEnv();
const FB = "[confirm-plan] continue: as your next message, emit only the CONFIRM echo";
if (!STEP) { check("driver arguments", false, `stage=${STAGE}`); process.exit(0); }

// Plan write -> anchor text with the link -> isMeta Stop feedback -> the CONFIRM echo.
const sameTurn = (s) => [U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"),
  A("a-anchor", T("Here is the plan.\n\n" + s.line)), STOPFB(FB, "u-fb"), A("a-echo", ECHO(STAGE, "e1"))];

// preToolUse(s, tp) -> {deny, ask, rc, json}: confirm-checkpoint only; on Deny no PostToolUse follows.
function preToolUse(s, tp) {
  const r = X.F.runNode("hooks/confirm-checkpoint.js", [], JSON.stringify({ session_id: s.sid, transcript_path: tp,
    hook_event_name: "PreToolUse", cwd: X.TDIR, tool_name: "Bash", tool_use_id: "e1",
    tool_input: { command: X.echoOf(STAGE) } }), ARMED);
  let json = {};
  try { json = r.out ? JSON.parse(r.out) : {}; } catch (_) { json = { unparsed: r.out }; }
  const hso = json.hookSpecificOutput || {};
  const deny = hso.permissionDecision === "deny";
  const ask = !deny && r.code === 0 && json.decision !== "block" && String(json.systemMessage || "").includes("Click Allow");
  return { deny, ask, rc: r.code, json };
}

const approvalEvents = (sid) => (X.F.rawEvents(sid) || []).filter((e) => e && e.kind === "plan_approval" && e.step === STEP);
const cliVerdict = (sid) => X.F.runNode("bin/workflow/check-plan-approval", ["--session", sid, "--step", STEP], "", ARMED).out.trim();
const skillGate = (sid) => X.F.runNode("hooks/gate-plan-skill-advance.js", [], JSON.stringify({
  hook_event_name: "PreToolUse", tool_name: "Skill", tool_input: { skill: NEXT_SKILL }, session_id: sid }), ARMED);
const advance = (sid) => X.F.runNode("bin/workflow/next-step", ["--session", sid, "--advance", "--step", STEP, "--complete"], "", ARMED);
const gateDenies = (r) => /"permissionDecision"\s*:\s*"deny"/.test(r.out);

{
  const s = X.sessionAt(STAGE);
  const w = RS.seedReceipt(s.sid, STAGE);
  check(`${STAGE} same-turn deny — the presentation receipt is seeded`, !!w && RS.receiptExists(s.sid, STAGE), show({ w }));
  const tp = X.writeTranscript(s.sid, sameTurn(s));
  const h = preToolUse(s, tp);
  check(`${STAGE} same-turn deny — confirm-checkpoint passes the echo to the ask dialog`, h.ask, show(h.json));
  // The user clicks Deny: the host skips the tool and PostToolUse hooks/workflow-mark.js.
  check(`${STAGE} same-turn deny — the receipt is consumed`, !RS.receiptExists(s.sid, STAGE), "receipt left");
  check(`${STAGE} same-turn deny — no plan_approval event for ${STEP}`, approvalEvents(s.sid).length === 0, show(approvalEvents(s.sid)));
  check(`${STAGE} same-turn deny — check-plan-approval says unapproved`, cliVerdict(s.sid) === "APPROVAL=unapproved", cliVerdict(s.sid));
  const g = skillGate(s.sid);
  check(`${STAGE} same-turn deny — Skill gate denies ${NEXT_SKILL}`, g.code === 0 && gateDenies(g), g.out + g.err);
  const a = advance(s.sid);
  check(`${STAGE} same-turn deny — next-step --advance refuses (non-zero)`, a.code !== 0, `exit=${a.code}`);
  check(`${STAGE} same-turn deny — ${STEP} stays not complete`, X.F.readStep(s.sid, STEP) !== "complete", X.F.readStep(s.sid, STEP));
  // A re-echo in the same turn after the Deny finds no receipt, so the judge denies it.
  const again = preToolUse(s, tp);
  check(`${STAGE} same-turn deny — re-echo in the same turn is denied`, again.deny, show(again.json));
  check(`${STAGE} same-turn deny — still no plan_approval event after the re-echo`, approvalEvents(s.sid).length === 0, show(approvalEvents(s.sid)));
}
