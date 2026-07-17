"use strict";

const { getSessionRepoRoots } = require("./session-scope");
const { isExcluded } = require("./shared-cmd-utils");
const { findRepoRoot, normalizeForCompare } = require("./git-repo-detection");
const { isAllowedScratchpadTarget } = require("../lib/claude-scratchpad-base");
const { classify, isGhWriteIR } = require("../lib/bash-write-patterns");
const { isGitWriteIR } = require("../lib/bash-write-patterns/patterns");
const { splitShellCommands } = require("../lib/shell-segments");
const { parse } = require("../lib/command-ir");
const { expandStaticShellTokens } = require("../lib/bash-write-targets/helpers");
const {
  extractStagedFiles,
  collectWriteTargetsFromSegments, FULL_VERB_SET,
  isPosixRedirWriteIR, isPwshWriteIR, isFileOpWriteIR, isCommandSubstWriteIR, isExoticExecWriteIR,
  isInterpreterCWriteIR, isEncodedCommandWriteIR, isExtendedFileOpWriteIR,
} = require("../lib/bash-write-targets");
const { extractFileOpTargets } = require("../lib/bash-write-targets/file-op");
const { extractGitWriteTargets } = require("../lib/bash-write-targets/git");
const { isPkgMgrWriteIR, extractPkgMgrWriteTargets } = require("../lib/bash-write-targets/pkg-mgr");

function isInSessionScope(repoRoot, sessionRoots) {
  if (!repoRoot) return false;
  const norm = normalizeForCompare(repoRoot);
  return norm ? sessionRoots.has(norm) : false;
}

// Defensive: the write-target contract is a typed {resolveVia, path} object
// (post-#1400/#1401). A future or missed caller passing a bare string target
// must NOT silently fail-open to "outside scope". Normalize a bare string to the
// safest interpretation — {resolveVia:"ancestor", path: str} — so it is still
// resolved to a repo root and scope-checked (fail-closed toward blocking).
//
// Fail-closed on malformed typed objects: an object present but with a
// missing/non-string `path` used to coerce to String(undefined)="undefined" in
// scope checks, producing a surprising allow/abstain (clean fail-open to
// "outside scope"). Instead, mark it malformed:true so scope predicates treat it
// as in-session / parse-failure (the safe direction → block/abstain), never a
// clean "outside scope" allow.
function normalizeTarget(t) {
  if (typeof t === "string") return { resolveVia: "ancestor", path: t };
  if (!t || typeof t !== "object" || typeof t.path !== "string") {
    return { malformed: true, resolveVia: "ancestor", path: "" };
  }
  return t;
}

// Collect write targets from all applicable extractors (redirect, tee, PS cmdlets,
// cp/mv/rm) plus — when repoRoot is supplied and the command is a git write — the
// git self-target (resolveVia:"self"). Accepts an IR object (post-#1294) or a raw
// command string (backward compat). Any extractor returning null → parseFailure.
//
// repoRoot (optional): when provided AND isGitWriteIR(ir), merge the git
// self-target. When omitted, git extraction is skipped and only the green
// ancestor targets are returned (back-compat for per-segment callers).
function collectBashWriteTargets(ir, repoRoot) {
  // Backward compat: accept raw string — parse it into IR.
  if (typeof ir === "string") ir = parse(ir);

  // Fail-closed: malformed IR → no targets.
  if (!ir || ir.parseFailure === true) return { targets: null, parseFailure: true };

  const green = collectWriteTargetsFromSegments(ir.segments, { verbs: FULL_VERB_SET });

  // Git self-target merge (C1): only when repoRoot was passed AND this is a git write.
  if (repoRoot !== undefined && isGitWriteIR(ir)) {
    const gitTargets = extractGitWriteTargets(ir, repoRoot);
    if (gitTargets === null) {
      // git write but repoRoot unresolvable → fail-closed.
      return { targets: green.targets, parseFailure: true };
    }
    if (gitTargets.length > 0) {
      const merged = (green.targets || []).concat(gitTargets);
      return { targets: merged, parseFailure: green.parseFailure };
    }
  }

  // Pkg-mgr self-target merge: only when repoRoot was passed AND this is a pkg-mgr write.
  if (repoRoot !== undefined && isPkgMgrWriteIR(ir)) {
    const pkgMgrTargets = extractPkgMgrWriteTargets(ir, repoRoot);
    if (pkgMgrTargets === null) {
      // pkg-mgr write but repoRoot unresolvable → fail-closed.
      return { targets: green.targets, parseFailure: true };
    }
    if (pkgMgrTargets.length > 0) {
      const merged = (green.targets || []).concat(pkgMgrTargets);
      return { targets: merged, parseFailure: green.parseFailure };
    }
  }

  // Extended file-op targets are ancestor-file targets (repoRoot-independent) —
  // merge unconditionally so per-segment EXCLUDE callers (which pass no repoRoot)
  // also receive them (C5).
  if (isExtendedFileOpWriteIR(ir)) {
    const fileOpTargets = extractFileOpTargets(ir);
    if (fileOpTargets === null) {
      return { targets: green.targets, parseFailure: true };
    }
    if (fileOpTargets.length > 0) {
      const wrapped = fileOpTargets.map((p) => ({ resolveVia: "ancestor", path: p }));
      green.targets = (green.targets || []).concat(wrapped);
    }
  }

  return green;
}

