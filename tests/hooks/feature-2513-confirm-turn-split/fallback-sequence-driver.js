"use strict";
// #2650 mode "fallback <stage> <ends-on-link|ends-elsewhere>" of ../feature-2513-confirm-turn-split.sh,
// rebased on the #2729 presentation receipt: one transcript grown through a whole run.
// Presentation turn -> the first Stop writes the receipt and blocks with the continue prompt ->
// the continuation message ends WITHOUT the CONFIRM echo -> the second Stop (stop_hook_active)
// does not block -> the user replies -> the echo's verdict follows the receipt alone, never the
// shape of the previous turn. Prints PASS|name / FAIL|name|detail lines.
const fs = require("fs");
const path = require("path");
const X = require("../feature-2650-confirm-continuation/fixture");

const { U, A, T, W, TR, STOPFB, ECHO, show, check } = X;
const STAGE = process.argv[2];
const VARIANT = process.argv[3];
if (!X.STEP[STAGE] || !["ends-on-link", "ends-elsewhere"].includes(VARIANT)) {
  check("fallback driver arguments", false, `stage=${STAGE} variant=${VARIANT}`);
  process.exit(0);
}
const L = `${STAGE} fallback (${VARIANT})`;

const s = X.sessionAt(STAGE);
const tp = path.join(X.TDIR, `fallback-${s.sid}.jsonl`);
const entries = [];
const grow = (...more) => {
  entries.push(...more);
  fs.writeFileSync(tp, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
};

// 1. Presentation turn: the plan is written and the anchor text closes on the plan-link line.
X.turnMarker(s.sid, STAGE, s.plan);
grow(U("write the plan", "u-prompt"), A("a-write", W(s.plan)), TR("w1", "u-tr"), A("a-anchor", T("Here is the plan.\n\n" + s.line)));
const first = X.runStop(s.sid, tp);
check(`${L} — the first Stop blocks with the continue prompt`,
  first.rc === 2 && first.json.decision === "block" && first.reason.startsWith("[confirm-plan] continue:"), show({ rc: first.rc, out: first.out }));
check(`${L} — the first Stop writes the presentation receipt`, X.receiptExists(s.sid, STAGE), "no receipt");

// 2. The continuation message ends the turn without the CONFIRM echo.
const contText = VARIANT === "ends-on-link" ? "Please review the plan.\n\n" + s.line : "Waiting for your review.";
grow(STOPFB(first.reason || "[confirm-plan] continue:", "u-fb"), A("a-cont", T(contText)));
const second = X.runStop(s.sid, tp, { input: { stop_hook_active: true } });
check(`${L} — the second Stop (stop_hook_active) does not block again`,
  second.rc === 0 && second.out.trim() === "", show({ rc: second.rc, out: second.out }));
const before = X.receiptExists(s.sid, STAGE);

// 3. Next turn: the user replies and the model emits the CONFIRM echo alone.
grow(U("looks good, go ahead", "u-reply"), A("a-echo", ECHO(STAGE, "e1")));
// #2853: settle the stage's pre-confirm audit on the plan as it is now; this driver tests the receipt.
require("../../lib/pre-confirm-audit-settle").trySettle(s.sid, STAGE, "CONTINUE");
const r = X.F.runNode("hooks/confirm-checkpoint.js", [], JSON.stringify({ session_id: s.sid, transcript_path: tp,
  hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "e1", tool_input: { command: X.echoOf(STAGE) } }), X.gateEnv());
let json = {};
try { json = r.out ? JSON.parse(r.out) : {}; } catch (_) { json = { unparsed: r.out }; }
const deny = (json.hookSpecificOutput || {}).permissionDecision === "deny";
// #2731: the dialog systemMessage is the stage fact line (`[<stage>] ...`), no "Click Allow" wording.
const ask = !deny && r.code === 0 && json.decision !== "block" && /^\[(intent|outline|detail)\] /.test(String(json.systemMessage || ""));
if (VARIANT === "ends-on-link") {
  check(`${L} — the receipt survives the second Stop`, before, "no receipt");
  check(`${L} — the echo reaches the ask dialog through the receipt`, before && ask, show(json));
}
check(`${L} — the verdict follows the receipt, not the previous turn's shape`, before ? ask : deny, show({ before, json }));
if (ask) check(`${L} — the pass consumed the receipt`, !X.receiptExists(s.sid, STAGE), "receipt left");
