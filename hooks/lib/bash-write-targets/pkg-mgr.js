"use strict";

// hooks/lib/bash-write-targets/pkg-mgr.js
// Package-manager write detection (IR-based SSOT). Retired from WRITE_PATTERNS
// (#1411 canary-6a). Covers npm, pnpm, yarn, pip, pip3, uv, cargo, go.
//
// FORM recognition is by BASENAME (isPkgMgrBasename) so path-qualified / `.exe` /
// wrapped forms all resolve correctly. SUBCOMMAND classification is a read-allowlist
// (fail-closed): a subcommand is treated as a WRITE unless it is in the read-list
// for that tool. Unknown / future / exotic subcommands default to WRITE.

const { resolveEffectiveCommand, resolveEffectiveArgv, scanWrappedVerb, commandBasename } = require("../bash-write-patterns/segment-utils");

const PKG_MGR_NAMES = new Set(["npm", "pnpm", "yarn", "pip", "pip3", "uv", "cargo", "go"]);

// Read-allowlist per tool. Keys are single-word subcommands; 2-word entries use
// the form "word1 word2". Classification tries the 2-word key first (when argv
// has ≥2 tokens after the tool name), then the single-word key.
const READ_LISTS = {
  npm: new Set([
    "list", "ls", "info", "view", "search", "outdated", "ping", "doctor",
    "--version", "-v", "--help", "-h",
    "config get", "config list",
  ]),
  pnpm: new Set([
    "list", "ls", "info", "view", "why", "outdated",
    "--version", "-v", "--help", "-h",
  ]),
  yarn: new Set([
    "list", "info", "why", "outdated", "audit",
    "--version", "-v", "--help", "-h",
  ]),
  pip: new Set([
    "show", "list", "search", "check", "freeze",
    "--version", "-V", "--help", "-h",
    "config get", "config list",
  ]),
  pip3: new Set([
    "show", "list", "search", "check", "freeze",
    "--version", "-V", "--help", "-h",
    "config get", "config list",
  ]),
  uv: new Set([
    "tree", "--version", "-V", "--help", "-h",
    "pip show", "pip list", "pip freeze", "pip check",
  ]),
  cargo: new Set([
    "tree", "metadata", "search",
    "--version", "-V", "--help", "-h",
  ]),
  go: new Set([
    "env", "version", "list", "doc", "vet", "--help", "help",
    "mod graph", "mod verify", "mod why",
  ]),
};

/**
 * isPkgMgrBasename: recognize a package manager binary regardless of how it is
 * spelled. Strip any directory prefix (POSIX `/` or Windows `\`) and a trailing
 * `.exe`, lowercase, and compare against the known set. Catches path-qualified
 * forms like `/usr/local/bin/npm`, `C:\...\npm.exe`, etc.
 */
function isPkgMgrBasename(cmd) {
  if (typeof cmd !== "string" || cmd === "") return false;
  const base = cmd.split(/[\\/]/).pop();
  if (!base) return false;
  return PKG_MGR_NAMES.has(base.replace(/\.exe$/i, "").toLowerCase());
}

/**
 * classifyPkgMgrSubcommand: read-allowlist, fail-closed.
 * Returns true (write) unless the subcommand is in the tool's read-list.
 * @param {string} tool - normalized tool name (e.g. "npm", "pip3")
 * @param {string[]} subArgv - argv AFTER the tool name token (argv.slice(1))
 * @returns {boolean} true = write, false = read
 */
function classifyPkgMgrSubcommand(tool, subArgv) {
  const readList = READ_LISTS[tool];
  if (!readList) return true; // unknown tool → fail-closed write

  if (!subArgv || subArgv.length === 0 || !subArgv[0]) return true; // bare tool → fail-closed write

  // Try 2-word key first (when ≥2 tokens available).
  if (subArgv.length >= 2 && subArgv[1] != null) {
    const twoWord = subArgv[0] + " " + subArgv[1];
    if (readList.has(twoWord)) return false; // read
  }

  // Single-word key.
  if (readList.has(subArgv[0])) return false; // read

  return true; // write (fail-closed)
}

/**
 * isPkgMgrWriteIR: IR-owned package-manager write detector.
 * Returns true when ANY segment resolves to a write package-manager invocation.
 */
function isPkgMgrWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments || ir.segments.length === 0) return false;

  for (const seg of ir.segments) {
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd != null && isPkgMgrBasename(effCmd)) {
      const argv = resolveEffectiveArgv(seg);
      const tool = commandBasename(effCmd).replace(/\.exe$/i, "").toLowerCase();
      // resolveEffectiveArgv returns argv WITHOUT the tool name (starts at first arg).
      if (classifyPkgMgrSubcommand(tool, argv || [])) return true;
      continue;
    }
    // Fail-closed safety net (AMBIGUOUS bail): a wrapper segment whose effective
    // command could not be cleanly resolved may still hide a wrapped pkg-mgr write.
    if (scanWrappedVerb(seg, (tok, rest) => {
      if (!isPkgMgrBasename(tok)) return false;
      const tool = commandBasename(tok).replace(/\.exe$/i, "").toLowerCase();
      return classifyPkgMgrSubcommand(tool, rest);
    })) return true;
  }
  return false;
}

/**
 * extractPkgMgrWriteTargets: package-manager writes target the repo (lock files /
 * node_modules / site-packages inside the repo), not a specific file path. Their
 * scope target is the repoRoot itself, tagged {resolveVia:"self"}.
 *
 * @param {import('../command-ir').IR} ir
 * @param {string|null|undefined} repoRoot
 * @returns {Array<{resolveVia:"self",path:string}>|null|[]}
 *   - []   when not a pkg-mgr write.
 *   - [{resolveVia:"self", path: repoRoot}] when a pkg-mgr write and repoRoot is a non-empty string.
 *   - null when a pkg-mgr write but repoRoot is null/empty (fail-closed).
 */
function extractPkgMgrWriteTargets(ir, repoRoot) {
  if (!isPkgMgrWriteIR(ir)) return [];
  if (typeof repoRoot !== "string" || repoRoot === "") return null; // fail-closed
  return [{ resolveVia: "self", path: repoRoot }];
}

module.exports = { isPkgMgrBasename, classifyPkgMgrSubcommand, isPkgMgrWriteIR, extractPkgMgrWriteTargets };
