"use strict";
// bin/lib/glossary-drift/context.js — the line and word contexts of the drift check: heading
// lines (table header rows included), fixed-format lines, identifier chunks and capital words.
// Matching rules SSOT: docs/architecture/claude-code/glossary-check.md#matching-rules.

const HEADING_RE = /^\s{0,3}#{1,6}\s/;
const TABLE_SEPARATOR_RE = /^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/;
// A line whose whole content is identifier context; add a fixed format here only.
const FIXED_FORMAT_LINE_RE = /^\s*(?:#{1,6}\s+)?Tags:/;
const IDENT_CHUNK_RE = /\S*[_=${}]\S*/g;
const CAPS_WORD_RE = /^[A-Z][A-Z0-9]+$/;

// headingLines(lines) -> the 0-based indexes of the heading lines and the table header rows.
function headingLines(lines) {
  const out = new Set();
  lines.forEach((line, i) => {
    const next = lines[i + 1];
    const tableHeader = line.includes("|") && next !== undefined && next.includes("|") && TABLE_SEPARATOR_RE.test(next);
    if (HEADING_RE.test(line) || tableHeader) out.add(i);
  });
  return out;
}

// identifierRanges(line) -> [[start, end]] of the identifier chunks (the whole of a fixed-format line).
function identifierRanges(line) {
  if (FIXED_FORMAT_LINE_RE.test(line)) return [[0, line.length]];
  const out = [];
  let m;
  IDENT_CHUNK_RE.lastIndex = 0;
  while ((m = IDENT_CHUNK_RE.exec(line)) !== null) out.push([m.index, m.index + m[0].length]);
  return out;
}

const isCapsWord = (text) => CAPS_WORD_RE.test(text);

module.exports = { FIXED_FORMAT_LINE_RE, headingLines, identifierRanges, isCapsWord };
