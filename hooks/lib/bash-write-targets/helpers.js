"use strict";

const path = require("path");

// True if the token looks like a variable expansion or command substitution
// that we cannot statically resolve.
function isUnresolvableToken(tok) {
  return /[$`]|\$\(|>\(/.test(tok);
}

// Resolve a shell variable name via process.env; accept it ONLY when BOTH the
// env value AND the final resolved path (envValue + remainder) are under
// getWorkflowPlansDir().  Returns the expanded string or null (fail-closed).
//
// Two-step guard prevents path-traversal: $STATE_PATH/../../outside is rejected
// because path.resolve(envVal + remainder) escapes plans-dir even when envVal itself
// is under plans-dir.
function tryResolveEnvUnderPlansDir(varName, remainder) {
  try {
    const { getWorkflowPlansDir } = require("../workflow-plans-dir");
    const envVal = process.env[varName];
    if (!envVal) return null;
    // Reject env values containing whitespace or glob chars: an unquoted $VAR whose
    // value has spaces would be word-split by the shell into multiple arguments,
    // defeating the single-target check.  Plans-dir paths must not contain spaces.
    if (/[\s*?[]/.test(envVal)) return null;

    let plansDir;
    try {
      plansDir = getWorkflowPlansDir();
    } catch (_) {
      return null; // relative WORKFLOW_PLANS_DIR — fail-closed
    }
    if (!plansDir) return null;

    const normPlans = path.resolve(plansDir).toLowerCase();
    const isUnder = (p) => {
      const n = path.resolve(p).toLowerCase();
      return n === normPlans ||
        n.startsWith(normPlans + path.sep) ||
        n.startsWith(normPlans + "/");
    };

    // (a) env value itself must be under plans-dir
    if (!isUnder(envVal)) return null;

    // (b) final resolved path (after appending remainder) must also be under plans-dir.
    // path.resolve collapses .., catching $STATE_PATH/../../outside escapes.
    const candidate = envVal + remainder;
    if (!isUnder(candidate)) return null;

    return candidate;
  } catch (_) {
    return null; // fail-closed on any unexpected error
  }
}

module.exports = { isUnresolvableToken, tryResolveEnvUnderPlansDir };
