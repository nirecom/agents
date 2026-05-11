#!/usr/bin/env node
// Thin wrapper around the `ignore` package providing full gitignore semantics.
// Used by worktree-copy.js and bin/worktree-copy-include.js.

const ignore = require("ignore");

function buildMatcher(patterns) {
  return ignore().add(patterns);
}

module.exports = { buildMatcher };
