"use strict";

const path = require("path");
const { normalizeCwd } = require("../../lib/path-normalize");
const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");

/**
 * True when every redirect (>, >>) or tee write target extracted from cmd
 * resolves under the resolved WORKFLOW_PLANS_DIR (default ~/.workflow-plans).
 *
 * Intentionally does NOT call rejectInterpreterAndChaining or hasShellChaining
 * — those rejectors block the documented #933 false-positive shapes (bash -c,
 * heredoc, mkdir && write). Safety is provided by the every-target prefix match.
 *
 * Scope: redirect and tee writes only. rm/mv/cp are excluded because their
 * source locations may reside outside the plans dir even when a destination is
 * inside it. Fail-closed: parseFailure or empty targets → false; no fallback allow.
 */
function isAllowedWorkflowPlansDirWrite(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  void repoRoot; // signature symmetry — plans dir is SSOT-resolved, not repo-relative

  let plansDir;
  try { plansDir = getWorkflowPlansDir(); } catch (e) { return false; }
  if (!plansDir) return false;

  let normPlans;
  try {
    normPlans = path.resolve(normalizeCwd(plansDir) || plansDir).toLowerCase();
  } catch (e) { return false; }
  if (!normPlans) return false;

  // True when a single path token resolves under the plans dir.
  // Strips surrounding quotes (some extractors return "<path>" with quotes intact).
  function isUnderPlans(t) {
    if (!t) return false;
    const raw = String(t).trim().replace(/^["']|["']$/g, "");
    if (!raw) return false;
    let normT;
    try { normT = path.resolve(normalizeCwd(raw) || raw).toLowerCase(); } catch (e) { return false; }
    return (
      normT === normPlans ||
      normT.startsWith(normPlans + path.sep) ||
      normT.startsWith(normPlans + "/")
    );
  }

  // Lazy-require bash-write-targets to avoid load-time circular dependency.
  // rm/mv/cp extractors intentionally excluded — see block comment above.
  const { extractRedirectTargets, extractTeeTargets } = require("../../lib/bash-write-targets");

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

  if (parseFailure) return false; // fail-closed; no fallback allow

  if (targets.length > 0) {
    // Supplement with raw redirect tokens to preserve Windows backslash paths
    // that extractRedirectTargets may strip when unquoting quoted Windows paths.
    const rawRedirectTargets = [];
    const rawRe = /(?:^|[\s;|&])(?:\d*)(?:&>>?|>>?)\s*(?:"([^"]+)"|'([^']+)'|(\S+))/g;
    let m;
    while ((m = rawRe.exec(cmd)) !== null) rawRedirectTargets.push(m[1] || m[2] || m[3]);

    if (rawRedirectTargets.some((t) => t.includes("\\"))) {
      // Windows-form paths detected: use raw redirect targets (unmangled) for
      // redirect-type targets; preserve separately-extracted tee targets as-is.
      // Drop primary targets that collapse (after removing backslashes) to any
      // raw target — these are the mangled redirect targets to discard.
      const teeOnly = targets.filter((t) => {
        const stripped = String(t).replace(/^["']|["']$/g, "");
        const collapsed = stripped.replace(/\\/g, "");
        return !rawRedirectTargets.some((r) => {
          const rStripped = String(r).replace(/^["']|["']$/g, "");
          return rStripped === stripped || rStripped === t ||
                 rStripped.replace(/\\/g, "") === collapsed;
        });
      });
      return rawRedirectTargets.concat(teeOnly).every(isUnderPlans);
    }
    return targets.every(isUnderPlans);
  }

  // No redirect/tee targets in the outer command. Try known opaque-body patterns.

  // bash -c '<body>' — re-parse the inner command for redirect/tee targets only.
  const bashCMatch =
    cmd.match(/^\s*bash\s+-c\s+'((?:[^'])*?)'\s*$/) ||
    cmd.match(/^\s*bash\s+-c\s+"((?:[^"\\]|\\.)*)"\s*$/);
  if (bashCMatch) {
    const inner = bashCMatch[1];
    const innerTargets = [];
    let innerFail = false;
    if (/(?:^|[\s;|&])(?:\d*)(?:&>>?|>>?)(?!>|\d)/.test(inner)) {
      const r = extractRedirectTargets(inner);
      if (r === null) innerFail = true; else innerTargets.push(...r);
    }
    if (/(?:^|[\s;|&])tee\b/.test(inner)) {
      const t = extractTeeTargets(inner);
      if (t === null) innerFail = true; else innerTargets.push(...t);
    }
    if (innerFail || innerTargets.length === 0) return false;
    return innerTargets.every(isUnderPlans);
  }

  // node -e '<script>' — scan for literal path args in fs write API calls only.
  // Non-literal paths (variables, template literals) produce zero matches → fail-closed.
  const nodeEMatch =
    cmd.match(/^\s*node\s+(?:-e|--eval)\s+"((?:[^"\\]|\\.)*)"\s*$/) ||
    cmd.match(/^\s*node\s+(?:-e|--eval)\s+'((?:[^'])*?)'\s*$/);
  if (nodeEMatch) {
    const script = nodeEMatch[1];
    const writePaths = [];
    let m;
    const reSQ = /(?:writeFileSync|appendFileSync|writeFile)\s*\(\s*'([^']+)'/g;
    const reDQ = /(?:writeFileSync|appendFileSync|writeFile)\s*\(\s*"([^"]+)"/g;
    while ((m = reSQ.exec(script)) !== null) writePaths.push(m[1]);
    while ((m = reDQ.exec(script)) !== null) writePaths.push(m[1]);
    if (writePaths.length === 0) return false;
    return writePaths.every(isUnderPlans);
  }

  return false;
}

module.exports = { isAllowedWorkflowPlansDirWrite };
