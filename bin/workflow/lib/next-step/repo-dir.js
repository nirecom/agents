"use strict";
// Single resolution of the git repo root (forwarded to evidence predicates).
// Shared leaf module: both the --list renderer and the verdict computation use it.

// Precedence: CLAUDE_PROJECT_DIR → git rev-parse → cwd.
let _repoDirCache;
function resolveRepoDir() {
  if (_repoDirCache !== undefined) return _repoDirCache;
  let repoDir = process.env.CLAUDE_PROJECT_DIR || null;
  if (!repoDir) {
    try {
      repoDir = require("child_process").execSync(
        "git rev-parse --show-toplevel", { encoding: "utf8", timeout: 5000 }
      ).trim();
    } catch (e) { repoDir = process.cwd(); }
  }
  _repoDirCache = repoDir;
  return repoDir;
}

module.exports = { resolveRepoDir };
