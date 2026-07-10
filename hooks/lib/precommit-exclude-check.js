"use strict";

// Committed pre-commit helper: decides whether ALL staged files are covered by
// ENFORCE_WORKTREE_EXCLUDE (path-coverage). Requires the same shared-cmd-utils
// module the JS hook uses, so JS/Bash parity is structural (no reimplemented
// matcher in Bash).
//
// Inputs (env):
//   AGENTS_CONFIG_DIR      — agents repo root (required)
//   _PRECOMMIT_STAGED      — newline-separated staged file relative paths (required)
//   _PRECOMMIT_REPO_TOP    — git show-toplevel absolute path (required)
//   ENFORCE_WORKTREE_EXCLUDE       — semicolon-separated entries (optional)
//   ENFORCE_WORKTREE_EXCLUDE_REPOS — deprecated alias (optional)
//
// Exit codes:
//   0 — all staged files covered → enforce gate may be skipped
//   2 — not all covered, or the entry list is empty → run enforce gate
//   1 — input error (AGENTS_CONFIG_DIR unset)

const path = require("path");

const cfg = process.env.AGENTS_CONFIG_DIR;
if (!cfg) process.exit(1);

// __dirname-relative require: OS-agnostic. AGENTS_CONFIG_DIR may be a POSIX-style
// path (/c/git/...) under Git-Bash, which Windows Node cannot resolve via require();
// resolving relative to this file's directory avoids that platform dependency.
const { getExcludePatterns, isExcluded } =
  require("../enforce-worktree/shared-cmd-utils");

// --- BEGIN temporary: ENFORCE_WORKTREE_EXCLUDE_REPOS → ENFORCE_WORKTREE_EXCLUDE migration ---
if (process.env.ENFORCE_WORKTREE_EXCLUDE_REPOS) {
  process.stderr.write(
    "pre-commit: ENFORCE_WORKTREE_EXCLUDE_REPOS is deprecated; " +
    "migrate entries to ENFORCE_WORKTREE_EXCLUDE in your .env\n"
  );
  const existing = process.env.ENFORCE_WORKTREE_EXCLUDE || "";
  const extra = process.env.ENFORCE_WORKTREE_EXCLUDE_REPOS;
  process.env.ENFORCE_WORKTREE_EXCLUDE = existing ? existing + ";" + extra : extra;
}
// --- END temporary: ENFORCE_WORKTREE_EXCLUDE_REPOS → ENFORCE_WORKTREE_EXCLUDE migration ---

const repoTop = process.env._PRECOMMIT_REPO_TOP || "";
const staged = process.env._PRECOMMIT_STAGED || "";
const files = staged.split(/\r?\n/).filter(Boolean);

if (files.length === 0) process.exit(2);

const patterns = getExcludePatterns();
if (patterns.length === 0) process.exit(2);

for (const rel of files) {
  const abs = repoTop ? path.resolve(repoTop, rel) : path.resolve(rel);
  if (!isExcluded(abs, patterns)) process.exit(2);
}
process.exit(0);
