// hooks/block-off-clearance-write/bash-scan.js
// Barrel for the Bash / runInTerminal / runCommands command analysis used by the
// block-off-clearance-write entrypoint. Dispatch + re-export only — all logic
// lives in ./bash-scan/{assignment-text,argv-scan,redirect-scan,scan}.js
// (rules/coding/file-split.md Pattern A).
"use strict";

const assignmentText = require("./bash-scan/assignment-text");
const argvScan = require("./bash-scan/argv-scan");
const redirectScan = require("./bash-scan/redirect-scan");
const scan = require("./bash-scan/scan");

module.exports = {
  // assignment-text
  isAssignmentOnlySegment: assignmentText.isAssignmentOnlySegment,
  precedingAssignmentChainText: assignmentText.precedingAssignmentChainText,
  priorAssignmentsText: assignmentText.priorAssignmentsText,
  // argv-scan
  segmentArgvHitsProtectedArg: argvScan.segmentArgvHitsProtectedArg,
  // redirect-scan
  redirectRawTargetsHitProtected: redirectScan.redirectRawTargetsHitProtected,
  // scan
  bashHitsProtected: scan.bashHitsProtected,
};
