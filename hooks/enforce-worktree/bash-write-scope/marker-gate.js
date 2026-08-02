"use strict";

const { expandStaticShellTokens } = require("../../lib/bash-write-targets/helpers");
const {
  PROTECTED_MARKER_BASENAME_RE,
  hitsProtectedMarkerBasename,
  hitsTokenBasename,
} = require("../../lib/protected-basenames");

// #1780 round-5 MEDIUM-7: the two protected basename FAMILIES — session markers
// and OFF-clearance tokens — are symmetric members of one class (CPR-5). Both
// are consulted together everywhere a write is being DETECTED, so the pairing
// is written once here instead of at each call site.
function hitsAnyProtectedBasename(basename) {
  return hitsProtectedMarkerBasename(basename) || hitsTokenBasename(basename);
}
const { isContainedUnder, normalizeTarget } = require("./target-normalize");
const { realResolve } = require("./realpath-resolve");

// #1709/#1780 H4 (security-scanner round 5): the workflow-dir allow fast-path
// approves EVERY write beneath the workflow dir, including the session-marker
// files that gate WORKFLOW_OFF/WORKTREE_OFF/issue-close-verified/next-step-paused
// clearance (hooks/lib/session-markers.js authorizes purely on a marker's
// existence). Without this exclusion, a single unguarded Bash write such as
// `echo x > <sid>.workflow-off` forges full clearance state and defeats the
// entire off-clearance gate this fix set exists to hardened. Marker basenames
// fall through to the normal (fail-closed) enforcement path instead.
//
// #1780 H-1/H-2: this file is DEFENCE IN DEPTH only. enforce-worktree.js is a
// worktree-LOCATION guard, so from a linked worktree on a feature branch its
// tail still allows — marker integrity is location-INDEPENDENT and is now
// primarily enforced by hooks/block-off-clearance-write.js. Both read the same
// protected-basename SSOT (hooks/lib/protected-basenames.js) so the two can
// never diverge (CPR-2).
// hitsProtectedMarkerBasename() applies the quote / NTFS-ADS / trailing-dot /
// glob normalization from hooks/lib/basename-glob-normalize.js; the raw regex is
// re-exported unchanged for callers that only want the shape.

