"use strict";
// Shared #2337 / #1192 fixture for hooks/stop-final-report-guard.js: control files, transcripts,
// a lane-B workflow state, and one spawn of the guard. Not a test on its own.
// The caller runs harness isolate() first, so WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR are pinned.

const fs = require("node:fs");
const path = require("node:path");
const F = require("./worktree-leftover-fixture");

const GUARD = F.rel("hooks/stop-final-report-guard.js");
const RENDERER = F.rel("bin/render-final-report.js");
const EXITS = "hooks/stop-final-report-guard/exits.js";

const DEFAULT_ENV = {
  CC_RESTART_REQUIRED: "not_required", CC_RESTART_REASON: "",
  VSCODE_RELOAD_REQUIRED: "not_required", VSCODE_RELOAD_REASON: "",
  INSTALLER_RERUN_REQUIRED: "not_required", INSTALLER_RERUN_REASON: "",
  OS_REBOOT_REQUIRED: "not_required", OS_REBOOT_REASON: "",
};

const stateDir = () => process.env.WORKFLOW_STATE_DIR;

function controlDir(sid) {
  const dir = path.join(stateDir(), `${sid}.control`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function writeControl(sid, name, value) {
  fs.writeFileSync(path.join(controlDir(sid), name), JSON.stringify(value));
}

const writeEnv = (sid) => writeControl(sid, "final-report-env.json", DEFAULT_ENV);
const writeYield = (sid) => writeControl(sid, "session-close-gate.json", { gate_action: "yield" });
const writeWorkflowOff = (sid) => fs.writeFileSync(path.join(stateDir(), `${sid}.workflow-off`), "off");

// A transcript whose turn ends with one assistant text entry.
function writeTranscript(dir, sid, text) {
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, `${sid}.jsonl`);
  fs.writeFileSync(p, [
    JSON.stringify({ type: "user", message: { content: "hello" } }),
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text }] } }),
  ].join("\n") + "\n");
  return p;
}

// The canonical headings, each followed by a filler line; `drop` omits headings by index.
function reportText(sid, { drop = [], extra = "" } = {}) {
  const headings = require(F.rel("hooks/lib/final-report-schema")).getSectionHeadings(sid);
  return headings.filter((_, i) => !drop.includes(i)).map((h) => `${h}\n- (none)`).join("\n") + extra;
}

// What b_mk_state (tests/hooks/feature-534-stop-final-report-guard/g28-trigger.sh) writes: every
// step complete except `pre_final_report_gate`, with plan approvals for the gated steps.
function writeLaneBState(sid) {
  const steps = {};
  const now = new Date().toISOString();
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail",
    "branching_complete", "write_tests", "review_tests", "write_code", "run_tests",
    "review_security", "docs", "user_verification", "cleanup"]) steps[s] = { status: "complete", updated_at: now };
  steps.pre_final_report_gate = { status: "pending", updated_at: null };
  const file = path.join(stateDir(), `${sid}.json`);
  fs.writeFileSync(file, JSON.stringify({ version: 1, session_id: sid, created_at: now, steps, workflow_type: "wf-code" }));
  const r = F.runNode([F.rel("tests/lib/plan-approval-fixture.js"), "inject-complete", file, "clarify_intent", "outline", "detail"]);
  if (r.rc !== 0) throw new Error(`plan-approval-fixture failed: ${r.err}`);
}

// Spawn the guard; returns { rc, out, err, decision, reason }.
function runGuard(sid, transcript, cwd) {
  const env = Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: stateDir() });
  delete env.CONV_LANG;
  const r = F.runNode([GUARD], {
    cwd, env, timeout: 110000, input: JSON.stringify({ session_id: sid, transcript_path: transcript }),
  });
  let parsed = {};
  try { parsed = JSON.parse(r.out.trim()); } catch (_) { /* not a block */ }
  return Object.assign(r, { decision: parsed.decision, reason: parsed.reason || "" });
}

function runRenderer(sid, cwd) {
  return F.runNode([RENDERER, "--session", sid], { cwd, timeout: 60000 });
}

const exitHatchText = () => F.need(EXITS, "EXIT_HATCH_TEXT");

module.exports = {
  DEFAULT_ENV, controlDir, writeControl, writeEnv, writeYield, writeWorkflowOff, writeTranscript,
  reportText, writeLaneBState, runGuard, runRenderer, exitHatchText,
};
