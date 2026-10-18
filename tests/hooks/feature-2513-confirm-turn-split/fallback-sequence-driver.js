"use strict";
// #2650 mode "fallback <stage> <ends-on-link|ends-elsewhere>" of ../feature-2513-confirm-turn-split.sh:
// one transcript grown through a whole run. Presentation turn -> the first Stop blocks and leaves
// the continuation mark -> the continuation message ends WITHOUT the CONFIRM echo -> the second
// Stop (stop_hook_active) neither blocks nor touches the mark -> the user replies -> the echo is
// judged by the two-turn path, never the same-turn one. Prints PASS|name / FAIL|name|detail lines.
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
const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
const TR_READER = require(path.join(X.ROOT, "hooks/lib/transcript-reader"));
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
const mark = X.readMark(s.sid, STAGE);
check(`${L} — the first Stop leaves the mark anchored on the presentation text`, !!mark && mark.anchorUuid === "a-anchor", show(mark));

// 2. The continuation message ends the turn without the CONFIRM echo.
const contText = VARIANT === "ends-on-link" ? "Please review the plan.\n\n" + s.line : "Waiting for your review.";
grow(STOPFB(first.reason || "[confirm-plan] continue:", "u-fb"), A("a-cont", T(contText)));
const second = X.runStop(s.sid, tp, { input: { stop_hook_active: true } });
check(`${L} — the second Stop (stop_hook_active) does not block again`,
  second.rc === 0 && second.out.trim() === "", show({ rc: second.rc, out: second.out }));
check(`${L} — the second Stop leaves the mark for confirm-checkpoint to consume`,
  JSON.stringify(X.readMark(s.sid, STAGE)) === JSON.stringify(mark), show(X.readMark(s.sid, STAGE)));

// 3. Next turn: the user replies and the model emits the CONFIRM echo alone.
grow(U("looks good, go ahead", "u-reply"), A("a-echo", ECHO(STAGE, "e1")));
const turns = TR_READER.readPreviousTurn({ transcriptPath: tp });
const sameTurn = !CC.__missing && !!mark && CC.sameTurnContinuation(turns.currentTurnEntries, mark, "e1");
check(`${L} — the mark's anchor is outside the echo's turn (same-turn path not open)`, !CC.__missing && !!mark && sameTurn === false,
  show({ missing: CC.__missing, sameTurn }));
const r = X.F.runNode("hooks/confirm-checkpoint.js", [], JSON.stringify({ session_id: s.sid, transcript_path: tp,
  hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "e1", tool_input: { command: X.echoOf(STAGE) } }), X.gateEnv());
let json = {};
try { json = r.out ? JSON.parse(r.out) : {}; } catch (_) { json = { unparsed: r.out }; }
const deny = (json.hookSpecificOutput || {}).permissionDecision === "deny";
const ask = !deny && r.code === 0 && json.decision !== "block" && String(json.systemMessage || "").includes("Click Allow");
if (VARIANT === "ends-on-link") {
  check(`${L} — the two-turn path accepts the echo (ask dialog)`, ask, show(json));
} else {
  check(`${L} — the two-turn path denies: the previous turn did not end on the link, the valid mark is not used`, deny, show(json));
}
check(`${L} — the mark is consumed by the echo`, X.readMark(s.sid, STAGE) === null && !fs.existsSync(X.markPath(s.sid, STAGE)), "mark left");
