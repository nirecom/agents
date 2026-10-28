"use strict";
// Fixtures for tests/hooks/feature-2709-approval-bypass-closure.js: the supervisor state and
// real PostToolUse hook driver (3a), and the workflow state + RESET_FROM drivers (3b), both the
// in-process handler and the real hooks/workflow-mark.js subprocess.
// The entry calls isolate() before requiring this module, so the spawned hook inherits the
// pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR and has no CLAUDE_CODE_SESSION_ID.

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));

const FK = "fk-2709";
// #2597: renamed from WORKFLOW_SUPERVISOR_BLOCK_ACCEPTED (BLOCK and WARN share one acceptance).
const SENT = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";

function make({ TMP, CFG, eq, ok, show }) {
  const S = mod("hooks/workflow-state/state-io");
  const PAF = mod("tests/lib/plan-approval-fixture.js");
  const writer = mod("hooks/lib/supervisor-state-writer");
  const schema = mod("hooks/lib/supervisor-state-schema.js");
  let n = 0;
  const nextSid = (tag) => `f2709-${tag}-${++n}`;

  // ── 3a: supervisor state ──
  function terminalRun(id, verdict, tr) {
    return { id, outcome: "terminal", cause: "step-complete:user_verification", tr_ids: [tr || "TR5"], verdict,
      freshness_key: FK, sub_checks: ["recurrence-patterns"], input_key: { "recurrence-patterns": FK } };
  }
  function seedSup(sid, runs) {
    const st = schema.createEmptyState(sid);
    const last = runs[runs.length - 1];
    Object.assign(st.audit, { ledger: runs, last_terminal_run_id: last.id, audit_verdict_summary: last.verdict });
    const p = writer.getStatePath(sid, { forWrite: true });
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify(st));
  }
  const supState = (sid) => { try { return writer.readState(sid); } catch (_) { return null; } };
  const overrides = (sid) => { const s = supState(sid); return (s && s.audit && s.audit.block_overrides) || []; };

  // markHook(sid, command) -> additionalContext text (plus stderr) of one real workflow-mark.js run.
  function markHook(sid, command) {
    const input = { tool_name: "Bash", session_id: sid, tool_input: { command, cwd: TMP }, tool_response: { exit_code: 0 } };
    const env = Object.assign({}, process.env, { USER: "tester-2709", USERNAME: "tester-2709", LOGNAME: "tester-2709" });
    delete env.CLAUDE_CODE_SESSION_ID;
    const r = spawnSync(process.execPath, [path.join(ROOT, "hooks", "workflow-mark.js")],
      { input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env, cwd: TMP });
    if (r.error) throw new Error(`hook did not run: ${r.error.message}`);
    let out = {};
    try { out = JSON.parse(String(r.stdout || "").trim().split("\n").pop() || "{}"); } catch (_) { out = {}; }
    return String(out.additionalContext || "") + String(r.stderr || "");
  }

  // ── 3b: workflow state + RESET_FROM ──
  function setConfig(intent, outline, detail) {
    fs.writeFileSync(path.join(CFG, ".env"), `CONFIRM_INTENT=${intent}\nCONFIRM_OUTLINE=${outline}\nCONFIRM_DETAIL=${detail}\n`);
  }
  const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json");
  const rawState = (sid) => fs.readFileSync(statePath(sid), "utf8");
  const events = (sid, kind) => JSON.parse(rawState(sid)).events.filter((e) => !kind || e.kind === kind);
  function seedWf(tag, approved) {
    const sid = nextSid(tag);
    S.markStep(sid, "workflow_init", "complete");
    for (const s of approved) PAF.approveLive(sid, s);
    return sid;
  }
  const resetCmd = (step) => `echo "<<WORKFLOW_RESET_FROM_${step}: rework the plan from here>>"`;
  // reset(sid, step) drives the handler in process; resetHook(sid, step) drives the real hook.
  function reset(sid, step) {
    const msgs = [];
    mod("hooks/workflow-mark/reset-handler.js").handle({
      cmd: resetCmd(step),
      sessionId: sid, pushMessage: (m) => msgs.push(String(m)), signalFatal: (m) => msgs.push(String(m)), repoCwd: TMP,
    });
    return msgs.join("\n");
  }
  const resetHook = (sid, step) => markHook(sid, resetCmd(step));
  const resetSentinelApprovals = (sid) => events(sid, "plan_approval").filter((e) => e.source === "reset-sentinel" || e.origin === "reset-sentinel").length;
  function assertRefused(sid, step, gated, code, msg, before, beforeCount) {
    eq(events(sid).length, beforeCount, "event count unchanged");
    ok(rawState(sid) === before, "state bytes changed by a refused reset");
    ok(new RegExp(`RESET_FROM_${step} refused`, "i").test(msg), `refusal shape for ${step}; got ${show(msg)}`);
    ok(msg.includes(gated) && msg.includes(code), `refusal names ${gated} and ${code}; got ${show(msg)}`);
  }

  return { S, PAF, writer, nextSid, terminalRun, seedSup, supState, overrides, markHook,
    setConfig, statePath, rawState, events, seedWf, reset, resetHook, resetSentinelApprovals, assertRefused };
}

module.exports = { make, mod, ROOT, FK, SENT };
