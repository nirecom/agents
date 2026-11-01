"use strict";
// bin/lib/glossary-drift/context.js — the line and word contexts of the drift check: heading
// lines (table header rows included), fixed-format lines, identifier chunks and capital words.
// Matching rules SSOT: docs/architecture/claude-code/glossary-check.md#matching-rules.

const HEADING_RE = /^\s{0,3}#{1,6}\s/;
const TABLE_SEPARATOR_RE = /^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/;
// A line whose whole content is identifier context; add a fixed format here only.
const FIXED_FORMAT_LINE_RE = /^\s*(?:#{1,6}\s+)?Tags:/;
const IDENT_CHAR_RE = /[_=${}]/;
const CAPS_WORD_RE = /^[A-Z][A-Z0-9]+$/;
// A character that continues a word or an identifier: a match next to one is not a whole token.
const BOUNDARY_RE = /[A-Za-z0-9_-]/;

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

// identifierRanges(line) -> [[start, end]] of the identifier chunks: the whitespace-delimited chunks
// holding `_ = $ { }` (the whole of a fixed-format line). One pass over the line.
function identifierRanges(line) {
  if (FIXED_FORMAT_LINE_RE.test(line)) return [[0, line.length]];
  const out = [];
  const re = /\S+/g;
  let m;
  while ((m = re.exec(line)) !== null) if (IDENT_CHAR_RE.test(m[0])) out.push([m.index, m.index + m[0].length]);
  return out;
}

const isBoundary = (ch) => ch !== "" && BOUNDARY_RE.test(ch);

// declaredRanges(line, spellings) -> [[start, end]] of the literal whole-token occurrences of the
// declared Identifier spellings.
function declaredRanges(line, spellings) {
  const out = [];
  for (const s of spellings || []) {
    if (!s) continue;
    for (let at = line.indexOf(s); at !== -1; at = line.indexOf(s, at + 1)) {
      if (!isBoundary(at > 0 ? line.charAt(at - 1) : "") && !isBoundary(line.charAt(at + s.length))) out.push([at, at + s.length]);
    }
  }
  return out;
}

const isCapsWord = (text) => CAPS_WORD_RE.test(text);

module.exports = { FIXED_FORMAT_LINE_RE, BOUNDARY_RE, headingLines, identifierRanges, declaredRanges, isCapsWord };