// True if all targets resolve to repos outside the session scope.
// findRepoRoot()==null (non-git path) is also treated as outside scope (allow).
function areAllBashTargetsOutsideSessionScope(targets, sessionRoots) {
  if (!targets || targets.length === 0) return false;
  for (const rawT of targets) {
    const t = normalizeTarget(rawT);
    // Malformed target → fail-closed: treat as in-session (not outside scope) so
    // the command is not silently allowed. Return false = "not all outside".
    if (t.malformed === true) return false;
    // Strip surrounding shell quotes from the path (some extractors return raw
    // token strings that include the original quotes) — the quote-strip that used
    // to live in universal-target-allow's caller is centralized here (CPR-2).
    const rawPath = String(t.path).replace(/^["']|["']$/g, "");
    let repo;
    if (t.resolveVia === "self") {
      // path IS the resolved scope root — do NOT call findRepoRoot.
      repo = rawPath;
    } else {
      // "ancestor" (default): path is a file inside a repo; resolve upward.
      repo = findRepoRoot(rawPath);
    }
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
    const isUnder = (rawT) => {
      const t = normalizeTarget(rawT);
      if (t.malformed === true) return false; // fail-closed: not provably under plans-dir
      const raw = String(t.path).replace(/^["']|["']$/g, ""); // strip surrounding quotes
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

// True if all targets are provably under the session scratchpad allow root (H2:
// the SCRATCHPAD dir when the harness exposes it, else <os-tmpdir>/claude/) AND
// outside every git repo root. NOT a generic temp-dir allow: /tmp/evil.md,
// /var/tmp/evil.md, <tmpdir>/evil.md (root), and /tmp/not-claude/... all remain blocked.
// F1 hardening: the outside-repo clause defends against a poisoned TEMP/TMP that nests
// the claude base inside a repo (SSOT base + guard live in lib/claude-scratchpad-base.js).
function areAllBashTargetsUnderClaude(targets) {
  if (!targets || targets.length === 0) return false;
  try {
    const nodePath = require("path");
    const isUnder = (rawT) => {
      const t = normalizeTarget(rawT);
      if (t.malformed === true) return false;
      const raw = String(t.path).replace(/^["']|["']$/g, "");
      let resolved = raw;
      if (raw.includes("$") || raw.includes("~")) {
        const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
        if (expanded === null) return false;
        resolved = expanded;
      }
      // Reject path traversal
      if (/(?:^|[/\\])\.\.(?:[/\\]|$)/.test(resolved)) return false;
      const n = nodePath.resolve(resolved);
      // Must be strictly under the scratchpad allow root AND outside every repo root.
      return isAllowedScratchpadTarget(n, findRepoRoot);
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

  // File-target EXCLUDE check applies only to file-path ("ancestor") targets.
  // A git self-target ({resolveVia:"self", path:repoRoot}) is a repo root, not a
  // file — it is NEVER covered by a file-path EXCLUDE glob, so including it here
  // would wrongly fail the staged-file EXCLUDE exception for `git commit` (the
  // git self-target was merged into `targets` post-#1401). The self-target's
  // exclusion is governed by the staged-file check above, not by file globs.
  const fileTargets = targets ? targets.filter((t) => t.resolveVia !== "self") : null;
  if (fileTargets && fileTargets.length > 0) {
    if (!fileTargets.every((f) => isExcluded(f.path, patterns))) return false;
  }

  return isGitCommit || (fileTargets !== null && fileTargets.length > 0);
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
    const segIr = { rawText: seg.rawText, segments: [seg], parseFailure: false, cmd0: seg.cmd0, cmd0Raw: seg.cmd0Raw || "", argv: seg.argv, argvRaw: seg.argvRaw || [], redirects: seg.redirects, kind: seg.kind, separators: [] };
    // A segment is a write when classify() flags it OR a green-group IR predicate
    // matches. The green predicates are required because their WRITE_PATTERNS
    // entries were retired (#1400) — classify() alone no longer flags redirect /
    // tee / pwsh-cmdlet / rm / cp / mv segments (mirror of the fast-allow gate).
    // BUG 2 fix: git/gh write segments must also count as writes. Their
    // WRITE_PATTERNS entries were retired (#1296/#1400/#1401), so classify()
    // alone no longer flags them; without the isGitWriteIR / isGhWriteIR
    // predicates here, a git/gh write segment was treated as a transparent read
    // and a sequence like `cp src .worktree-backup/x/f && git commit` /
    // `... && gh pr merge` fast-allowed with only the file segment EXCLUDE-checked.
    const isGhWrite = isGhWriteIR(segIr);
    // gh writes have NO local file target — an EXCLUDE file pattern can never
    // satisfy them. Fail closed to the main-worktree block.
    if (isGhWrite) return false;
    // Exotic execution-bearing constructs (eval / xargs / find action clauses)
    // carry their write verb as an ARGUMENT — there is no clean, statically
    // resolvable local file target to EXCLUDE-check. Fail closed to the block,
    // same treatment as gh writes (final shell-layer round).
    if (isExoticExecWriteIR(segIr)) return false;
    if (isPkgMgrWriteIR(segIr)) return false;
    if (isInterpreterCWriteIR(segIr)) return false;
    if (isEncodedCommandWriteIR(segIr)) return false; // no extractable local target → fail-closed
    const isGitWrite = isGitWriteIR(segIr);
    const isWriteSeg = classify(segIr) === "write" ||
      isPosixRedirWriteIR(segIr) || isPwshWriteIR(segIr) || isFileOpWriteIR(segIr) ||
      isCommandSubstWriteIR(segIr) ||
      isExtendedFileOpWriteIR(segIr) ||
      isGitWrite;
    if (!isWriteSeg) continue;
    // write segment
    hasWriteSegment = true;
    // For a git-write segment, thread repoRoot so the git self-target
    // ({resolveVia:"self", path:repoRoot}) is produced and EXCLUDE-checked. A
    // git self-target is repoRoot — never covered by a file-path EXCLUDE
    // pattern → the sequence fails "all excluded" → returns false → block.
    const result = isGitWrite
      ? collectBashWriteTargets(segIr, repoRoot)
      : collectBashWriteTargets(segIr);
    if (result.parseFailure === true) return false;
    if (result.targets === null || result.targets.length === 0) return false;
    for (const target of result.targets) {
      // Symmetry with isWriteTargetAllExcluded (post-#1401): a git self-target
      // ({resolveVia:"self", path:repoRoot}) is a REPO ROOT, not a file. It must
      // NEVER be satisfiable by a file-path EXCLUDE glob — otherwise a broad
      // pattern (e.g. `**`) matching the repo root / a prefix would wrongly mark
      // a git-write segment "excluded" and let a sequenced `... && git commit`
      // fast-allow past the main-worktree guard (sequenced-exclude bypass).
      // Fail-closed: a self-target is never exclude-satisfiable here → the
      // segment is not-all-excluded → return false → block.
      if (target.resolveVia === "self") return false;
      if (!isExcluded(target.path, patterns)) return false;
    }
  }
  return hasWriteSegment === true;
}

module.exports = {
  isInSessionScope,
  collectBashWriteTargets,
  areAllBashTargetsOutsideSessionScope,
  areAllBashTargetsUnderPlansDir,
  areAllBashTargetsUnderClaude,
  isWriteTargetAllExcluded,
  isEverySegmentExcluded,
  isGhWriteCommand,
};
