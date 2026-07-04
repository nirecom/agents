"use strict";

const { getSessionRepoRoots } = require("./session-scope");
const { isExcluded } = require("./shared-cmd-utils");
const { findRepoRoot, normalizeForCompare } = require("./git-repo-detection");
const { classify, isGhWriteIR } = require("../lib/bash-write-patterns");
const { splitShellCommands } = require("../lib/shell-segments");
const { parse } = require("../lib/command-ir");
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
// Accepts an IR object (post-#1294) or a raw command string (backward compat).
// Any extractor returning null → parseFailure = true (fail-closed).
function collectBashWriteTargets(ir) {
  // Backward compat: accept raw string — parse it into IR.
  if (typeof ir === "string") ir = parse(ir);

  // Fail-closed: malformed IR → no targets.
  if (!ir || ir.parseFailure === true) return { targets: null, parseFailure: true };

  const cmd = ir.rawText;
  const targets = [];
  let parseFailure = false;

  // Resolve effective command name: for env-prefix form (VAR=val cmd args...),
  // cmd0 is the assignment and the actual command is argv[0].
  const effectiveCmd0 = (s) => {
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(s.cmd0) && s.argv && s.argv.length > 0) return s.argv[0];
    return s.cmd0;
  };

  if (ir.segments.some((s) => s.redirects && s.redirects.some((r) => r.op !== "<" && r.op !== "<<<"))) {
    const r = extractRedirectTargets(cmd);
    if (r === null) parseFailure = true;
    else targets.push(...r);
  }
  if (ir.segments.some((s) => effectiveCmd0(s) === "tee")) {
    const t = extractTeeTargets(cmd);
    if (t === null) parseFailure = true;
    else targets.push(...t);
  }
  if (ir.segments.some((s) => /^(?:set-content|add-content|out-file|new-item|remove-item|move-item|copy-item|sc|ac|ni|ri|mi|ci)$/i.test(effectiveCmd0(s)))) {
    const p = extractPwshWriteTargets(cmd);
    if (p === null) parseFailure = true;
    else targets.push(...p);
  }
  if (ir.segments.some((s) => effectiveCmd0(s) === "cp" || effectiveCmd0(s) === "mv")) {
    const d = extractCpMvDestination(cmd);
    if (d === null) parseFailure = true;
    else targets.push(d);
  }
  if (ir.segments.some((s) => effectiveCmd0(s) === "rm")) {
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

// True if cmd/ir is a Group B gh write. Accepts IR object or raw string (backward compat).
function isGhWriteCommand(ir) {
  if (typeof ir === "string") ir = parse(ir);
  return isGhWriteIR(ir);
}

// Per-segment EXCLUDE check for sequenced commands (#739).
// Accepts an IR object (post-#1294) or a raw command string (backward compat).
// For each segment:
//   - "read" → transparent (continue)
//   - "write" → require all write targets to be EXCLUDE-matched
// Returns true ONLY when ≥1 write segment was verified excluded AND no write
// segment produced parseFailure / null targets / a non-excluded target.
// Fail-closed: any unresolvable segment returns false.
function isEverySegmentExcluded(ir, repoRoot, patterns) {
  // Backward compat: accept raw string.
  if (typeof ir === "string") ir = parse(ir);

  if (!ir || ir.parseFailure === true) return false;
  if (!patterns || patterns.length === 0) return false;
  if (ir.rawText.includes("\r") || ir.rawText.includes("\n")) return false;
  if (!ir.segments || ir.segments.length === 0) return false;

  let hasWriteSegment = false;
  for (const seg of ir.segments) {
    const segIr = { rawText: seg.rawText, segments: [seg], parseFailure: false, cmd0: seg.cmd0, argv: seg.argv, redirects: seg.redirects, kind: seg.kind, separators: [] };
    const kind = classify(segIr);
    if (kind === "read") continue;
    // write segment
    hasWriteSegment = true;
    const result = collectBashWriteTargets(segIr);
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
