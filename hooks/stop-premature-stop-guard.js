#!/usr/bin/env node
"use strict";
// Stop hook: C4 premature-stop guard — detects ACTION=invoke being ignored and auto-resumes Claude.
// Fires when Claude stops despite next-step returning ACTION=invoke (workflow step pending).
// Records a warning/workflow finding and outputs decision:block to trigger auto-resume.

const fs = require("fs");
const { spawnSync } = require("child_process");
const path = require("path");

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  // Loop prevention: when this hook itself caused Claude to re-invoke, skip.
  if (input.stop_hook_active === true) process.exit(0);

  let resolveSessionId, readWorkflowState;
  let isWorkflowOff;
  let appendFinding;
  try {
    ({ resolveSessionId, readState: readWorkflowState } = require("./lib/workflow-state"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ appendFinding } = require("./lib/supervisor-state-writer"));
  } catch (_) {
    process.exit(0);
  }

  try {
    // Resolve CC session ID from input (used for next-step, workflow-state, and appendFinding).
    let sessionId = null;
    try {
      sessionId = resolveSessionId({
        sessionIdFromInput: input.session_id,
        transcriptPath: input.transcript_path,
      });
    } catch (_) {}
    if (!sessionId || !SESSION_ID_RE.test(sessionId)) process.exit(0);

    // Skip when workflow-off marker is present.
    try {
      if (isWorkflowOff(sessionId)) process.exit(0);
    } catch (_) {
      process.exit(0);
    }

    // Skip sessions with no workflow state file (non-workflow sessions).
    let wfState = null;
    try {
      wfState = readWorkflowState(sessionId);
    } catch (_) {}
    if (!wfState) process.exit(0);

    // Locate next-step binary.
    const agentsDir = process.env.AGENTS_CONFIG_DIR
      ? process.env.AGENTS_CONFIG_DIR
      : path.join(__dirname, "..");
    const nextStepPath = path.join(agentsDir, "bin", "workflow", "next-step");
    if (!fs.existsSync(nextStepPath)) process.exit(0);

    // Run next-step with CC session ID to check current ACTION.
    const result = spawnSync(process.execPath, [nextStepPath, "--session", sessionId], {
      timeout: 5000,
      encoding: "utf8",
    });
    if (result.status !== 0 || !result.stdout) process.exit(0);

    // Parse ACTION from output.
    const lines = result.stdout.split("\n");
    const actionLine = lines.find((l) => l.startsWith("ACTION="));
    if (!actionLine || actionLine !== "ACTION=invoke") process.exit(0);

    // Extract NEXT_SKILL for the continuation message.
    const skillLine = lines.find((l) => l.startsWith("NEXT_SKILL="));
    const nextSkill = skillLine ? skillLine.replace("NEXT_SKILL=", "").trim() : "";

    // Record warning/workflow finding (fail-open — do not suppress continuation on error).
    try {
      appendFinding(sessionId, {
        categories: ["workflow"],
        severity: "warning",
        detail: `premature-stop: ACTION=invoke ignored (skill: ${nextSkill || "(unknown)"})`,
        reporter: "stop-premature-stop-guard",
      });
    } catch (_) {}

    // Output decision:block to auto-resume Claude with the pending skill.
    const skillNote = nextSkill
      ? `Run /${nextSkill} now via the Skill tool to continue the workflow.`
      : "Re-run next-step to determine the pending workflow skill.";
    const reason = `[C4 premature-stop] ACTION=invoke was pending (NEXT_SKILL=${nextSkill || "(unknown)"}). ${skillNote} (Hook: stop-premature-stop-guard.js)`;
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (_) {
    // Fail-open: never block on own errors.
    process.exit(0);
  }
}

module.exports = {};
