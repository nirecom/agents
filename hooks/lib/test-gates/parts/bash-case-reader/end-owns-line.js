"use strict";
// _trp_end_owns_line: only case_end's own words follow it — at most one `|| true` /
// `|| <name>=$?` clause plus redirections to a bare word or a quoted string.

const { scanLine } = require("../bash-scan");

const SP = "[ \\t\\n\\v\\f\\r]";
const WORD = `[^ \\t\\n\\v\\f\\r;&|<>()'"$\`\\\\]+`;
const RE_TOK = new RegExp(
  `^${SP}*(\\|\\|${SP}*(true|[A-Za-z_][A-Za-z0-9_]*=\\$\\?)|[0-9]*[<>]&[0-9]+|([0-9]*(>>|>|<)|&>>|&>)${SP}*(${WORD}|"[^"$\`\\\\]*"|'[^']*'))(${SP}|$)`,
);

function endOwnsLine(line) {
  const code = scanLine(line).code;
  let tail = code.startsWith("case_end") ? code.slice("case_end".length) : code;
  let orSeen = false;
  while (/[^ \t\n\v\f\r]/.test(tail)) {
    const m = RE_TOK.exec(tail);
    if (!m) return false;
    if (m[1].startsWith("||")) {
      if (orSeen) return false;
      orSeen = true;
    }
    tail = tail.slice(m[0].length);
  }
  return true;
}

module.exports = { endOwnsLine };
