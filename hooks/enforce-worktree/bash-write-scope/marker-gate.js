"use strict";

const { expandStaticShellTokens } = require("../../lib/bash-write-targets/helpers");
const {
  PROTECTED_MARKER_BASENAME_RE,
  hitsProtectedMarkerBasename,
  hitsTokenBasename,
} = require("../../lib/protected-basenames");

// Session markers and OFF-clearance tokens are symmetric members of one
// protected-basename class (CPR-ORTH); both are consulted together everywhere a
// write is being detected, so the pairing is written once here. `opts` carries
// `{ sessionCtx }` out of the hook's stdin (#2108) — a basename only confers
// clearance when its stem is an effective session id, and only stdin knows it.
function hitsAnyProtectedBasename(basename, opts) {
  return hitsProtectedMarkerBasename(basename, opts) || hitsTokenBasename(basename, opts);
}
const { isContainedUnder, normalizeTarget } = require("./target-normalize");
const { realResolve } = require("./realpath-resolve");

// The workflow-dir allow fast-path approves every write beneath the workflow dir,
// including the session-marker files that gate clearance (session-markers.js
// authorizes purely on a marker's existence) — without this exclusion a bare
// `echo x > <sid>.workflow-off` would forge full clearance state.
//
// Defence in depth only: enforce-worktree.js is a worktree-LOCATION guard, so a
// linked worktree on a feature branch still allows. Marker integrity is enforced
// primarily by hooks/block-clearance-token-write.js; both read the same SSOT,
// hooks/lib/protected-basenames.js, so the two can never diverge (CPR-SSOT).

function areAllBashTargetsUnderWorkflowDir(targets, opts) {
  if (!targets || targets.length === 0) return false;
  const sessionCtx = opts && opts.sessionCtx;
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
      // Both the lexical basename and the realpath'd one are tested: a two-step
      // symlink indirection (`ln -s <wf>/<sid>.workflow-off lnk`) never matches
      // the marker rule on its own path, so only the realpath'd form fails it
      // closed. `resolved` still carries the raw glob metachars and trailing
      // whitespace-dots (the real shell resolves those at execution time), so
      // both forms are normalized before testing — same treatment as
      // hooks/block-clearance-token-write.js (CPR-ORTH). The OFF-clearance token
      // shares this directory and grants the same clearance, so it is excluded
      // on identical grounds; the sanctioned mint route writes it from a
      // subprocess no PreToolUse hook sees, so nothing legitimate loses its allow.
      if (hitsAnyProtectedBasename(nodePath.basename(resolved), { sessionCtx })) return false;
      if (hitsAnyProtectedBasename(nodePath.basename(n), { sessionCtx })) return false;
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
function bashTargetsHitProtectedMarker(targets, opts) {
  if (!targets || targets.length === 0) return false;
  const nodePath = require("path");
  const sessionCtx = opts && opts.sessionCtx;
  return targets.some((rawT) => {
    const t = normalizeTarget(rawT);
    // This predicate runs in the DETECTION direction — `true` means "skip
    // every allow fast-path" — so a target the normalizer couldn't make sense
    // of must NOT be waved through. Its sibling above (the permission
    // direction) answers `false` on malformed for the same "cannot vouch"
    // reason, just inverted: `false` there, `true` here.
    if (t.malformed === true) return true;
    const raw = String(t.path).replace(/^["']|["']$/g, "");
    if (hitsAnyProtectedBasename(nodePath.basename(raw), { sessionCtx })) return true;
    let resolved = raw;
    if (raw.includes("$") || raw.includes("~")) {
      const expanded = expandStaticShellTokens(raw, { fromQuotedContext: "unquoted" });
      if (expanded !== null) resolved = expanded;
    }
    if (hitsAnyProtectedBasename(nodePath.basename(resolved), { sessionCtx })) return true;
    try {
      // No case-folding here: this is a DETECTION test and the marker regex
      // already carries the `i` flag, so folding would add nothing.
      const n = realResolve(resolved);
      if (hitsAnyProtectedBasename(nodePath.basename(n), { sessionCtx })) return true;
    } catch (_) { /* unresolvable — lexical checks above already covered */ }
    return false;
  });
}

module.exports = {
  PROTECTED_MARKER_BASENAME_RE,
  areAllBashTargetsUnderWorkflowDir,
  bashTargetsHitProtectedMarker,
};
