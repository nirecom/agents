"use strict";
// Extracts the destination output path from a shell command that invokes
// skills/_shared/assemble-mandatory.sh. Returns the resolved 3rd positional
// after any optional --source-kind switch, or null when the command does
// not invoke the script or has no parseable destination.
//
// Backslash line continuation: SKILL.md authors split the invocation across
// 4 lines using POSIX `\<newline>` continuation. Claude Code may record the
// command either as the literal multi-line string (preserving the `\`s) or
// as the shell-collapsed single-line form. We normalize the former by
// joining continuation lines before tokenizing.

const SCRIPT_NAME = "assemble-mandatory.sh";

// Join POSIX backslash-continuation lines: a backslash at end-of-line
// (optionally followed by trailing whitespace before the newline) plus the
// newline (LF or CRLF) collapses to a single space.
function joinContinuations(s) {
  return s.replace(/\\[ \t]*\r?\n[ \t]*/g, " ");
}

function tokenize(s) {
  // Minimal POSIX-like tokenizer: splits on whitespace honoring single/double
  // quotes. Backslash-escapes inside paths (e.g. Windows `C:\foo`) are kept
  // literal — continuation backslashes have already been removed by
  // joinContinuations.
  const out = [];
  let cur = "";
  let q = null; // '\'' or '"' or null
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q) { q = null; continue; }
      cur += c;
    } else if (c === '"' || c === "'") {
      q = c;
    } else if (/\s/.test(c)) {
      if (cur) { out.push(cur); cur = ""; }
    } else {
      cur += c;
    }
  }
  if (cur) out.push(cur);
  return out;
}

function extractAssembleDest(cmd) {
  if (typeof cmd !== "string" || cmd.length === 0) return null;
  if (cmd.indexOf(SCRIPT_NAME) === -1) return null;
  const joined = joinContinuations(cmd);
  const tokens = tokenize(joined);
  // Find the token whose basename is the script name.
  let i = 0;
  for (; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.endsWith("/" + SCRIPT_NAME) || t.endsWith("\\" + SCRIPT_NAME) || t === SCRIPT_NAME) break;
  }
  if (i >= tokens.length) return null;
  // Consume args after the script token.
  let j = i + 1;
  // Optional --source-kind <kind>
  if (tokens[j] === "--source-kind") j += 2;
  // Need 3 positionals: source, planner-out, out
  if (j + 2 >= tokens.length) return null;
  const dest = tokens[j + 2];
  // Defensive: reject lone backslash (would indicate continuation handling
  // failed), shell separators, and flag-looking tokens.
  if (!dest || dest === "\\" || dest.startsWith("-") || dest === "&&" || dest === "||" || dest === ";") return null;
  return dest;
}

module.exports = { extractAssembleDest, tokenize, joinContinuations };