function areAllBashTargetsUnderWorkflowDir(targets) {
  if (!targets || targets.length === 0) return false;
  try {
    const nodePath = require("path");
    const { getWorkflowDir } = require("../../workflow-state");
    let wfDir;
    try { wfDir = getWorkflowDir(); } catch (_) { return false; }
    if (!wfDir) return false;
    // #1780 H-3: containment is decided by isContainedUnder(), which folds case
    // only on a filesystem PROVEN case-insensitive by probe. Pre-folding both
    // sides here (the old caseFold) made `<wf>/State` look contained in
    // `<wf>/state` on a case-sensitive volume — an allow for a path outside the
    // workflow dir.
    const normWf = realResolve(wfDir);
    const isUnder = (rawT) => {
      const t = normalizeTarget(rawT);
      if (t.malformed === true) return false;           // fail-closed
      const raw = String(t.path).replace(/^["']|["']$/g, "");
      let resolved = raw;
      if (raw.includes("$") || raw.includes("~")) {
        const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
        if (expanded === null) return false;            // fail-closed: unresolvable $VAR
        resolved = expanded;
      }
      if (/(?:^|[/\\])\.\.(?:[/\\]|$)/.test(resolved)) return false; // no traversal
      const n = realResolve(resolved);
      // F-3 (security-scanner round 6): the lexical-only marker check missed a
      // two-step symlink indirection — `ln -s <wf>/<sid>.workflow-off
      // <wf>/lnk` then `echo x > lnk` — where the write target's OWN path
      // ("lnk") never matches PROTECTED_MARKER_BASENAME_RE even though
      // realResolve() (used for containment just below) follows the symlink
      // to the actual protected marker file on disk. Check the marker regex
      // against BOTH the lexical basename (nonexistent-target case, where
      // realResolve falls back to the lexical form) and the realpath'd
      // basename (existing-symlink case) so the indirection fails closed too.
      // H-2 (security-scanner round 8): the pre-realResolve `resolved` form still
      // carries whatever glob metachars / trailing whitespace-dots the raw
      // command text spelled (the real shell resolves these to the on-disk
      // marker basename at execution time, but this check runs BEFORE that
      // expansion) — normalize before testing, same treatment as H-1's sibling
      // fix in hooks/block-off-clearance-write.js (CPR-5). `n` is already
      // realpath'd (no glob survives symlink/existing-file resolution) but is
      // normalized too for uniformity and to catch a nonexistent-target glob
      // that realResolve() falls back to lexically.
      // #1780 round-5 MEDIUM-7 (CPR-5): the OFF-clearance TOKEN lives in this
      // same directory and grants the same clearance, so it is excluded from
      // the allow fast-path on identical grounds. The sanctioned mint route
      // (bin/request-off-clearance) writes it from inside a subprocess, which
      // no PreToolUse hook sees, so nothing legitimate loses its allow here.
      if (hitsAnyProtectedBasename(nodePath.basename(resolved))) return false; // H4 fail-closed
      if (hitsAnyProtectedBasename(nodePath.basename(n))) return false; // F-3 fail-closed
      // Directory itself is NOT allowed (unlike the plans-dir variant): that keeps
      // `rm -rf <workflowDir>` blocked. Only strict descendants pass.
      return isContainedUnder(n, normWf, { allowEqual: false });
    };
    return targets.every(isUnder);
  } catch (_) {
    return false; // fail-closed
  }
}

// #1780 H-3 (security-scanner round 8): areAllBashTargetsUnderWorkflowDir() is the
// ONLY function that consults PROTECTED_MARKER_BASENAME_RE. Several independent
// allow fast-paths (checkUniversalTargetAllow's session-scope guard in
// universal-target-allow.js; the `repoRoot !== null` disjunct of the Bug2 rule in
// enforce-worktree.js) approve a Bash write purely on "target resolves outside
// session scope" — trivially true for the default workflow-dir location, since
// the workflow dir normally lives outside every session repo — without ever
// calling areAllBashTargetsUnderWorkflowDir(). A marker write therefore slips
// through untouched whenever the command's CWD happens to be inside any git
// repo. Rather than scatter a marker check into each of those allow paths
// individually, this predicate is a single, location-independent early gate:
// true iff ANY extracted target's basename (raw, shell-token-expanded, or
// realpath'd — mirroring the three forms areAllBashTargetsUnderWorkflowDir
// itself checks) hits a protected marker basename, regardless of where that
// target resolves. Callers must skip ALL allow-paths (not just the workflow-dir
// one) when this returns true, falling through to fail-closed enforcement.
function bashTargetsHitProtectedMarker(targets) {
  if (!targets || targets.length === 0) return false;
  const nodePath = require("path");
  return targets.some((rawT) => {
    const t = normalizeTarget(rawT);
    // #1780 round-5 MEDIUM-7: this predicate runs in the DETECTION direction —
    // `true` means "skip every allow fast-path". A target the normalizer could
    // not make sense of is therefore the one case that must NOT be waved
    // through: `false` here restored the allow paths for exactly the inputs
    // nothing could vouch for. Its sibling above (the permission direction)
    // already answers `false` on malformed for the same reason — both say
    // "cannot vouch", which is `false` there and `true` here.
    if (t.malformed === true) return true;
    const raw = String(t.path).replace(/^["']|["']$/g, "");
    if (hitsAnyProtectedBasename(nodePath.basename(raw))) return true;
    let resolved = raw;
    if (raw.includes("$") || raw.includes("~")) {
      const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
      if (expanded !== null) resolved = expanded;
    }
    if (hitsAnyProtectedBasename(nodePath.basename(resolved))) return true;
    try {
      // No case-folding here: this is a DETECTION test (block direction) and
      // PROTECTED_MARKER_BASENAME_RE already carries the `i` flag, so folding
      // added nothing and only obscured that the two directions differ (#1780 H-3).
      const n = realResolve(resolved);
      if (hitsAnyProtectedBasename(nodePath.basename(n))) return true;
    } catch (_) { /* unresolvable — lexical checks above already covered */ }
    return false;
  });
}

module.exports = {
  PROTECTED_MARKER_BASENAME_RE,
  areAllBashTargetsUnderWorkflowDir,
  bashTargetsHitProtectedMarker,
};
