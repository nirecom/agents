// hooks/block-clearance-token-write/bash-target-context.js
// Context-aware classification of one Bash WRITE TARGET (redirect target or argv path).
// N-1 (#1780): variable splicing (`S=.workflow-off; … > <wf>/s1$S`) is resolved by
// substituteAssignments(); anything unresolved fails closed when the chain names a protected file.
// N-2 (#1780): a pure-wildcard target (`<wf>/*`) fails closed when its directory resolves
// at/under any listStateRoots() root (#2511); globs elsewhere stay approved.
// Dispatch + re-export only; the logic and its rationale live in ./bash-target-context/
// (substitute.js <- classify.js <- cwd-tracking.js, one-directional).
"use strict";

const { substituteAssignments } = require("./bash-target-context/substitute");
const { commandCwd } = require("./bash-target-context/cwd-tracking");
const {
  resolveStateRoots,
  resolveWorkflowDir,
  globTargetInsideWorkflowDir,
  dynamicTargetInsideWorkflowDir,
  textNamesPathInsideWorkflowDir,
  classifyBashWriteTarget,
} = require("./bash-target-context/classify");

module.exports = {
  substituteAssignments,
  commandCwd,
  resolveStateRoots,
  resolveWorkflowDir,
  globTargetInsideWorkflowDir,
  dynamicTargetInsideWorkflowDir,
  textNamesPathInsideWorkflowDir,
  classifyBashWriteTarget,
};
