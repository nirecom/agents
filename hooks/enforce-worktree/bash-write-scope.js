"use strict";

// Dispatch + re-export only (Pattern A, rules/coding/file-split.md HARD limit).
// Logic lives in the sibling ./bash-write-scope/ directory, split by
// responsibility: target normalization, symlink-aware realpath resolution,
// write-target collection, session/plans-dir/scratchpad scope checks, the
// off-clearance marker gate, EXCLUDE-pattern checks, and per-segment checks
// for sequenced commands.

const { splitShellCommands } = require("../lib/shell-segments");

const { collectBashWriteTargets } = require("./bash-write-scope/collect-targets");
const {
  isInSessionScope,
  areAllBashTargetsOutsideSessionScope,
  areAllBashTargetsUnderPlansDir,
  areAllBashTargetsUnderClaude,
} = require("./bash-write-scope/scope-checks");
const {
  areAllBashTargetsUnderWorkflowDir,
  bashTargetsHitProtectedMarker,
} = require("./bash-write-scope/marker-gate");
const {
  isWriteTargetAllExcluded,
  isGhWriteCommand,
} = require("./bash-write-scope/exclude-checks");
const {
  isEverySegmentExcluded,
  areAllWriteSegmentsOutsideSessionScope,
  areAllWriteSegmentsUnderWorkflowDir,
} = require("./bash-write-scope/segment-checks");

module.exports = {
  isInSessionScope,
  collectBashWriteTargets,
  areAllBashTargetsOutsideSessionScope,
  areAllWriteSegmentsUnderWorkflowDir,
  areAllBashTargetsUnderPlansDir,
  areAllBashTargetsUnderClaude,
  areAllBashTargetsUnderWorkflowDir,
  isWriteTargetAllExcluded,
  isEverySegmentExcluded,
  areAllWriteSegmentsOutsideSessionScope,
  isGhWriteCommand,
  bashTargetsHitProtectedMarker,
};
