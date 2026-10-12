"use strict";
// Scene builder for the sibling-reader cases of ../feature-2610-transcript-reader.sh.
// argv: <kind> <case-dir> <sid> [plan-path]. Writes <case-dir>/t.jsonl (what is flushed when
// the hook starts), <case-dir>/stdin.json (the Stop input) and, for a late-flush scene,
// <case-dir>/late.jsonl — the final line the test appends while the hook is already running.

const fs = require("fs");
const path = require("path");

const [kind, dir, sid, planPath] = process.argv.slice(2);
const U = (text) => ({ type: "user", message: { role: "user", content: text } });
const R = () => ({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const B = (command) => ({ type: "tool_use", id: "t1", name: "Bash", input: { command } });
const C = (stage) => B('echo "<<WORKFLOW_CONFIRM_' + stage.toUpperCase() + ': ok>>"');

function report() {
  const schema = require(process.env.TR_SCHEMA_LIB);
  const h2 = "## Final Report — " + sid;
  const rest = schema.getSectionHeadings(sid).filter((h) => h !== h2);
  return [h2, ""].concat(rest.map((h) => h + "\n\nNone.\n")).join("\n");
}

const fwd = (p) => String(p || "").replace(/\\/g, "/");
let base;
let late = null;
let lam;
switch (kind) {
  case "l2-block": base = [U("ok"), A(T("Confirmed."), C("outline"))]; lam = "Confirmed."; break;
  case "l2-late": base = [U("ok"), A(T("Working on it."))]; late = A(T("Confirmed."), C("outline")); lam = "Confirmed."; break;
  case "pl-present": base = [U("go"), A(B("echo write")), R(), A(T("Plan: " + fwd(planPath)))]; lam = "Plan: " + fwd(planPath); break;
  case "pl-missing": base = [U("go"), A(B("echo write")), R(), A(T("The intent plan is written."))]; lam = "The intent plan is written."; break;
  case "pl-late": base = [U("go"), A(B("echo write")), R()]; late = A(T("Plan: " + fwd(planPath))); lam = "Plan: " + fwd(planPath); break;
  case "pl-undecidable": base = [U("go"), A(B("echo write")), R(), A(T("Older text."))]; lam = "A final text that is never flushed."; break;
  case "fr-present": base = [U("close"), A(T(report()))]; lam = report(); break;
  case "fr-absent": base = [U("close"), A(T("All done."))]; lam = "All done."; break;
  default: process.stderr.write("unknown kind " + kind + "\n"); process.exit(1);
}
fs.mkdirSync(dir, { recursive: true });
const tpath = path.join(dir, "t.jsonl");
fs.writeFileSync(tpath, base.map((e) => JSON.stringify(e)).join("\n") + "\n");
if (late) fs.writeFileSync(path.join(dir, "late.jsonl"), JSON.stringify(late) + "\n");
fs.writeFileSync(path.join(dir, "stdin.json"),
  JSON.stringify({ session_id: sid, transcript_path: tpath, hook_event_name: "Stop", last_assistant_message: lam }));
