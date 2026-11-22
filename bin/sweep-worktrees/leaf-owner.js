#!/usr/bin/env node
"use strict";
// Usage: node leaf-owner.js <leaf dir> — prints the main checkout that owns a gitlink leftover
// (#1610 shared-base ownership), by the same reverse lookup hooks/cleanup-orphan-dir.js proves it
// with. Prints nothing when the leaf is not an unregistered leftover of a non-bare repo. Exit 0.

const path = require("path");
const { classifyWorktreeLeftover } = require("../../hooks/workflow-state/resolve-worktree-path");
const { mainRootOf } = require("../../hooks/cleanup-orphan-dir/leftover");
const { normalizeCwd } = require("../../hooks/lib/path-normalize");

const leaf = process.argv[2];
if (leaf) {
  try {
    const { kind, commonDir } = classifyWorktreeLeftover(path.resolve(normalizeCwd(leaf) || leaf));
    const root = kind === "unregistered-leftover" ? mainRootOf(commonDir) : null;
    if (root) process.stdout.write(root.replace(/\\/g, "/") + "\n");
  } catch (e) {
    /* no proven owner */
  }
}
