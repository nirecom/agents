#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce workflow step completion before git commit
// Replaces check-tests-updated.js and check-docs-updated.js

const fs = require("fs");
const { resolveRepoDir } = require("./lib/is-private-repo");
const {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  readState,
} = require("./lib/workflow-state");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  block("workflow-gate: failed to parse hook input — commit blocked (fail-safe).");
}

const toolName = input.tool_name;
const toolInput = input.tool_input || {};
const sessionId = input.session_id;

if (toolName !== "Bash") approve();

const command = toolInput.command || "";
if (!command) approve();

const commitMatch = command.match(/git\s+(?:-C\s+\S+\s+)?commit\s/);
if (!commitMatch) approve();

const repoDir = resolveRepoDir(command);

// session_id is required — fail-safe if missing
if (!sessionId) {
  block(
    "workflow-gate: session_id not found in hook input.\n" +
      "Cannot verify workflow state. Commit blocked (fail-safe).\n" +
      "To reset workflow state, run:\n" +
      '  node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" --reset-from research'
  );
}

const state = readState(repoDir, sessionId);

if (!state) {
  block(
    `workflow-gate: no workflow state found for session ${sessionId}.\n` +
      "Commit blocked (fail-safe). To initialize workflow state, run:\n" +
      '  node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" --reset-from research'
  );
}

// Check all steps
const incomplete = [];
for (const step of VALID_STEPS) {
  const stepState = state.steps && state.steps[step];
  const status = stepState ? stepState.status : "pending";

  if (status === "complete") continue;
  if (status === "skipped" && SKIPPABLE_STEPS.includes(step)) continue;
  incomplete.push(step);
}

if (incomplete.length === 0) approve();

const SKILL_MAP = {
  research: "/survey-code or /deep-research",
  plan: "/make-plan",
  write_tests: "/write-tests",
  docs: "/update-docs",
};

const lines = [
  `workflow-gate: the following workflow steps are not complete: ${incomplete.join(", ")}`,
  "",
  "To mark a step complete:",
];

for (const step of incomplete) {
  if (SKILL_MAP[step]) {
    lines.push(`  ${step}: run ${SKILL_MAP[step]}`);
  } else {
    lines.push(
      `  ${step}: node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" ${step} complete`
    );
  }
}

lines.push(
  "",
  "To reset workflow state from a specific step:",
  '  echo "<<WORKFLOW_RESET_FROM_<step>>"'
);

block(lines.join("\n"));
