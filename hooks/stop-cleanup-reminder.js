#!/usr/bin/env node
const { resolveSessionId, readState } = require("./lib/workflow-state");

let input = {};
try {
  const raw = require("fs").readFileSync(0, "utf8").trim();
  if (raw) input = JSON.parse(raw);
} catch (e) {}

if (input.stop_hook_active) process.exit(0);

const sessionId = resolveSessionId() || input.session_id || null;
if (!sessionId) process.exit(0);

const state = readState(sessionId);
if (!state) process.exit(0);

if (state.steps?.user_verification?.status !== "complete") process.exit(0);

const cleanup = state.steps?.cleanup;
if (cleanup?.status === "complete" || cleanup?.status === "skipped") process.exit(0);

const decision = state.steps?.branching_complete?.decision ?? "";

let reason = null;
if (decision.startsWith("worktree:")) {
  reason =
    "[workflow] WF-CODE-11 (Cleanup) is pending. Run `/worktree-end` to merge and remove the worktree, " +
    'then mark complete: echo "<<WORKFLOW_MARK_STEP_cleanup_complete>>"';
} else if (decision.startsWith("branch:")) {
  const name = decision.replace(/^branch:\s*/, "").trim();
  reason =
    `[workflow] WF-CODE-11 (Cleanup) is pending. Create a PR if not done. ` +
    `After the PR is merged, delete the branch: git branch -d ${name} && git push origin --delete ${name}. ` +
    `Then mark complete: echo "<<WORKFLOW_MARK_STEP_cleanup_complete>>"`;
}

if (reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(2);
}
