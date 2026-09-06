#!/usr/bin/env node
// Project-local config overlay: the 2-layer resolver behind the global .env and
// a reviewed project's own .env.local.
// Trust model: every key a project sets in .env.local applies, except the ones
// the blocklist below refuses. That list names the settings whose per-repo
// divergence breaks the agents repo's own contract — either a 1-PC-1-policy
// value, or one whose consumer reads the global .env directly and would leave a
// local override half-applied. Per-key rationale: issue #2223.
// Pure module: no filesystem reads beyond the .git probe, no process.env reads
// beyond CLAUDE_PROJECT_DIR (path resolution only).

const fs = require("fs");
const path = require("path");

const LOCAL_ENV_BASENAME = ".env.local";

// ENFORCE_WORKTREE, ENFORCE_WORKTREE_EXCLUDE, ENFORCE_WORKTREE_ADDITIONAL_REPOS
// and DEFAULT_BRANCHES are here for the half-applied reason: hooks/pre-commit
// reads them through load-env.sh, which has no .env.local layer, so a local
// override would silence the Node guard while the pre-commit one still fires.
// CODE_FILE_EXTENSIONS and CLAUDE_CODE_AUTO_COMPACT_WINDOW never reach a local
// value at all — their readers bypass process.env. Per-repo ENFORCE_WORKTREE
// belongs in the global .env's ENFORCE_WORKTREE_EXCLUDE instead.
const ENV_ENTRY_BLOCKLIST_EXACT = new Set([
  "SHOW_PLAN_LINK_NO_AUTO_OPEN",
  "WORKFLOW_PLANS_DIR",
  "WORKTREE_BASE_DIR",
  "ENFORCE_WORKTREE",
  "ENFORCE_WORKTREE_EXCLUDE",
  "ENFORCE_WORKTREE_ADDITIONAL_REPOS",
  "SWEEP_AGE_DAYS",
  "CODE_LANG_EXCLUDE",
  "CODE_FILE_EXTENSIONS",
  "VERBOSE_PROMPT_MODELS",
  "ISSUE_VERDICT_WEB_SEARCH",
  "MCP_FS_DEBUG",
  "MERGE_BASE_MAX_DIFF_LINES",
  "MERGE_BASE_MAX_DIFF_FILES",
  "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
  "DEFAULT_BRANCHES",
  "AUTO_APPROVE_TOOLS",
]);

// SESSION_ also covers the harness-supplied SESSION_ID; PROPAGATE_ covers the
// PROPAGATE_LABELS_PAT credential; CODEX_ covers CODEX_NFR_MAX_*, the caps on
// the very PROJECT_NFR text the project itself supplies; COMMENT_BLOCK_ reaches
// only a pre-commit reader that deliberately bypasses process.env.
const ENV_ENTRY_BLOCKLIST_PREFIX = ["SESSION_", "PROPAGATE_", "CODEX_", "COMMENT_BLOCK_"];

// isBlocklisted answers the deny list. Case-folded to upper-case: Windows
// environment variables are case-insensitive (process.env.enforce_worktree and
// process.env.ENFORCE_WORKTREE name the same slot there), so a lower-case key
// in .env.local must not slip past a same-cased check.
function isBlocklisted(key) {
  if (typeof key !== "string" || key.length === 0) return true;
  const upper = key.toUpperCase();
  if (ENV_ENTRY_BLOCKLIST_EXACT.has(upper)) return true;
  return ENV_ENTRY_BLOCKLIST_PREFIX.some((p) => upper.startsWith(p));
}

// hasGitEntry answers whether `dir` carries a .git entry. A linked worktree's
// .git is a file (`gitdir: <path>`), so presence — not kind — is the test.
function hasGitEntry(dir) {
  try {
    return fs.existsSync(path.join(dir, ".git"));
  } catch {
    return false;
  }
}

// resolveProjectRoot: explicit argument > CLAUDE_PROJECT_DIR > upward .git
// search from startDir > null. Never spawns git.
function resolveProjectRoot(explicitRoot, startDir) {
  if (explicitRoot) return path.resolve(String(explicitRoot));
  if (process.env.CLAUDE_PROJECT_DIR) return path.resolve(process.env.CLAUDE_PROJECT_DIR);

  let dir;
  try {
    dir = path.resolve(startDir || process.cwd());
  } catch {
    return null;
  }
  for (;;) {
    if (hasGitEntry(dir)) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function localEnvPathFor(root) {
  if (!root) return null;
  return path.join(String(root), LOCAL_ENV_BASENAME);
}

// overlay merges localMap onto globalMap for every non-blocklisted key.
// Pure: neither input is mutated. Returns {map, applied, ignored}, where
// `ignored` names the keys the blocklist refused.
function overlay(globalMap, localMap) {
  const result = Object.assign({}, globalMap || {});
  const applied = [];
  const ignored = [];

  for (const key of Object.keys(localMap || {})) {
    if (isBlocklisted(key)) {
      ignored.push(key);
      continue;
    }
    result[key] = localMap[key];
    applied.push(key);
  }
  return { map: result, applied, ignored };
}

module.exports = {
  LOCAL_ENV_BASENAME,
  ENV_ENTRY_BLOCKLIST_EXACT,
  ENV_ENTRY_BLOCKLIST_PREFIX,
  isBlocklisted,
  resolveProjectRoot,
  localEnvPathFor,
  overlay,
};
