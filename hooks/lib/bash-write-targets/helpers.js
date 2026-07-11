"use strict";

const path = require("path");
const os = require("os");

// True if the token looks like a variable expansion or command substitution
// that we cannot statically resolve.
function isUnresolvableToken(tok) {
  return /[$`]|\$\(|>\(/.test(tok);
}

/**
 * Expand statically resolvable shell variable prefixes in a token.
 * Only expands: $HOME, ${HOME}, ~/..., $WORKFLOW_PLANS_DIR, ${WORKFLOW_PLANS_DIR},
 * and generic $VAR/${VAR} constrained to getWorkflowPlansDir().
 * Only expands at the START of the token (leading position).
 * Returns the expanded string, or the original string if unexpandable.
 * Returns null if the token contains a dollar sign that was NOT expanded (fail-closed).
 *
 * @param {string} s - The token string to expand.
 * @param {object} opts
 *   fromQuotedContext: "double" | "unquoted"
 */
function expandStaticShellTokens(s, opts = {}) {
  const { fromQuotedContext = "unquoted" } = opts;

  // Normalize Windows backslash paths to forward slashes for consistent matching
  // and output. os.homedir() returns backslashes on Windows; downstream callers
  // (path.resolve, hook regex matching) treat / and \ interchangeably on Windows
  // but tests expect forward-slash output.
  const homeDir = os.homedir().replace(/\\/g, "/");

  // Tilde expansion: only in unquoted context (not inside double-quotes)
  if (fromQuotedContext === "unquoted" && (s === "~" || s.startsWith("~/") || s.startsWith("~\\"))) {
    const remainder = s.slice(1);
    if (remainder.includes("$") || remainder.includes("`")) return null;
    return homeDir + remainder;
  }

  // $HOME or ${HOME} — expand in both double-quoted and unquoted contexts.
  // Use alternation to enforce balanced braces: $HOME or ${HOME} only.
  const homeRe = /^\$(?:\{HOME\}|HOME)(?=\/|\\|$)/;
  if (homeRe.test(s)) {
    const remainder = s.replace(homeRe, "");
    if (remainder.includes("$") || remainder.includes("`")) return null;
    return homeDir + remainder;
  }

  // $WORKFLOW_PLANS_DIR or ${WORKFLOW_PLANS_DIR} — expand only when env var is defined and non-empty.
  const wpRe = /^\$(?:\{WORKFLOW_PLANS_DIR\}|WORKFLOW_PLANS_DIR)(?=\/|\\|$)/;
  if (wpRe.test(s)) {
    const wpd = process.env.WORKFLOW_PLANS_DIR;
    if (!wpd) return null; // fail-closed: unset or empty → cannot resolve
    const remainder = s.replace(wpRe, "");
    if (remainder.includes("$") || remainder.includes("`")) return null;
    return wpd + remainder;
  }

  // Generic $VAR / ${VAR} — resolve via process.env when env value AND the final
  // resolved path (envValue + remainder) are both under getWorkflowPlansDir().
  // The regex captures the identifier head only; any subsequent character (.tmp, /sub,
  // end-of-string) becomes the remainder appended after expansion.
  // This covers $state_path.tmp, $state_path/sub, and bare $state_path forms (#983).
  const genericVarRe = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/;
  const gm = genericVarRe.exec(s);
  if (gm) {
    const varName = gm[1] || gm[2];
    const remainder = s.slice(gm[0].length);
    if (!remainder.includes("$") && !remainder.includes("`")) {
      const resolved = tryResolveEnvUnderPlansDir(varName, remainder);
      if (resolved !== null) return resolved;
    }
  }

  // If the token still starts with $ (or contains $ not at a known expansion), fail-closed.
  if (s.includes("$")) return null;

  return s;
}

/**
 * Resolve a raw (pre-strip) token to a filesystem path, deciding the quote
 * context from the raw form itself. Returns the expanded path string, or null
 * (fail-closed) when the token is unresolvable / dangerous.
 *
 * Decision order (see detail plan §Section E):
 *   1. null/empty → null
 *   2. backtick / $( / >( / ( prefix → null (command/process substitution)
 *   3. $'...' ANSI-C prefix → null (fail-closed)
 *   4. simple single-quoted → literal content, no expansion
 *   5. simple double-quoted → strip outer quotes; \$ inside → null; else expand (double ctx)
 *   6. mixed (contains a quote but neither simple form) → null (fail-closed)
 *   7. unquoted → expandStaticShellTokens (unquoted ctx)
 */
function expandRawToken(rawTok) {
  if (rawTok == null || rawTok === "") return null;
  if (rawTok.includes("`") || rawTok.includes("$(") || rawTok.startsWith(">(") || rawTok.startsWith("(")) return null;
  if (rawTok.startsWith("$'")) return null; // ANSI-C quoting — fail-closed

  // Simple single-quoted: literal, never expand.
  if (rawTok.startsWith("'") && rawTok.endsWith("'") && rawTok.length >= 2) {
    return rawTok.slice(1, -1);
  }

  // Simple double-quoted.
  if (rawTok.startsWith('"') && rawTok.endsWith('"') && rawTok.length >= 2) {
    const content = rawTok.slice(1, -1);
    if (content.includes("\\$")) return null; // escaped $ → literal, fail-closed
    return expandStaticShellTokens(content, { fromQuotedContext: "double" });
  }

  // Mixed quoting (contains a quote char but not a simple single/double form).
  if (rawTok.includes("'") || rawTok.includes('"')) return null;

  // Unquoted.
  return expandStaticShellTokens(rawTok, { fromQuotedContext: "unquoted" });
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

module.exports = { isUnresolvableToken, tryResolveEnvUnderPlansDir, expandStaticShellTokens, expandRawToken };
