"use strict";

const { getSessionRepoRoots } = require("./session-scope");
const { isExcluded } = require("./shared-cmd-utils");
const { findRepoRoot, normalizeForCompare } = require("./git-repo-detection");
const { WRITE_PATTERNS, classify } = require("../lib/bash-write-patterns");
const { splitShellCommands } = require("../lib/shell-segments");
const { expandStaticShellTokens } = require("../lib/bash-write-targets/redirect");
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

// True if all targets are provably under getWorkflowPlansDir().
// Used to allow out-of-session-scope Bash writes from a non-git CWD (#878):
// non-git CWD is allowed ONLY when every target is under plans-dir, preserving
// fail-closed denial for arbitrary /tmp or external paths.
function areAllBashTargetsUnderPlansDir(targets) {
  if (!targets || targets.length === 0) return false;
  try {
    const nodePath = require("path");
    const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
    let plansDir;
    try { plansDir = getWorkflowPlansDir(); } catch (_) { return false; }
    if (!plansDir) return false;
    const normPlans = nodePath.resolve(plansDir).toLowerCase();
    const isUnder = (t) => {
      const raw = t.replace(/^["']|["']$/g, ""); // strip surrounding quotes
      let resolved = raw;
      if (raw.includes("$") || raw.includes("~")) {
        const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
        if (expanded === null) return false; // fail-closed: unresolvable $VAR
        resolved = expanded;
      }
      const n = nodePath.resolve(resolved).toLowerCase();
      return n === normPlans ||
        n.startsWith(normPlans + nodePath.sep) ||
        n.startsWith(normPlans + "/");
    };
    return targets.every(isUnder);
  } catch (_) {
    return false; // fail-closed
  }
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

// Per-segment EXCLUDE check for sequenced commands (#739).
// Splits cmd on ; && || (quote-aware), then for each segment:
//   - "read" → transparent (continue)
//   - "write" → require all write targets to be EXCLUDE-matched
// Returns true ONLY when ≥1 write segment was verified excluded AND no write
// segment produced parseFailure / null targets / a non-excluded target.
// Fail-closed: any unresolvable segment returns false.
function isEverySegmentExcluded(cmd, repoRoot, patterns) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!patterns || patterns.length === 0) return false;
  if (cmd.includes("\r") || cmd.includes("\n")) return false;
  const segments = splitShellCommands(cmd);
  if (segments.length === 0) return false;

  let hasWriteSegment = false;
  for (const segment of segments) {
    const kind = classify(segment);
    if (kind === "read") continue;
    // write segment
    hasWriteSegment = true;
    const result = collectBashWriteTargets(segment);
    if (result.parseFailure === true) return false;
    if (result.targets === null || result.targets.length === 0) return false;
    for (const target of result.targets) {
      if (!isExcluded(target, patterns)) return false;
    }
  }
  return hasWriteSegment === true;
}

module.exports = {
  isInSessionScope,
  collectBashWriteTargets,
  areAllBashTargetsOutsideSessionScope,
  areAllBashTargetsUnderPlansDir,
  isWriteTargetAllExcluded,
  isEverySegmentExcluded,
  isGhWriteCommand,
};
