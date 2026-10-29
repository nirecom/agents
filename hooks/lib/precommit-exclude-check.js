"use strict";

// Committed pre-commit helper: are ALL staged files covered by
// ENFORCE_WORKTREE_EXCLUDE? Shares shared-cmd-utils with the JS hook so JS/Bash
// parity is structural (no reimplemented matcher in Bash).
// Env in: _PRECOMMIT_STAGED, _PRECOMMIT_REPO_TOP (both
// required), ENFORCE_WORKTREE_EXCLUDE (optional, semicolon-separated).
// run({ env }) -> 0 covered (gate may be skipped) / 2 not covered or empty list; the CLI exits with it.

const path = require("path");
const fs = require("fs");

// __dirname-relative require: OS-agnostic. A path handed over by Git-Bash may be
// in POSIX drive-letter form, which Windows Node cannot resolve via require().
const { isExcluded, BUILTIN_EXCLUDE_PATTERNS } = require("../enforce-worktree/shared-cmd-utils");
const { parseExcludePatterns } = require("./glob-match");

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

function run(opts) {
  const env = (opts && opts.env) || process.env;
  const repoTop = env._PRECOMMIT_REPO_TOP || "";
  const files = (env._PRECOMMIT_STAGED || "").split(/\r?\n/).filter(Boolean);
  if (files.length === 0) return 2;

  // Normalize repoTop so that path.resolve(realRepoTop, rel) uses the physical path,
  // consistent with _canon(relative_entry) which uses process.cwd() (always physical).
  const realRepoTop = repoTop ? realPathBestEffort(repoTop) : "";

  // Also normalize absolute entries in patterns for the same reason.
  const rawPatterns = BUILTIN_EXCLUDE_PATTERNS.concat(parseExcludePatterns(env.ENFORCE_WORKTREE_EXCLUDE || ""));
  const patterns = rawPatterns.map((p) =>
    p && !p.includes("*") && path.isAbsolute(p) ? realPathBestEffort(p) : p
  );
  if (patterns.length === 0) return 2;

  for (const rel of files) {
    const physAbs = realRepoTop ? path.resolve(realRepoTop, rel) : path.resolve(rel);
    const abs = realPathBestEffort(physAbs);
    if (!isExcluded(abs, patterns)) return 2;
  }
  return 0;
}

module.exports = { run };

if (require.main === module) process.exit(run({ argv: process.argv.slice(2), env: process.env }));
