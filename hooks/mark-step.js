#!/usr/bin/env node
// CLI tool: mark a workflow step as complete/skipped, or reset from a step
// Usage: node mark-step.js <session-id> <step> <status>
//        node mark-step.js <session-id> --reset-from <step>

const {
  VALID_STEPS,
  VALID_STATUSES,
  resolveSessionId,
  markStep,
  createInitialState,
  writeState,
} = require("./lib/workflow-state");

const args = process.argv.slice(2);
const repoDir = process.env.HOOK_CWD || process.cwd();

if (args.length < 2) {
  process.stderr.write(
    "Usage: node mark-step.js <step> <status>\n" +
      "       node mark-step.js --reset-from <step>\n"
  );
  process.exit(1);
}

const sessionId = resolveSessionId();
if (!sessionId) {
  process.stderr.write(
    "Error: cannot resolve session ID from CLAUDE_ENV_FILE.\n" +
      "CLAUDE_ENV_FILE must be set and contain CLAUDE_SESSION_ID=<id>.\n"
  );
  process.exit(1);
}

// --reset-from mode
if (args[0] === "--reset-from") {
  const fromStep = args[1];
  if (!VALID_STEPS.includes(fromStep)) {
    process.stderr.write(
      `Error: unknown step "${fromStep}". Valid steps: ${VALID_STEPS.join(", ")}\n`
    );
    process.exit(1);
  }

  const newState = createInitialState(sessionId);
  const fromIndex = VALID_STEPS.indexOf(fromStep);
  const now = new Date().toISOString();

  for (let i = 0; i < fromIndex; i++) {
    newState.steps[VALID_STEPS[i]] = { status: "complete", updated_at: now };
  }

  try {
    writeState(repoDir, sessionId, newState);
    process.stderr.write(
      `Workflow reset: steps before "${fromStep}" marked complete, "${fromStep}" and after reset to pending.\n`
    );
    process.exit(0);
  } catch (e) {
    process.stderr.write(`Error: ${e.message}\n`);
    process.exit(1);
  }
}

// Normal mode: mark a step with a status
const stepName = args[0];
const status = args[1];

if (!VALID_STEPS.includes(stepName)) {
  process.stderr.write(
    `Error: unknown step "${stepName}". Valid steps: ${VALID_STEPS.join(", ")}\n`
  );
  process.exit(1);
}

if (!VALID_STATUSES.includes(status)) {
  process.stderr.write(
    `Error: unknown status "${status}". Valid statuses: ${VALID_STATUSES.join(", ")}\n`
  );
  process.exit(1);
}

if (stepName === "user_verification" && status === "skipped") {
  process.stderr.write('Error: "user_verification" cannot be skipped.\n');
  process.exit(1);
}

try {
  markStep(repoDir, sessionId, stepName, status);
  process.stderr.write(`Step "${stepName}" marked as "${status}".\n`);
  process.exit(0);
} catch (e) {
  process.stderr.write(`Error: ${e.message}\n`);
  process.exit(1);
}
