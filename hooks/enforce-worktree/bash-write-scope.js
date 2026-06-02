"use strict";

const { getSessionRepoRoots } = require("./session-scope");
const { isExcluded } = require("./shared-cmd-utils");
const { findRepoRoot, normalizeForCompare } = require("./git-repo-detection");
const { WRITE_PATTERNS } = require("../lib/bash-write-patterns");
const {
  extractRedirectTargets, extractTeeTargets,
  extractPwshWriteTargets, extractCpMvDestination,
  extractRmTargets, extractStagedFiles,
} = require("../lib/bash-write-targets");

function isInSessionScope(repoRoot, sessionRoots) {
  if (!repoRoot) return false;
  const norm = normalizeForCompare(repoRoot);
  return norm ? sessionRoots.has(norm) : false;
}

// Collect write targets from all applicable extractors (redirect, tee, PS cmdlets).
// Any extractor returning null → parseFailure = true (fail-closed).
function collectBashWriteTargets(cmd) {
  const targets = [];
  let parseFailure = false;

  if (/(?:^|[\s;|&])(?:\d*)(?:&>>?|>>?)(?!>|\d)/.test(cmd)) {
    const r = extractRedirectTargets(cmd);
    if (r === null) parseFailure = true;
    else targets.push(...r);
  }
  if (/(?:^|[\s;|&])tee\b/.test(cmd)) {
    const t = extractTeeTargets(cmd);
    if (t === null) parseFailure = true;
    else targets.push(...t);
  }
  if (/\b(?:Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item)\b/i.test(cmd)
      || /(?:^|[\s;|&])(?:sc|ac|ni|ri|mi|ci)\b/.test(cmd)) {
    const p = extractPwshWriteTargets(cmd);
    if (p === null) parseFailure = true;
    else targets.push(...p);
  }
  if (/(?:^|[\s;|&])(?:cp|mv)\b/.test(cmd)) {
    const d = extractCpMvDestination(cmd);
    if (d === null) parseFailure = true;
    else targets.push(d);
  }
  if (/(?:^|[\s;|&])rm\b/.test(cmd)) {
    const r = extractRmTargets(cmd);
    if (r === null) parseFailure = true;
    else targets.push(...r);
  }

  return { targets: targets.length > 0 ? targets : null, parseFailure };
}

// True if all targets resolve to repos outside the session scope.
// findRepoRoot()==null (non-git path) is also treated as outside scope (allow).
function areAllBashTargetsOutsideSessionScope(targets, sessionRoots) {
  if (!targets || targets.length === 0) return false;
  for (const t of targets) {
    const repo = findRepoRoot(t);
    if (repo !== null && isInSessionScope(repo, sessionRoots)) return false;
  }
  return true;
}

// EXCLUDE check for file-target writes and git commit (staged files).
function isWriteTargetAllExcluded(cmd, targets, repoRoot, patterns) {
  if (!patterns || patterns.length === 0) return false;
  const isGitCommit = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*commit\b/.test(cmd);

  if (isGitCommit) {
    const staged = extractStagedFiles(repoRoot);
    if (staged === null || staged.length === 0) return false;
    if (!staged.every((f) => isExcluded(f, patterns))) return false;
  }

  if (targets) {
    if (!targets.every((f) => isExcluded(f, patterns))) return false;
  }

  return isGitCommit || (targets !== null && targets.length > 0);
}

// True if cmd matches any kind:"gh" entry in WRITE_PATTERNS (= Group B gh writes).
function isGhWriteCommand(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  for (const p of WRITE_PATTERNS) {
    if (p.kind === "gh" && p.regex.test(cmd)) return true;
  }
  return false;
}

module.exports = {
  isInSessionScope,
  collectBashWriteTargets,
  areAllBashTargetsOutsideSessionScope,
  isWriteTargetAllExcluded,
  isGhWriteCommand,
};
