"use strict";
// H2 hardening, generalized to every evidence read recordStepVerdict performs on
// the advance gate: resolve the repo root strictly from git's own view of the
// real process cwd — never from process.env — so a forged CLAUDE_PROJECT_DIR
// prefix on a model-issued `next-step --advance` cannot redirect an evidence
// check to a directory of the model's choosing. null (fail-closed) outside a repo.

function resolveTrustedRepoDir() {
  try {
    const { execFileSync } = require("child_process");
    const out = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const dir = out.trim();
    return dir || null;
  } catch (_) {
    return null;
  }
}

module.exports = { resolveTrustedRepoDir };
