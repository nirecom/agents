"use strict";
// FROZEN FIXTURE — verbatim copy of foldDqNewlines() from
// hooks/enforce-worktree/main-worktree-allows/worker-script.js as of PR #1577
// (pre-#1569 quote-spans refactor). Do NOT edit. Used by
// tests/unit-quote-spans-differential.sh as the old-implementation side.
// Replace only real newlines that are inside DQ spans with a space.
// Preserves $() and backtick verbatim (so the \$\( guard still fires on them).
// Returns the original string on any exception.
function foldDqNewlines(str) {
  try {
    let out = "";
    let i = 0;
    const n = str.length;
    while (i < n) {
      const ch = str[i];
      if (ch !== '"') {
        out += ch;
        i++;
        continue;
      }
      // Inside DQ span — fold literal newlines, keep everything else verbatim
      out += '"';
      i++;
      while (i < n) {
        const c = str[i];
        if (c === "\\" && i + 1 < n) {
          out += c + str[i + 1];
          i += 2;
          continue;
        }
        if (c === '"') {
          out += c;
          i++;
          break;
        }
        if (c === "\r" || c === "\n") {
          out += " ";
          i++;
        } else {
          out += c;
          i++;
        }
      }
    }
    return out;
  } catch (_) {
    return str;
  }
}

module.exports = { foldDqNewlines };
