#!/usr/bin/env node
"use strict";
// baseline-checkout-marker.js — tags the temporary merge-base checkouts that
// bin/run-tests-baseline creates (#2431). The marker lives in the linked
// worktree's private gitdir, so it vanishes with `git worktree remove` and is
// never part of any tracked tree. provenance-identity.js refuses such a checkout
// as a RUN_CONTRACT emitter root: base-commit output must never complete run_tests.

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("./path-normalize");

const BASELINE_CHECKOUT_MARKER = "agents-baseline-checkout";

// The private gitdir of a LINKED worktree (`.git` is a file), else null.
function linkedGitDir(root) {
  const base = normalizeCwd(root) || root;
  if (typeof base !== "string" || base === "") return null;
  const dotGit = path.join(base, ".git");
  if (!fs.statSync(dotGit).isFile()) return null;
  const m = /^\s*gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(dotGit, "utf8"));
  if (m === null) return null;
  const gitdir = path.resolve(base, normalizeCwd(m[1]) || m[1]);
  return fs.statSync(gitdir).isDirectory() ? gitdir : null;
}

function isBaselineCheckout(root) {
  try {
    const gitdir = linkedGitDir(root);
    if (gitdir === null) return false;
    return fs.statSync(path.join(gitdir, BASELINE_CHECKOUT_MARKER)).isFile();
  } catch (e) {
    return false;
  }
}

function mark(root) {
  const gitdir = linkedGitDir(root);
  if (gitdir === null) throw new Error(`not a linked worktree: ${root}`);
  fs.writeFileSync(path.join(gitdir, BASELINE_CHECKOUT_MARKER), "");
}

if (require.main === module) {
  const [cmd, root] = process.argv.slice(2);
  if (cmd !== "mark" || !root) {
    process.stderr.write("usage: baseline-checkout-marker.js mark <worktree-root>\n");
    process.exit(2);
  }
  try {
    mark(root);
  } catch (e) {
    process.stderr.write(`baseline-checkout-marker: ${e.message}\n`);
    process.exit(1);
  }
}

module.exports = { BASELINE_CHECKOUT_MARKER, isBaselineCheckout, mark };
