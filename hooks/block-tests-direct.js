#!/usr/bin/env node
// PreToolUse hook: block direct writes to tests/ from the main conversation.
// Subagents (agent_id present) and settled write_tests states pass through.
// Unreadable stdin blocks; other error paths approve.

const fs = require("fs");
const { resolveSessionId, readState } = require("./workflow-state");
const { getPathSegments } = require("./lib/path-match");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "block-tests-direct";

const DENY_MESSAGE =
  "write_tests step is still pending. Run /write-tests first — it spawns a subagent that writes tests/ autonomously. " +
  "If tests are genuinely not needed, mark the step skipped with: " +
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"';

module.exports = { DENY_MESSAGE };

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason = DENY_MESSAGE) {
  console.log(JSON.stringify({ decision: "block", reason }));
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
  const parts = getPathSegments(filePath);
  // Need at least one directory component + one filename component.
  if (parts.length < 2) return false;
  for (let i = 0; i < parts.length - 1; i++) {
    if (names.includes(parts[i])) return true;
  }
  return false;
}

// --- Main logic ---

if (require.main === module) {
  const r = readHookInput();
  if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
  if (r.kind === "json-invalid") {
    try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
    approve(); // B14: malformed stdin
  }
  const input = r.input;

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
  if (!sessionId) approve(); // B10: session id unresolvable

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
  // Only a SETTLED step opens the direct-write path. Since #2013 the PostToolUse
  // auto-mark records write_tests in_progress on the very first dispatch, so
  // treating in_progress as settled would unblock tests/ for the whole step.
  if (status !== "pending" && status !== "in_progress") approve(); // A4/A5

  // Step 6: allow subagents (agent_id populated only in subagent context)
  if (input.agent_id) approve(); // A9: non-empty agent_id

  // Step 7: block
  block();
}
