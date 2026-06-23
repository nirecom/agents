"use strict";
// Dispatch + re-export only. All predicate logic lives in main-worktree-allows/.
// See rules/coding/file-split.md (Pattern A): <name>.js is re-export only.
const standard = require("./main-worktree-allows/standard");
module.exports = Object.assign({}, standard);
