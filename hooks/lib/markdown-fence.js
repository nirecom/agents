"use strict";
// hooks/lib/markdown-fence.js — the fenced-code-block state of one Markdown line scan (#2529),
// shared by the glossary drift check, the glossary entry parser and the intent Glossary check.
// CommonMark fence rules: an opener is 3+ backticks or 3+ tildes (a backtick opener's info
// string holds no backtick); the closer uses the same character, is at least as long and has
// nothing after it but whitespace. The other delimiter inside a fence is content. Leading
// indentation is accepted at any depth, so a fence nested in a list item counts too.

const OPEN_RE = /^\s*(`{3,}|~{3,})(.*)$/;
const CLOSE_RE = /^\s*(`{3,}|~{3,})\s*$/;

// fenceStep(line, fence) -> { fence, marker }: fence is the open delimiter after this line
// (null outside a fence); marker is true when this line opens or closes a fence.
function fenceStep(line, fence) {
  const s = typeof line === "string" ? line : "";
  if (fence) {
    const close = CLOSE_RE.exec(s);
    if (close && close[1][0] === fence[0] && close[1].length >= fence.length) return { fence: null, marker: true };
    return { fence, marker: false };
  }
  const open = OPEN_RE.exec(s);
  if (open && !(open[1][0] === "`" && open[2].includes("`"))) return { fence: open[1], marker: true };
  return { fence: null, marker: false };
}

module.exports = { fenceStep };
