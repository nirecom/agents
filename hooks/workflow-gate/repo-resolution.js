"use strict";
// Repo directory resolver: maps a git command or hook payload to the relevant repo
// root via -C arg, cd prefix, payload cwd (isLinkedWorktree gate), or staged-change scan.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { normalizeForWindows } = require("./path-normalize");
const { isLinkedWorktree } = require("./worktree-context");
const { hasStagedChanges } = require("./staged-evidence");
const { parseGitCArg, parseCdCommand } = require("../lib/parse-git-args");
const { getGitCommonDir } = require("../lib/git-common-dir");

// Read additionalDirectories from the assembled ~/.claude/settings.json, falling back
// to agents/settings.json so the hook works before the first install run.
function findAdditionalDirectories() {
  try {
    const agentsRoot = path.resolve(__dirname, "..", "..");
    const claudePath = path.join(os.homedir(), ".claude", "settings.json");
    const agentsPath = path.join(agentsRoot, "settings.json");
    const settingsPath = fs.existsSync(claudePath) ? claudePath : agentsPath;
    const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    const dirs = (settings.permissions || settings).additionalDirectories || [];
    // Filter out linked worktrees: relative paths like "../agents" resolve to the
    // linked worktree itself when the hook runs from a worktree, causing
    // Tier 4 to return the worktree (with staged WIP) instead of the test's temp
    // repo. Linked worktrees are already handled by Tier 3 (payload-cwd gate).
    return dirs
      .map((d) => path.isAbsolute(d) ? d : path.resolve(agentsRoot, d))
      .filter((d) => !isLinkedWorktree(d));
  } catch (e) {
    return [];
  }
}

// Resolve repo dir from explicit path in the command, or detect from staged changes.
// Resolution order:
//   1. `git -C <path>` argument (with env-var expansion + Windows normalization)
//   2. `cd <abs-path> && ...` leading command (Windows normalization)
//   3. `input.cwd` (Bash hook payload) — authoritative when it resolves to a
//      linked worktree (isLinkedWorktree gate). Closes #380, #394.
//   4. CLAUDE_PROJECT_DIR / process.cwd() (primary), then additionalDirectories,
//      preferring whichever has staged changes
function resolveRepoDir(command, input) {
  const raw = parseGitCArg(command);
  const expanded = raw ? raw.replace(/\$\{(\w+)\}|\$(\w+)/g, (_, a, b) => process.env[a || b] || '') : raw;
  const cArg = normalizeForWindows(expanded);
  if (cArg) return cArg;

  const cdArg = normalizeForWindows(parseCdCommand(command));
  if (cdArg) return cdArg;

  // Tier 3 — hook payload cwd, gated by isLinkedWorktree. Authoritative under
  // Windows VS Code where process.cwd() drifts to the main worktree (CC #27343).
  // Gate prevents stale/main-checkout cwd from bypassing Tier 4's staged-change
  // search across CLAUDE_PROJECT_DIR + additionalDirectories.
  const payloadCwd = input && typeof input.cwd === 'string' ? input.cwd : null;
  const normPayloadCwd = normalizeForWindows(payloadCwd);
  if (normPayloadCwd && isLinkedWorktree(normPayloadCwd)) return normPayloadCwd;
  // else: fall through to Tier 4

  const primary = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const norm = (p) => p.replace(/\\/g, "/").replace(/\/$/, "").toLowerCase();
  if (hasStagedChanges(primary)) return primary;
  for (const dir of findAdditionalDirectories()) {
    if (norm(dir) === norm(primary)) continue;
    if (hasStagedChanges(dir)) return dir;
  }
  return primary;
}

// True when repoDir is (or is a linked worktree of) the agents session repo.
// Fail-closed: returns true on any error so gate enforcement is never skipped
// due to a transient git failure. Returns false only when git confirms the two
// repos have different common-dirs.
function isAgentsSessionRepo(repoDir) {
  if (!repoDir) return true;
  try {
    const agentsRoot = process.env.AGENTS_CONFIG_DIR || path.resolve(__dirname, "..", "..");
    const targetCommonDir = getGitCommonDir(repoDir);
    const agentsCommonDir = getGitCommonDir(agentsRoot);
    if (!targetCommonDir || !agentsCommonDir) return true;
    const norm = (p) => p.replace(/\\/g, "/").toLowerCase();
    return norm(targetCommonDir) === norm(agentsCommonDir);
  } catch (_) {
    return true;
  }
}

module.exports = { findAdditionalDirectories, resolveRepoDir, isAgentsSessionRepo };
