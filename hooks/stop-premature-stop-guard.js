#!/usr/bin/env node
"use strict";
// Stop hook: C4 premature-stop guard — detects ACTION=invoke being ignored and auto-resumes Claude.
// Fires when Claude stops despite next-step returning ACTION=invoke (workflow step pending).
// Records a warning/workflow finding and outputs decision:block to trigger auto-resume.

const fs = require("fs");
const { spawnSync } = require("child_process");
const path = require("path");

// Steps whose ACTION=invoke is handled by a dedicated Stop hook. Emitting a
// second generic block in the same turn would surface two competing messages,
// so this guard stays silent for them (CPR-3 — one owner per condition).
// - pre_final_report_gate → owned by hooks/stop-final-report-guard.js lane B.
const DELEGATED_REASONS = new Set(["pre_final_report_gate"]);

// Exemption table. Add a row to extend the conditions.
// phase="session"          : decidable from session state alone, before next-step runs
// phase="next-step-output" : decidable only after seeing next-step's output (REASON)
// Each test is a pure function of (ctx, deps) — it must not close over module-scope
// `let` bindings from the require.main block, or it throws ReferenceError (see #1794).
const C4_EXEMPTIONS = [
  { id: "workflow-off",      phase: "session", test: (c, d) => d.isWorkflowOff(c.sid) },
  { id: "next-step-paused",  phase: "session", test: (c, d) => d.isNextStepPaused(c.sid) },
  { id: "pre-workflow-init", phase: "session", test: (c, d) => !d.isWorkflowStarted(c.sid) },
  { id: "background-work",   phase: "session", test: (c, d) => d.isBackgroundWorkInFlight(c.sid) },
  // Only exemption row with a side effect: consumes the marker the moment it
  // decides the exemption applies (single-turn declaration, #1685).
  { id: "awaiting-user",     phase: "session",
    test: (c, d) => { if (!d.isAwaitingUser(c.sid)) return false; d.consumeAwaitingUser(c.sid); return true; } },
  { id: "delegated-reason",  phase: "next-step-output",
    test: (c, _d) => DELEGATED_REASONS.has(c.reason) },
];

// Assembles the predicates the table needs. Both the hook body and tests use
// only this function, so the wiring never diverges between the two.
// A require failure throws here and is caught by the caller (the
// require.main block's try/catch) — same handling as any other dependency
// load failure.
function buildExemptionDeps() {
  const { isWorkflowOff, isNextStepPaused, isBackgroundWorkInFlight, isAwaitingUser, consumeAwaitingUser } =
    require("./lib/session-markers");
  const { isWorkflowStarted } = require("./workflow-state");
  return {
    isWorkflowOff, isNextStepPaused, isWorkflowStarted, isBackgroundWorkInFlight,
    isAwaitingUser, consumeAwaitingUser,
  };
}

// An exemption holds only when it can be actively proven. A predicate that
// throws is treated as NOT holding, and its id is pushed onto `degraded` so
// evaluation continues to the next row. Treating a throw as exempt would let
// a single buggy predicate silence C4 across every session.
function firstExemption(phase, ctx, deps, degraded) {
  for (const e of C4_EXEMPTIONS) {
    if (e.phase !== phase) continue;
    let hit = false;
    try {
      hit = e.test(ctx, deps);
    } catch (_err) {
      if (degraded) degraded.push(e.id);
      continue;
    }
    if (hit) return e.id;
  }
  return null;
}

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

  let resolveSessionId;
  let appendFinding;
  let deps;
  try {
    ({ resolveSessionId } = require("./workflow-state"));
    ({ appendFinding } = require("./lib/supervisor-state-writer"));
    deps = buildExemptionDeps();
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
    if (!sessionId) process.exit(0);

    const degraded = [];
    if (firstExemption("session", { sid: sessionId }, deps, degraded)) process.exit(0);

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

    // Delegate reasons owned by a dedicated Stop hook (REASON is single-quoted).
    const reasonLine = lines.find((l) => l.startsWith("REASON="));
    const reasonValue = reasonLine ? reasonLine.slice("REASON=".length).replace(/^'|'$/g, "") : "";
    if (firstExemption("next-step-output", { sid: sessionId, reason: reasonValue }, deps, degraded)) {
      process.exit(0);
    }

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
    const degradedNote = degraded.length
      ? ` [warning: exemption predicate(s) failed: ${degraded.join(",")}]`
      : "";
    const reason = `[C4 premature-stop] ACTION=invoke was pending (NEXT_SKILL=${nextSkill || "(unknown)"}). ${skillNote} (Hook: stop-premature-stop-guard.js)${degradedNote}`;
    if (degraded.length) {
      try {
        process.stderr.write(`stop-premature-stop-guard: exemption predicate(s) failed: ${degraded.join(",")}\n`);
      } catch (_) {}
    }
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (_) {
    // Fail-open: never block on own errors.
    process.exit(0);
  }
}

module.exports = { C4_EXEMPTIONS, buildExemptionDeps, firstExemption };
