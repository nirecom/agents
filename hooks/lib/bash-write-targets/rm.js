"use strict";

const { isUnresolvableToken } = require("./helpers");

/**
 * Quote-aware tokenizer for `rm` argument regions.
 *
 * - Double-quoted tokens: literal content; `$` and backtick inside fail-closed
 *   (unresolvable shell expansion). Backslash escapes (\" etc.) are NOT
 *   implemented (accepted constraint).
 * - Single-quoted tokens: fully literal content, no substitutions.
 * - Unquoted tokens: read until whitespace.
 *
 * Returns: string[] (token array) on success, null on parse failure
 *   (unterminated quote or shell-expansion sigil inside double-quotes).
 */
function tokenizeRmArgs(argsRegion) {
  const tokens = [];
  let i = 0;
  const s = argsRegion;
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++;
    if (i >= s.length) break;
    const ch = s[i];
    if (ch === '"') {
      let content = "";
      let j = i + 1;
      while (j < s.length && s[j] !== '"') {
        // Backtick anywhere inside double-quotes → command substitution, fail-closed.
        if (s[j] === "`") return null;
        if (s[j] === "$") {
          // Resolve ONLY the simple `$VAR` form (optionally followed by a
          // literal `/suffix`). Everything else (${VAR}, $(...), mixed
          // pre$VAR / $VAR$X) fails closed.
          const rest = s.slice(j);
          const vm = rest.match(/^\$([A-Za-z_][A-Za-z0-9_]*)/);
          if (!vm) return null; // ${VAR}, $(...), $1, bare $, etc.
          const varName = vm[1];
          let k = j + vm[0].length; // index just past the var name
          // Collect an optional literal suffix up to the closing quote.
          // The suffix must contain no further $ or backtick (no mixed forms).
          let suffix = "";
          while (k < s.length && s[k] !== '"') {
            if (s[k] === "$" || s[k] === "`") return null;
            suffix += s[k++];
          }
          if (k >= s.length) return null; // unterminated quote
          // Suffix, if present, must start with `/` (accept `$VAR/literal/path`).
          if (suffix !== "" && suffix[0] !== "/") return null;
          const val = process.env[varName];
          if (val === undefined || val === "") return null; // undefined/empty → fail-closed
          // Reject resolved values carrying shell-meta — they would word-split
          // or glob-expand at shell runtime, defeating single-target analysis.
          if (/[\s*?[\]{}$`]/.test(val)) return null;
          content += val + suffix;
          j = k; // loop sees closing quote next and terminates
          continue;
        }
        content += s[j++];
      }
      if (j >= s.length) return null;
      tokens.push(content);
      i = j + 1;
    } else if (ch === "'") {
      let content = "";
      let j = i + 1;
      while (j < s.length && s[j] !== "'") content += s[j++];
      if (j >= s.length) return null;
      tokens.push(content);
      i = j + 1;
    } else {
      let content = "";
      let j = i;
      while (j < s.length && !/\s/.test(s[j])) content += s[j++];
      tokens.push(content);
      i = j;
    }
  }
  return tokens;
}

/**
 * Extract POSIX rm targets from a shell command string.
 *
 * rm [flags] path... — returns all positional (non-flag) args.
 * Flags handled: short bundles (-rf, -fr, -i, -v, ...), long flags
 *   (--recursive, --force, --interactive, --verbose, --one-file-system,
 *   --no-preserve-root, --preserve-root, --dir, -d), and `--` end-of-flags.
 *
 * Relative paths are returned verbatim; the caller (findRepoRoot →
 * path.resolve) resolves them against process.cwd().
 *
 * Quote handling: delegated to tokenizeRmArgs (quote-aware). Double-quoted
 *   tokens with `$` or backtick fail-closed; unterminated quotes fail-closed.
 *
 * Returns: string[] on success (may be empty if no positionals), null on
 *   parse failure (unresolvable token via $VAR / $(...) / backticks, OR
 *   unterminated quote, OR shell expansion sigil inside double-quotes).
 */
function extractRmTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  const RE = /(?:^|[\s;|&])rm\b(.*?)(?:$|[;|&](?:[^|&]|$))/s;
  const m = RE.exec(cmd);
  if (!m) return null;

  const tokens = tokenizeRmArgs(m[1]);
  if (tokens === null) return null;

  const positionals = [];
  let sawDashDash = false;
  for (const t of tokens) {
    if (!sawDashDash && isUnresolvableToken(t)) return null;
    if (!sawDashDash && t === "--") { sawDashDash = true; continue; }
    if (!sawDashDash && t.startsWith("-")) continue;
    if (t === "") continue;
    positionals.push(t);
  }
  return positionals;
}

module.exports = { extractRmTargets };
