"use strict";
// FROZEN FIXTURE — verbatim copy of hasUnclosedQuote() from
// hooks/lib/command-ir.js as of PR #1577 (pre-#1569 quote-spans refactor).
// Do NOT edit. Used by tests/unit-quote-spans-differential.sh as the
// old-implementation side of the old-vs-new differential comparison.
function hasUnclosedQuote(str) {
  let inDouble = false;
  let inSingle = false;
  let i = 0;
  const n = str.length;
  while (i < n) {
    const ch = str[i];
    if (inDouble) {
      if (ch === "\\" && i + 1 < n) { i += 2; continue; }
      if (ch === '"') { inDouble = false; }
      i++;
    } else if (inSingle) {
      if (ch === "'") { inSingle = false; }
      i++;
    } else {
      if (ch === '"') { inDouble = true; i++; }
      else if (ch === '$' && i + 1 < n && str[i + 1] === "'") {
        // ANSI-C quoting: $'...' — skip without setting inSingle
        i += 2; // skip $ and opening '
        let closed = false;
        while (i < n) {
          const ac = str[i];
          if (ac === '\\' && i + 1 < n) { i += 2; continue; }
          if (ac === "'") { i++; closed = true; break; }
          i++;
        }
        if (!closed) return true; // fail-closed: unclosed ANSI-C quote
      } else if (ch === '\\' && i + 1 < n) { i += 2; } // backslash-escape in unquoted context
      else if (ch === "'") { inSingle = true; i++; }
      else { i++; }
    }
  }
  return inDouble || inSingle;
}

module.exports = { hasUnclosedQuote };
