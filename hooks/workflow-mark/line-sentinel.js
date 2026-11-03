"use strict";
// hasLineSentinel(command) — true when a statement of a multi-statement script is a sentinel
// echo (#1981). The script is cut at newlines and `;` outside quotes; `#` comments are dropped,
// and a leading `then` / `else` / `do` is stripped. A sentinel line inside a quoted argument is
// not a statement. Recognition stays with isSentinel (sentinel-patterns.js, unchanged).

const { isSentinel } = require("../lib/sentinel-patterns");

const LEAD_KEYWORD_RE = /^(?:then|else|do)\s+/;

// statementsOf(command) -> the top-level statements, quotes kept, comments removed.
function statementsOf(command) {
  const out = [];
  let cur = "";
  let quote = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      cur += ch;
      if (quote === '"' && ch === "\\" && i + 1 < command.length) cur += command[++i];
      else if (ch === quote) quote = null;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      cur += ch;
    } else if (ch === "\\" && i + 1 < command.length) {
      cur += ch + command[++i];
    } else if (ch === "#" && (cur === "" || /\s$/.test(cur))) {
      while (i + 1 < command.length && command[i + 1] !== "\n") i++;
    } else if (ch === "\n" || ch === ";") {
      out.push(cur);
      cur = "";
    } else {
      cur += ch;
    }
  }
  out.push(cur);
  return out;
}

function hasLineSentinel(command) {
  if (typeof command !== "string" || command === "") return false;
  return statementsOf(command)
    .map((s) => s.trim().replace(LEAD_KEYWORD_RE, "").trim())
    .some((s) => s !== "" && isSentinel(s));
}

module.exports = { hasLineSentinel };
