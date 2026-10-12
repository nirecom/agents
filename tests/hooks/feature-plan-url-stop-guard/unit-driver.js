"use strict";
// Node driver shared by the unit and hook sections of ../feature-plan-url-stop-guard.sh:
// transcript-entry builders, the local path forms a reply may hold, and runUnit, which loads
// hooks/lib/plan-link-turn-check.js (TC_LIB) and prints one PASS|name / FAIL|name|detail line
// per assertion. Loaded by `node -e` through the UPG_DRIVER environment variable.

const path = require("path");

const U = (text) => ({ type: "user", message: { role: "user", content: text } });
const RT = (text) => ({
  type: "user",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: text }] },
});
const R = () => RT("ok");
// RTE — the tool_result of t1 marked is_error (a denied CONFIRM echo).
const RTE = (text) => ({
  type: "user",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", is_error: true, content: text }] },
});
// UMETA / UCOMPACT — user entries that are not real prompts (meta injection, compaction summary).
const UMETA = (text) => ({ type: "user", isMeta: true, message: { role: "user", content: text } });
const UCOMPACT = (text) => ({ type: "user", isCompactSummary: true, message: { role: "user", content: text } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const B = (command) => ({ type: "tool_use", id: "t1", name: "Bash", input: { command } });
const S = (skill) => ({ type: "tool_use", id: "t2", name: "Skill", input: { skill } });
const C = (stage) => B('echo "<<WORKFLOW_CONFIRM_' + stage.toUpperCase() + ': ok>>"');
// W — a file-writing tool_use (Write / Edit / MultiEdit) on file_path.
const W = (file_path, name) => ({ type: "tool_use", id: "t3", name: name || "Write", input: { file_path, content: "x" } });

const fwdOf = (p) => p.replace(/\\/g, "/");
const uriOf = (p) => {
  const f = fwdOf(p);
  const enc = (s) => s.split("/").map(encodeURIComponent).join("/");
  const m = f.match(/^([A-Za-z]:)\/(.*)/);
  return m ? "file:///" + m[1] + "/" + enc(m[2]) : "file:///" + enc(f.replace(/^\//, ""));
};

// runUnit(body) — body({ tc, ok, show, isBlock }); a missing lib is one not-implemented FAIL.
function runUnit(body) {
  const out = [];
  const ok = (n, c, d) => out.push(c ? "PASS|" + n : "FAIL|" + n + "|" + d);
  const show = (x) => JSON.stringify(x);
  const isBlock = (r) => !!r && (r.block === true || r.decision === "block");
  let tc;
  try {
    tc = require(process.env.TC_LIB);
  } catch (e) {
    process.stdout.write("FAIL|require hooks/lib/plan-link-turn-check.js|not implemented: " + (e.code || e.message) + "\n");
    return;
  }
  try {
    body({ tc, ok, show, isBlock });
  } catch (e) {
    ok("driver does not throw", false, e && e.stack);
  }
  process.stdout.write(out.join("\n") + "\n");
}

module.exports = { path, U, R, RT, RTE, UMETA, UCOMPACT, A, T, B, S, C, W, fwdOf, uriOf, runUnit };
