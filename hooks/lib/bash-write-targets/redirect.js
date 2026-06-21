"use strict";

const os = require("os");

/**
 * Expand statically resolvable shell variable prefixes in a redirect target token.
 * Only expands: $HOME, ${HOME}, ~/..., $WORKFLOW_PLANS_DIR, ${WORKFLOW_PLANS_DIR}.
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
      const { tryResolveEnvUnderPlansDir } = require("./helpers");
      const resolved = tryResolveEnvUnderPlansDir(varName, remainder);
      if (resolved !== null) return resolved;
    }
  }

  // If the token still starts with $ (or contains $ not at a known expansion), fail-closed.
  if (s.includes("$")) return null;

  return s;
}

// Pad quoted string CONTENT with null bytes to preserve string length while
// neutralising any shell operators (>, $, etc.) that appear inside quotes.
// This lets the redirect-operator regex run on the padded string and produce
// character positions that are identical to those in the original string.
function padQuotedSegments(str) {
  return str
    .replace(/"(?:[^"\\]|\\.)*"/g, (m) => '"' + "\0".repeat(m.length - 2) + '"')
    .replace(/'[^']*'/g, (m) => "'" + "\0".repeat(m.length - 2) + "'");
}

// Read a redirect target token from the ORIGINAL cmd starting at position i.
// Returns { target: string|null, end: number } or null (parse failure).
function readTargetAt(cmd, i) {
  if (i >= cmd.length) return { target: null, end: i };
  const ch = cmd[i];
  if (ch === "(") return null;                       // process substitution
  if (ch === "`") return null;                       // command substitution
  if (ch === '"') {
    let content = "", j = i + 1;
    let hadEscapedDollar = false;
    while (j < cmd.length && cmd[j] !== '"') {
      if (cmd[j] === "`") return null;              // command substitution inside double-quotes
      if (cmd[j] === "\\" && j + 1 < cmd.length) {
        if (cmd[j + 1] === "$") hadEscapedDollar = true;
        content += cmd[j + 1]; j += 2;
      } else {
        content += cmd[j++];
      }
    }
    // If a backslash-escaped \$ was encountered, the resulting content contains a literal $
    // that must NOT be expanded (the user explicitly escaped it). Fail-closed.
    if (hadEscapedDollar && content.includes("$")) return null;
    const expanded = expandStaticShellTokens(content, { fromQuotedContext: "double" });
    if (expanded === null) return null;
    return { target: expanded, end: j + 1 };
  }
  if (ch === "'") {
    let content = "", j = i + 1;
    while (j < cmd.length && cmd[j] !== "'") content += cmd[j++];
    // Single-quoted strings: NEVER expand — return literal content as-is.
    return { target: content, end: j + 1 };
  }
  // Unquoted token: read until whitespace or shell delimiter.
  // Allow $ to accumulate and attempt static expansion via expandStaticShellTokens.
  let content = "", j = i;
  while (j < cmd.length && !/[\s;|&]/.test(cmd[j])) {
    const c = cmd[j];
    if (c === "`" || c === "(") return null;        // command/process substitution — fail-closed
    content += c; j++;
  }
  if (!content) return { target: null, end: j };
  const expanded = expandStaticShellTokens(content, { fromQuotedContext: "unquoted" });
  if (expanded === null) return null;
  return { target: expanded, end: j };
}

/**
 * Extract POSIX redirect write targets from a shell command string.
 *
 * Handles: > file, >> file, N> file, N>> file, &> file
 * Skips:   FD-to-FD redirects (2>&1, 1>&2), /dev/null sinks, quoted paths preserved
 * Returns: string[] on success, null on parse failure (unresolvable token).
 */
function extractRedirectTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  // Detect redirect operators on the padded string (avoids false positives inside quotes).
  // Positions in padded == positions in original because quotes are padded to same length.
  const padded = padQuotedSegments(cmd);
  // \s* is required: both "> file" and ">file" are valid shell syntax.
  const OPRE = /(?:^|[\s;|])(?:\d*)(?:&>>?|>>?)(?!>|\d)\s*/g;

  const targets = [];
  let m;
  while ((m = OPRE.exec(padded)) !== null) {
    const targetStart = m.index + m[0].length;
    const result = readTargetAt(cmd, targetStart);
    if (result === null) return null;                     // parse failure
    const { target } = result;
    if (target === null) continue;
    if (/^&\d/.test(target)) continue;                   // FD-to-FD (e.g. &1)
    if (target === "/dev/null" || target.endsWith("/dev/null")) continue; // null-sink
    targets.push(target);
  }
  return targets;
}

module.exports = { extractRedirectTargets };
