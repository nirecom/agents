"use strict";

const { parse } = require("../../lib/command-ir");
const {
  collectWriteTargetsFromSegments, FULL_VERB_SET,
  isExtendedFileOpWriteIR,
} = require("../../lib/bash-write-targets");
const { isGitWriteIR } = require("../../lib/bash-write-patterns/patterns");
const { extractFileOpTargets } = require("../../lib/bash-write-targets/file-op");
const { extractGitWriteTargets } = require("../../lib/bash-write-targets/git");
const { isPkgMgrWriteIR, extractPkgMgrWriteTargets } = require("../../lib/bash-write-targets/pkg-mgr");

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

module.exports = {
  collectBashWriteTargets,
};
