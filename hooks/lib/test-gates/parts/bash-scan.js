"use strict";
// Line scanners of bash source shared by the bash reader and embed parts (#2507 D7; ports
// _trp_scan_line, _trp_heredoc_term and the file read of bin/lib/test-retire-predicate/case-parser.sh).

const S = require("../source");

const COMMENT_PREV = /[ \t\n\v\f\r;&|()]/;

// fileLines(file) — the lines `while IFS= read -r line || [[ -n $line ]]` reads; null when absent.
function fileLines(file) {
  let text;
  try {
    if (!S.isFile(file)) return null;
    text = S.textOf(file).replace(/\0/g, "");
  } catch {
    return null;
  }
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

// scanLine(s) -> { code, open }: the line minus its unquoted comment, and whether it ends in a quote.
function scanLine(s) {
  let prev = " ";
  let state = 0;
  let code = s;
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (state === 0) {
      if (c === "\\") i += 1;
      else if (c === "'") state = 1;
      else if (c === '"') state = 2;
      else if (c === "#" && COMMENT_PREV.test(prev)) {
        code = s.slice(0, i);
        break;
      }
    } else if (state === 1) {
      if (c === "'") state = 0;
    } else if (c === "\\") i += 1;
    else if (c === '"') state = 0;
    prev = c;
  }
  return { code, open: state !== 0 };
}

const RE_HD = /^(-?)[ \t\n\v\f\r]*('([^']*)'|"([^"]*)"|\\?([^ \t\n\v\f\r;&|<>()'"]+))/;

// heredocTerm(s) -> { term, strip } of the last heredoc the line opens, or null.
function heredocTerm(s) {
  if (!s.includes("<<")) return null;
  let prev = " ";
  let state = 0;
  let arith = 0;
  let term = "";
  let strip = 0;
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (state === 0) {
      if (c === "\\") i += 1;
      else if (c === "'") state = 1;
      else if (c === '"') state = 2;
      else if (c === "#") {
        if (COMMENT_PREV.test(prev)) break;
      } else if (c === "(") {
        if (s[i + 1] === "(") {
          arith += 1;
          i += 1;
        }
      } else if (c === ")") {
        if (arith > 0 && s[i + 1] === ")") {
          arith -= 1;
          i += 1;
        }
      } else if (c === "<" && arith === 0 && s[i + 1] === "<") {
        if (s[i + 2] === "<") i += 2;
        else {
          const m = RE_HD.exec(s.slice(i + 2));
          if (m) {
            term = `${m[3] || ""}${m[4] || ""}${m[5] || ""}`;
            strip = m[1] ? 1 : 0;
          }
          i += 1;
        }
      }
    } else if (state === 1) {
      if (c === "'") state = 0;
    } else if (c === "\\") i += 1;
    else if (c === '"') state = 0;
    prev = c;
  }
  return term ? { term, strip } : null;
}

// heredocEnds(line, hd) — the line closes the heredoc (leading blanks cut for `<<-`).
function heredocEnds(line, hd) {
  const chk = hd.strip ? line.replace(/^[ \t]+/, "") : line;
  return chk === hd.term;
}

module.exports = { fileLines, scanLine, heredocTerm, heredocEnds };
