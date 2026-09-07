"use strict";
// hooks/lib/command-ir/scan.js — quote-aware occurrence scan for shell operators.
//
// Substitutions, brace groups and output redirects are recognised on the TEXT, not
// on tokens: `echo "<<MARK>>"` and `echo '{ ls; }'` tokenize into shapes the legacy
// redirect matcher misreads, and only a scan that knows quoting can say the
// characters were never operators. Single quotes disable everything; double quotes
// disable `<<`, `{`, `>` but NOT `$(` or a backtick, which still execute.

// A `{` opens a brace GROUP only in command position and only when a blank follows
// it — `find ... -exec rm {} \;` is neither.
const CMD_POSITION_BEFORE = new Set(["", ";", "&", "|", "(", ")", "\n", "{", "}"]);

function prevSignificant(text, i) {
  let k = i - 1;
  while (k >= 0 && (text[k] === " " || text[k] === "\t")) k--;
  return k < 0 ? "" : text[k];
}

/**
 * Scan `text` for unquoted operator occurrences.
 *
 * @returns {{substitutions: object[], groups: object[], redirects: object[]}}
 *          substitution kinds are "cmd-subst" (`$(`) and "backtick".
 */
function scanOperators(text) {
  const substitutions = [];
  const groups = [];
  const redirects = [];
  if (typeof text !== "string" || text === "") return { substitutions, groups, redirects };

  const n = text.length;
  let i = 0;
  let inDq = false;
  while (i < n) {
    const ch = text[i];
    if (ch === "\\") { i += 2; continue; }
    if (!inDq && ch === "'") {
      i++;
      while (i < n && text[i] !== "'") i++;
      i++;
      continue;
    }
    if (ch === '"') { inDq = !inDq; i++; continue; }
    // `$((` opens an ARITHMETIC expansion: it evaluates numbers and runs no command,
    // so recording it as `$(` made `echo $((1+2))` read as a command substitution.
    if (ch === "$" && text[i + 1] === "(" && text[i + 2] === "(") {
      i += 3;
      continue;
    }
    if (ch === "$" && text[i + 1] === "(") {
      substitutions.push({ kind: "cmd-subst", index: i, text: "$(" });
      i += 2;
      continue;
    }
    if (ch === "`") {
      substitutions.push({ kind: "backtick", index: i, text: "`" });
      i++;
      continue;
    }
    if (!inDq && ch === "{" && CMD_POSITION_BEFORE.has(prevSignificant(text, i)) && /[ \t\n]/.test(text[i + 1] || "")) {
      groups.push({ index: i, text: "{" });
      i++;
      continue;
    }
    if (!inDq && ch === ">") {
      if (text[i + 1] === ">") {
        redirects.push({ kind: "append", index: i, text: ">>" });
        i += 2;
      } else {
        redirects.push({ kind: "out", index: i, text: ">" });
        i++;
      }
      continue;
    }
    i++;
  }
  return { substitutions, groups, redirects };
}

module.exports = { scanOperators };
