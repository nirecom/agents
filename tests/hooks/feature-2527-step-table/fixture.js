"use strict";
// Fixture writer for the feature-2527-step-table suite (not a test): node fixture.js '<spec-json>'.
// Writes <WORKFLOW_STATE_DIR>/<sid>.json as an event-stream state file; spec keys are read below.

const fs = require("fs");
const path = require("path");

const spec = JSON.parse(process.argv[2] || "{}");
if (!spec.sid) {
  process.stderr.write("fixture.js: spec.sid is required\n");
  process.exit(2);
}

const ORIGIN = "fixture-2527";
const events = [];
let hour = 0;
const at = () => new Date(Date.UTC(2026, 0, 1, hour++)).toISOString();
const push = (ev) => {
  events.push(Object.assign({ seq: events.length + 1, at: at(), provenance: "observed", origin: ORIGIN }, ev));
};

// steps: "step=status;step=status" in stream order.
const pairs = String(spec.steps || "").split(";").filter(Boolean).map((p) => p.split("="));
let enteredWritten = false;
const writeEntered = () => {
  push({
    kind: "worktree",
    transition: "entered",
    git_branch: spec.branch || "feature/2527-fixture",
    cwd: spec.cwd || null,
    worktree_path: spec.cwd || null,
    path_source: "tool_input",
  });
  enteredWritten = true;
};

for (const [step, status] of pairs) {
  push({ kind: "step_status", step, status });
  // entered: the worktree "entered" event lands right after the first branching_complete.
  if (spec.entered && !enteredWritten && step === "branching_complete") writeEntered();
}
if (spec.entered && !enteredWritten) writeEntered();
if (spec.uvReset) {
  push({ kind: "step_annotation", step: "user_verification", key: "reset_reason", value: spec.uvReset });
}

const out = {
  version: spec.version === undefined ? 4 : spec.version,
  session_id: spec.sid,
  created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: spec.cwd || null, git_branch: spec.branch || null },
};
// type: legacy workflow_type value (default wf-code); null omits the key.
if (spec.type !== null) out.workflow_type = spec.type || "wf-code";
out.closes_issues = [2527];
out.last_pushed_sha = spec.lastPushed || null;
// extra: merged verbatim into the top level (used for v5-shaped fixtures).
Object.assign(out, spec.extra || {});
out.events = events;

fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, spec.sid + ".json"), JSON.stringify(out, null, 2));
