"use strict";
// hooks/lib/alt-target-remedy.js
// Shared alternative-write-target wording for ENFORCE_WORKTREE / workflow-gate block
// reasons (#2120 Change 3, CPR-SSOT/CPR-ORTH — one remedy sentence, reused by every
// site that blocks a write). Naming a target the agent can actually reach turns a
// bare stop into a redirect, instead of leaving the agent to retry the same blocked
// tool. Model pattern: the pre-existing enforce-worktree.js remedy "use Edit/Write
// tools or set ENFORCE_WORKTREE=off".

const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { getClaudeBaseNorm } = require("./claude-scratchpad-base");

function buildAltTargetRemedy() {
  let plansDir;
  try {
    plansDir = getWorkflowPlansDir();
  } catch (_e) {
    plansDir = "~/.workflow-plans";
  }
  let scratchpad;
  try {
    scratchpad = getClaudeBaseNorm();
  } catch (_e) {
    scratchpad = "<os-tmpdir>/claude";
  }
  return (
    "Need to write right now? Use Write/Edit/MultiEdit to target the plans dir " +
    `(${plansDir}) or the scratchpad (${scratchpad}) instead.`
  );
}

module.exports = { buildAltTargetRemedy };
