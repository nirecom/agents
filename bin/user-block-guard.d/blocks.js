"use strict";
// `<user>` block extraction and comparison (#2940). Only CRLF/CR -> LF precedes the comparison.

const TAG_RE = /<user\b[^>]*>|<\/user\s*>/gi;
const CLOSE_RE = /^<\/user\s*>$/i;

function extractBlocks(text) {
  const src = String(text == null ? "" : text).replace(/\r\n?/g, "\n");
  const blocks = [];
  let depth = 0;
  let start = -1;
  for (const m of src.matchAll(TAG_RE)) {
    if (CLOSE_RE.test(m[0])) {
      if (depth === 0) continue;
      depth -= 1;
      if (depth === 0) blocks.push(src.slice(start, m.index + m[0].length));
    } else {
      if (depth === 0) start = m.index;
      depth += 1;
    }
  }
  if (depth > 0) blocks.push(src.slice(start));
  return blocks;
}

// -> "equal" | "added" | "changed"; more blocks in next is "added" even when another one changed.
function compareBlocks(oldBlocks, newBlocks) {
  if (newBlocks.length > oldBlocks.length) return "added";
  if (newBlocks.length === oldBlocks.length && newBlocks.every((b, i) => b === oldBlocks[i])) return "equal";
  return "changed";
}

const hasBlock = (text) => extractBlocks(text).length > 0;

module.exports = { extractBlocks, compareBlocks, hasBlock };
