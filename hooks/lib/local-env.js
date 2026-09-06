#!/usr/bin/env node
// Project-local config overlay: the 2-layer resolver behind the global .env and
// a reviewed project's own .env.local.
// Trust model: a key reaches the local layer only when the global .env declares
// it in LOCAL_OVERRIDABLE_KEYS, and never when it is on the hard-coded deny
// list below — declaration cannot buy a key past that list.
// Pure module: no filesystem reads beyond the .git probe, no process.env reads
// beyond CLAUDE_PROJECT_DIR (path resolution only).

const fs = require("fs");
const path = require("path");

const LOCAL_ENV_BASENAME = ".env.local";

// PROJECT_NFR is deliberately absent: a project must opt in explicitly.
const DEFAULT_LOCAL_OVERRIDABLE = ["CODE_LANG"];

const NEVER_OVERRIDABLE_EXACT = new Set([
  "ENFORCE_WORKTREE",
  "WORKFLOW_PLANS_DIR",
  "AGENTS_CONFIG_DIR",
  "CLAUDE_WORKFLOW_DIR",
  "WORKTREE_BASE_DIR",
  "DEFAULT_BRANCHES",
  "LOCAL_OVERRIDABLE_KEYS",
  "CODEX_MCP_FS",
  "AUTO_MERGE_PR",
  // Guard-decision and process-runtime names: none of these are config values
  // a project's own .env.local should ever be able to set for real, since each
  // one changes what code runs or which permissions are granted, not what a
  // review reports.
  "SYSTEM_OPS_APPROVED",
  "SCRATCHPAD",
  "AGENT_AUTO_BRANCH",
  "AGENT_DEFAULT_BRANCHES",
  "ISSUE_CLOSE_SKILL",
  "CLAUDE_BLOCK_TESTS_DIR_NAMES",
  "CLAUDE_PROJECT_DIR",
  "PATH",
  "NODE_OPTIONS",
  "BASH_ENV",
  "LD_PRELOAD",
  "GIT_SSH_COMMAND",
]);

const NEVER_OVERRIDABLE_PREFIXES = ["ENFORCE_", "CONFIRM_", "AUTO_", "SESSION_SYNC", "RUN_TL"];

// isNeverOverridable answers the deny list, which outranks every declaration.
// Case-folded to upper-case: Windows environment variables are case-insensitive
// (process.env.enforce_worktree and process.env.ENFORCE_WORKTREE name the same
// slot there), so a lower-case declaration must not slip past a same-cased check.
function isNeverOverridable(key) {
  if (typeof key !== "string" || key.length === 0) return true;
  const upper = key.toUpperCase();
  if (NEVER_OVERRIDABLE_EXACT.has(upper)) return true;
  return NEVER_OVERRIDABLE_PREFIXES.some((p) => upper.startsWith(p));
}

// resolveOverridableKeys reads LOCAL_OVERRIDABLE_KEYS out of the GLOBAL map.
// Absent → the built-in seed; present → exactly what it lists (an empty value
// means "nothing is overridable"). Deny-listed entries are dropped either way.
function resolveOverridableKeys(globalMap) {
  const map = globalMap || {};
  const declared = Object.prototype.hasOwnProperty.call(map, "LOCAL_OVERRIDABLE_KEYS")
    ? String(map.LOCAL_OVERRIDABLE_KEYS).split(",")
    : DEFAULT_LOCAL_OVERRIDABLE;
  const out = new Set();
  for (const raw of declared) {
    const key = String(raw).trim();
    if (!key || isNeverOverridable(key)) continue;
    out.add(key);
  }
  return out;
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

// overlay merges localMap onto globalMap for allowed, non-deny-listed keys.
// Pure: neither input is mutated. Returns {map, applied, ignored}, where
// `ignored` names the allowed keys the deny list refused — an undeclared key was
// never a candidate, so it is silently absent from both lists.
function overlay(globalMap, localMap, allowedKeys) {
  const result = Object.assign({}, globalMap || {});
  const allowed = allowedKeys instanceof Set ? allowedKeys : new Set(allowedKeys || []);
  const applied = [];
  const ignored = [];

  for (const key of Object.keys(localMap || {})) {
    if (!allowed.has(key)) continue;
    if (isNeverOverridable(key)) {
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
  DEFAULT_LOCAL_OVERRIDABLE,
  NEVER_OVERRIDABLE_EXACT,
  NEVER_OVERRIDABLE_PREFIXES,
  isNeverOverridable,
  resolveOverridableKeys,
  resolveProjectRoot,
  localEnvPathFor,
  overlay,
};
