"use strict";

// Committed pre-commit helper: are ALL staged files covered by
// ENFORCE_WORKTREE_EXCLUDE? Shares shared-cmd-utils with the JS hook so JS/Bash
// parity is structural (no reimplemented matcher in Bash).
// Env in: AGENTS_CONFIG_DIR, _PRECOMMIT_STAGED, _PRECOMMIT_REPO_TOP (all
// required), ENFORCE_WORKTREE_EXCLUDE (optional, semicolon-separated).
// Exit: 0 covered (gate may be skipped) / 2 not covered or empty list / 1 input error.

const path = require("path");
const fs = require("fs");

const cfg = process.env.AGENTS_CONFIG_DIR;
if (!cfg) process.exit(1);

// __dirname-relative require: OS-agnostic. AGENTS_CONFIG_DIR may be a POSIX drive-letter
// path under Git-Bash, which Windows Node cannot resolve via require();
// resolving relative to this file's directory avoids that platform dependency.
const { getExcludePatterns, isExcluded } =
  require("../enforce-worktree/shared-cmd-utils");

// Resolve symlinks best-effort: tries the full path first, then walks up parent
// directories until finding one that resolves, and re-appends the unresolved tail.
// On macOS /var is a symlink to /private/var; staged files often do not yet exist
// on disk so a plain realpathSync would throw ENOENT. The walk-up finds the nearest
// existing ancestor and resolves its symlinks, making paths consistent with
// process.cwd() which the OS always returns as the physical path via getcwd().
function realPathBestEffort(p) {
  try { return fs.realpathSync(p); } catch (e) {}
  const tail = [];
  let cur = p;
  for (;;) {
    const parent = path.dirname(cur);
    if (parent === cur) break;
    tail.unshift(path.basename(cur));
    cur = parent;
    try { return path.join(fs.realpathSync(cur), ...tail); } catch (e) {}
  }
  return p;
}

const repoTop = process.env._PRECOMMIT_REPO_TOP || "";
const staged = process.env._PRECOMMIT_STAGED || "";
const files = staged.split(/\r?\n/).filter(Boolean);

if (files.length === 0) process.exit(2);

// Normalize repoTop so that path.resolve(realRepoTop, rel) uses the physical path,
// consistent with _canon(relative_entry) which uses process.cwd() (always physical).
const realRepoTop = repoTop ? realPathBestEffort(repoTop) : "";

// Also normalize absolute entries in patterns for the same reason.
const rawPatterns = getExcludePatterns();
const patterns = rawPatterns.map((p) =>
  p && !p.includes("*") && path.isAbsolute(p) ? realPathBestEffort(p) : p
);
if (patterns.length === 0) process.exit(2);

for (const rel of files) {
  const physAbs = realRepoTop ? path.resolve(realRepoTop, rel) : path.resolve(rel);
  const abs = realPathBestEffort(physAbs);
  if (!isExcluded(abs, patterns)) process.exit(2);
}
process.exit(0);
