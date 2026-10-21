"use strict";
// Regression driver for hooks/supervisor-guard/detect.js (DETECT_LIB) under #2610: every
// detector keeps its verdict on a transcript with a malformed JSONL line, and stays quiet on a
// missing or empty one. Prints PASS|name / FAIL|name|detail lines; transcripts go to TR_TDIR.

const fs = require("fs");
const path = require("path");

const out = [];
const ok = (n, c, d) => out.push(c ? "PASS|" + n : "FAIL|" + n + "|" + d);
const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };
let seq = 0;
const write = (lines) => {
  const p = path.join(process.env.TR_TDIR, "detect-" + (++seq) + ".jsonl");
  fs.writeFileSync(p, lines.map((e) => (typeof e === "string" ? e : JSON.stringify(e))).join("\n") + "\n");
  return p;
};
const U = (text) => ({ type: "user", message: { role: "user", content: text } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const B = (command) => ({ type: "tool_use", id: "t1", name: "Bash", input: { command } });
const ASK = { type: "tool_use", id: "t9", name: "AskUserQuestion", input: { questions: [] } };
const BAD = "{broken json";

let d;
try { d = require(process.env.DETECT_LIB); } catch (e) {
  process.stdout.write("FAIL|require hooks/supervisor-guard/detect.js|" + e.message + "\n");
  process.exit(0);
}
const call = (f, p) => { try { return d[f](p); } catch (e) { return { threw: e.message }; } };
// #2698: the AskUserQuestion turn judgment moved out of detect.js into the shared predicate
// hooks/lib/user-dialog-turn.js (kind "ask-user-question-tool"), which takes the Stop input.
const UDT_LIB = path.join(path.dirname(process.env.DETECT_LIB), "..", "lib", "user-dialog-turn.js");
const askTurn = (p) => {
  try { return require(UDT_LIB).isUserDialogTurn({ transcript_path: p, last_assistant_message: "" }); }
  catch (e) { return { threw: e.message }; }
};

try {
  const hang = write([U("go"), BAD, A(T("Marking."), B('echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"')), BAD]);
  ok("detectSentinelHang — MARK_STEP last, malformed lines around it -> true", call("detectSentinelHang", hang) === true, show(call("detectSentinelHang", hang)));
  const noHang = write([U("go"), A(B('echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"'), B("ls"))]);
  ok("detectSentinelHang — a later tool_use follows -> false", call("detectSentinelHang", noHang) === false, show(call("detectSentinelHang", noHang)));
  const exempt = write([U("go"), A(B('echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"'))]);
  ok("detectSentinelHang — final_report is exempt -> false", call("detectSentinelHang", exempt) === false, show(call("detectSentinelHang", exempt)));

  const ask = write([U("go"), BAD, A(T("Question."), ASK)]);
  ok("isUserDialogTurn — AskUserQuestion last, malformed line -> true", askTurn(ask) === true, show(askTurn(ask)));
  const noAsk = write([U("go"), A(ASK, B("ls"))]);
  ok("isUserDialogTurn — another tool_use last -> false", askTurn(noAsk) === false, show(askTurn(noAsk)));

  const audit = write([U("go"), A(T("one")), BAD, A(T("two"))]);
  const parsed = call("parseTranscriptForAudit", audit);
  ok("parseTranscriptForAudit — two assistant entries, malformed line skipped", Array.isArray(parsed) && parsed.length === 2 && parsed.every((e) => e.role === "assistant"), show(parsed));

  const off = write([U("go"), A(B('echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>"')), BAD]);
  const offR = call("detectOffProposal", off);
  ok("detectOffProposal — WORKTREE_OFF without ON -> detected worktree-off", offR && offR.detected === true && offR.kind === "worktree-off", show(offR));
  const offOn = write([U("go"), A(B('echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>"')), A(B('echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: test reason>>"'))]);
  const offOnR = call("detectOffProposal", offOn);
  ok("detectOffProposal — OFF then ON -> not detected", offOnR && offOnR.detected === false, show(offOnR));

  const missing = path.join(process.env.TR_TDIR, "detect-missing.jsonl");
  const empty = write([]);
  for (const p of [missing, empty]) {
    const tag = p === missing ? "missing" : "empty";
    ok("detectSentinelHang — " + tag + " transcript -> false", call("detectSentinelHang", p) === false, show(call("detectSentinelHang", p)));
    ok("isUserDialogTurn — " + tag + " transcript -> false", askTurn(p) === false, show(askTurn(p)));
    const a = call("parseTranscriptForAudit", p);
    ok("parseTranscriptForAudit — " + tag + " transcript -> []", Array.isArray(a) && a.length === 0, show(a));
    const o = call("detectOffProposal", p);
    ok("detectOffProposal — " + tag + " transcript -> not detected", o && o.detected === false, show(o));
  }
} catch (e) {
  ok("driver does not throw", false, e && e.stack);
}
process.stdout.write(out.join("\n") + "\n");
process.exit(0);
