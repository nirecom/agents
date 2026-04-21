#!/usr/bin/env node
// PreToolUse hook: block direct writes to tests/ from the main conversation.
// Subagents (agent_id present) and non-pending write_tests states pass through.
// Fail-open: any error path approves rather than blocking.

const fs = require("fs");
const { resolveSessionId, readState } = require("./lib/workflow-state");

const DENY_MESSAGE =
  "write_tests step is still pending. Run /write-tests first — it spawns a subagent that writes tests/ autonomously. " +
  "If tests are genuinely not needed, mark the step skipped with: " +
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>>"';

module.exports = { DENY_MESSAGE };

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block() {
  console.log(JSON.stringify({ decision: "block", reason: DENY_MESSAGE }));
  process.exit(0);
}

// Returns true if file_path has a directory component matching one of the
// monitored names (any-component: not the final filename, anywhere in the path).
function isUnderTestsDir(filePath) {
  if (!filePath) return false;
  const names = (process.env.CLAUDE_BLOCK_TESTS_DIR_NAMES || "tests")
    .split(",")
    .map((n) => n.trim())
    .filter(Boolean);
  const parts = filePath.replace(/\\/g, "/").split("/").filter(Boolean);
  // Need at least one directory component + one filename component.
  if (parts.length < 2) return false;
  for (let i = 0; i < parts.length - 1; i++) {
    if (names.includes(parts[i])) return true;
  }
  return false;
}

// --- Main logic ---

if (require.main === module) {
  let input = {};
  try {
    input = JSON.parse(readStdin());
  } catch (e) {
    approve(); // B14: malformed stdin
  }

  // Step 1: only intercept Write / Edit / MultiEdit
  const WATCHED = new Set(["Write", "Edit", "MultiEdit"]);
  if (!WATCHED.has(input.tool_name)) approve();

  // Step 2: only intercept paths under a monitored tests directory
  const filePath = (input.tool_input || {}).file_path || "";
  if (!isUnderTestsDir(filePath)) approve();

  // Step 3: resolve session — fail-open if unavailable
  let sessionId;
  try {
    sessionId = resolveSessionId();
  } catch (e) {
    approve();
  }
  if (!sessionId) approve(); // B10: no CLAUDE_ENV_FILE

  // Step 4: read workflow state — fail-open on any error
  let state;
  try {
    state = readState(sessionId);
  } catch (e) {
    approve();
  }
  if (!state) approve(); // B11: missing state file

  // Step 5: check write_tests status — fail-open if key absent
  const status = state?.steps?.write_tests?.status;
  if (!status) approve(); // B13: key missing
  if (status !== "pending") approve(); // A3/A4/A5: in_progress / complete / skipped

  // Step 6: allow subagents (agent_id populated only in subagent context)
  if (input.agent_id) approve(); // A9: non-empty agent_id

  // Step 7: block
  block();
}
