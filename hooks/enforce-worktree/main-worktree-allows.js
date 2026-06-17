"use strict";
// Dispatch + re-export only. All predicate logic lives in main-worktree-allows/.
// See rules/coding/file-split.md (Pattern A): <name>.js is re-export only.
const standard = require("./main-worktree-allows/standard");
const { isAllowedWorkflowPlansDirWrite } = require("./main-worktree-allows/plans-dir");
module.exports = Object.assign({}, standard, { isAllowedWorkflowPlansDirWrite });
