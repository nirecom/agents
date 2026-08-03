"use strict";

const { expandStaticShellTokens } = require("../../lib/bash-write-targets/helpers");
const {
  PROTECTED_MARKER_BASENAME_RE,
  hitsProtectedMarkerBasename,
  hitsTokenBasename,
} = require("../../lib/protected-basenames");

// Session markers and OFF-clearance tokens are symmetric members of one
// protected-basename class (CPR-5); both are consulted together everywhere a
// write is being detected, so the pairing is written once here.
function hitsAnyProtectedBasename(basename) {
  return hitsProtectedMarkerBasename(basename) || hitsTokenBasename(basename);
}
const { isContainedUnder, normalizeTarget } = require("./target-normalize");
const { realResolve } = require("./realpath-resolve");

// The workflow-dir allow fast-path approves every write beneath the workflow
// dir, including the session-marker files that gate WORKFLOW_OFF/WORKTREE_OFF
// /issue-close-verified/next-step-paused clearance (session-markers.js
// authorizes purely on a marker's existence). Without this exclusion, a bare
// `echo x > <sid>.workflow-off` would forge full clearance state. Marker
// basenames fall through to normal fail-closed enforcement instead.
//
// This file is defence in depth only — enforce-worktree.js is a
// worktree-LOCATION guard, so a linked worktree on a feature branch still
// allows. Marker integrity is location-independent and is primarily enforced
// by hooks/block-off-clearance-write.js; both read the same protected-basename
// SSOT (hooks/lib/protected-basenames.js) so the two can never diverge (CPR-2).

function areAllBashTargetsUnderWorkflowDir(targets) {
  if (!targets || targets.length === 0) return false;
  try {
    const nodePath = require("path");
    const { getWorkflowDir } = require("../../workflow-state");
    let wfDir;
    try { wfDir = getWorkflowDir(); } catch (_) { return false; }
    if (!wfDir) return false;
    // Containment is decided by isContainedUnder(), which folds case only on a
    // filesystem proven case-insensitive by probe — pre-folding both sides
    // here made `<wf>/State` look contained in `<wf>/state` on a
    // case-sensitive volume, an allow for a path outside the workflow dir.
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
      // A lexical-only marker check misses a two-step symlink indirection
      // (`ln -s <wf>/<sid>.workflow-off <wf>/lnk` then `echo x > lnk`), where
      // the write target's own path never matches the marker regex even
      // though realResolve() follows the symlink to the real marker file.
      // Check both the lexical basename and the realpath'd basename so the
      // indirection fails closed too. `resolved` still carries whatever glob
      // metachars / trailing whitespace-dots the raw command spelled (the
      // real shell resolves these at execution time, before this check runs)
      // so both forms are normalized before testing (CPR-5, same treatment as
      // hooks/block-off-clearance-write.js). The OFF-clearance token lives in
      // this same directory and grants the same clearance, so it's excluded
      // from the allow fast-path on identical grounds — the sanctioned mint
      // route (bin/request-off-clearance) writes it from a subprocess no
      // PreToolUse hook sees, so nothing legitimate loses its allow here.
      if (hitsAnyProtectedBasename(nodePath.basename(resolved))) return false; // fail-closed
      if (hitsAnyProtectedBasename(nodePath.basename(n))) return false; // fail-closed
      // Directory itself is NOT allowed (unlike the plans-dir variant): that keeps
      // `rm -rf <workflowDir>` blocked. Only strict descendants pass.
      return isContainedUnder(n, normWf, { allowEqual: false });
    };
    return targets.every(isUnder);
  } catch (_) {
    return false; // fail-closed
  }
}

// areAllBashTargetsUnderWorkflowDir() is the only function that consults
// PROTECTED_MARKER_BASENAME_RE, but several independent allow fast-paths
// approve a Bash write purely on "target resolves outside session scope" —
// trivially true for the default workflow-dir location — without ever
// calling it, so a marker write can slip through untouched. Rather than
// scatter a marker check into each allow path, this predicate is a single,
// location-independent early gate: true iff any extracted target's basename
// (raw, shell-token-expanded, or realpath'd) hits a protected marker
// basename, regardless of where it resolves. Callers must skip ALL allow
// paths (not just the workflow-dir one) when this returns true.
function bashTargetsHitProtectedMarker(targets) {
  if (!targets || targets.length === 0) return false;
  const nodePath = require("path");
  return targets.some((rawT) => {
    const t = normalizeTarget(rawT);
    // This predicate runs in the DETECTION direction — `true` means "skip
    // every allow fast-path" — so a target the normalizer couldn't make sense
    // of must NOT be waved through. Its sibling above (the permission
    // direction) answers `false` on malformed for the same "cannot vouch"
    // reason, just inverted: `false` there, `true` here.
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
      // No case-folding here: this is a DETECTION test and the marker regex
      // already carries the `i` flag, so folding would add nothing.
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
