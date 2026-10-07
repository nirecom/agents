"use strict";
// Prints the recorded status of one workflow step from the fixture state
// store (WORKFLOW_STATE_DIR), or "none" when nothing was recorded.
// Usage: node step-status.js <agentsDir> <sessionId> <step>
const path = require("path");

const [agentsDir, sid, step] = process.argv.slice(2);
try {
  const wf = require(path.join(agentsDir, "hooks", "workflow-state"));
  const state = wf.readState(sid);
  const steps = state && (state.steps || (state.current && state.current.steps));
  const entry = steps && steps[step];
  process.stdout.write((entry && entry.status) || "none");
} catch (e) {
  process.stdout.write("probe-error:" + e.message);
}
