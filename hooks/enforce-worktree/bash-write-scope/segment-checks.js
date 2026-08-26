"use strict";

const { isExcluded } = require("../shared-cmd-utils");
const { parse } = require("../../lib/command-ir");
const { classify, isGhWriteIR } = require("../../lib/bash-write-patterns");
const { isGitWriteIR } = require("../../lib/bash-write-patterns/patterns");
const {
  isPosixRedirWriteIR, isPwshWriteIR, isFileOpWriteIR, isCommandSubstWriteIR, isExoticExecWriteIR,
  isInterpreterCWriteIR, isEncodedCommandWriteIR, isExtendedFileOpWriteIR,
} = require("../../lib/bash-write-targets");
const { isPkgMgrWriteIR } = require("../../lib/bash-write-targets/pkg-mgr");
const { collectBashWriteTargets } = require("./collect-targets");
const { areAllBashTargetsOutsideSessionScope } = require("./scope-checks");
const { areAllBashTargetsUnderWorkflowDir } = require("./marker-gate");

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

// Per-segment scope check for sequenced commands (#1448A).
// Accepts an IR object. For each segment:
//   - read segment → skip (continue)
//   - write segment with extractable targets → check each target with isInSessionScope;
//     if any target is in scope → return false (fail-closed)
//   - write segment with no extractable targets (targetless write: git commit, gh pr merge,
//     interpreter-c, encoded-command, exotic-exec, pkg-mgr without extractable path) →
//     return false (fail-closed)
// Returns true only when every write segment's targets are provably outside session scope.
// Mirrors isEverySegmentExcluded's segment iteration pattern but checks scope instead of EXCLUDE.
function areAllWriteSegmentsOutsideSessionScope(ir, repoRoot, sessionRoots) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments || ir.segments.length === 0) return false;

  for (const seg of ir.segments) {
    const segIr = { rawText: seg.rawText, segments: [seg], parseFailure: false, cmd0: seg.cmd0, cmd0Raw: seg.cmd0Raw || "", argv: seg.argv, argvRaw: seg.argvRaw || [], redirects: seg.redirects, kind: seg.kind, separators: [] };
    // Targetless write predicates: no local file target extractable → fail-closed.
    const isGhWrite = isGhWriteIR(segIr);
    if (isGhWrite) return false;
    if (isExoticExecWriteIR(segIr)) return false;
    if (isPkgMgrWriteIR(segIr)) return false;
    if (isInterpreterCWriteIR(segIr)) return false;
    if (isEncodedCommandWriteIR(segIr)) return false;
    // Determine if this is a write segment (mirrors isEverySegmentExcluded logic).
    const isGitWrite = isGitWriteIR(segIr);
    const isWriteSeg = classify(segIr) === "write" ||
      isPosixRedirWriteIR(segIr) || isPwshWriteIR(segIr) || isFileOpWriteIR(segIr) ||
      isCommandSubstWriteIR(segIr) ||
      isExtendedFileOpWriteIR(segIr) ||
      isGitWrite;
    if (!isWriteSeg) continue;
    // Write segment: collect targets and scope-check each one.
    const result = isGitWrite
      ? collectBashWriteTargets(segIr, repoRoot)
      : collectBashWriteTargets(segIr);
    if (result.parseFailure === true) return false;
    // Targetless write (no extractable targets) → fail-closed.
    if (result.targets === null || result.targets.length === 0) return false;
    // Check each target: if any resolves inside session scope → fail-closed.
    if (!areAllBashTargetsOutsideSessionScope(result.targets, sessionRoots)) return false;
  }
  return true;
}

// Per-segment scope check for sequenced commands (#1709 H-2 fix).
// Mirrors areAllWriteSegmentsOutsideSessionScope's iteration pattern but checks
// containment under the workflow dir instead of session-scope exclusion.
// A targetless write segment (git commit, gh pr merge, interpreter -c, etc.)
// fails closed — extraction can't prove it stays under the workflow dir.
// `opts` is `{ sessionCtx }` (#2108), passed straight through to the marker gate.
function areAllWriteSegmentsUnderWorkflowDir(ir, repoRoot, opts) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments || ir.segments.length === 0) return false;

  let hasWriteSegment = false;
  for (const seg of ir.segments) {
    const segIr = { rawText: seg.rawText, segments: [seg], parseFailure: false, cmd0: seg.cmd0, cmd0Raw: seg.cmd0Raw || "", argv: seg.argv, argvRaw: seg.argvRaw || [], redirects: seg.redirects, kind: seg.kind, separators: [] };
    const isGhWrite = isGhWriteIR(segIr);
    if (isGhWrite) return false;
    if (isExoticExecWriteIR(segIr)) return false;
    if (isPkgMgrWriteIR(segIr)) return false;
    if (isInterpreterCWriteIR(segIr)) return false;
    if (isEncodedCommandWriteIR(segIr)) return false;
    const isGitWrite = isGitWriteIR(segIr);
    const isWriteSeg = classify(segIr) === "write" ||
      isPosixRedirWriteIR(segIr) || isPwshWriteIR(segIr) || isFileOpWriteIR(segIr) ||
      isCommandSubstWriteIR(segIr) ||
      isExtendedFileOpWriteIR(segIr) ||
      isGitWrite;
    if (!isWriteSeg) continue;
    hasWriteSegment = true;
    // A git self-target ({resolveVia:"self", path:repoRoot}) is a repo root,
    // never under the workflow dir → fail-closed via the same collect path.
    const result = isGitWrite
      ? collectBashWriteTargets(segIr, repoRoot)
      : collectBashWriteTargets(segIr);
    if (result.parseFailure === true) return false;
    if (result.targets === null || result.targets.length === 0) return false;
    if (!areAllBashTargetsUnderWorkflowDir(result.targets, opts)) return false;
  }
  return hasWriteSegment === true;
}

module.exports = {
  isEverySegmentExcluded,
  areAllWriteSegmentsOutsideSessionScope,
  areAllWriteSegmentsUnderWorkflowDir,
};
