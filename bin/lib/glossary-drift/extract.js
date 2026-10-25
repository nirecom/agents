"use strict";
// bin/lib/glossary-drift/extract.js — the excluded contexts of the drift check, as two layers that
// keep the line count and the columns: the prose layer (code spans blanked) and the identifier
// layer (only the code-span contents). Matching rules SSOT:
// docs/architecture/claude-code/glossary-check.md#matching-rules.

const { classifyLines } = require("../../../hooks/lib/comment-block-scan");
const { fenceStep } = require("../../../hooks/lib/markdown-fence");

const EDGE_PUNCT_RE = /^["'([{<]+|["')\]}>,;:!?.]+$/g;
const PATH_EXT_RE = /[A-Za-z0-9_-]\.[A-Za-z][A-Za-z0-9]{0,7}$/;
const CODE_SPAN_RE = /(`+)[^`]*?\1/g;

const spaces = (s) => " ".repeat(s.length);
const blankAll = (s, re) => s.replace(re, spaces);

// Blanks <!-- ... --> (possibly multi-line); returns [line, stillInComment]. Outside a comment an
// opener inside an inline code span is literal text (it is looked up with the spans blanked);
// inside one, backticks are comment text and only `-->` closes it.
function blankComments(line, inComment) {
  let out = "";
  let rest = line;
  let open = inComment;
  while (rest.length > 0) {
    const at = open ? rest.indexOf("-->") : blankAll(rest, CODE_SPAN_RE).indexOf("<!--");
    if (at === -1) { out += open ? spaces(rest) : rest; break; }
    const cut = at + (open ? 3 : 0);
    out += open ? spaces(rest.slice(0, cut)) : rest.slice(0, cut);
    rest = rest.slice(cut);
    if (!open) { out += spaces(rest.slice(0, 4)); rest = rest.slice(4); }
    open = !open;
  }
  return [out, open];
}

function isPathShaped(token) {
  const core = token.replace(EDGE_PUNCT_RE, "");
  return core.includes("/") || core.includes("\\") || PATH_EXT_RE.test(core);
}

function blankInline(line) {
  let s = blankAll(line, CODE_SPAN_RE);
  s = blankAll(s, /<<.*?>>/g);
  s = s.replace(/\]\([^)]*\)/g, (m) => "]" + spaces(m.slice(1)));
  s = blankAll(s, /<[A-Za-z][A-Za-z0-9+.-]*:[^>\s]*>/g);
  return s.replace(/\S+/g, (t) => (isPathShaped(t) ? spaces(t) : t));
}

// The identifier layer of one line: the code-span contents in place, everything else blank.
function codeSpanContents(line) {
  let out = spaces(line);
  line.replace(CODE_SPAN_RE, (m, ticks, offset) => {
    const from = offset + ticks.length;
    out = out.slice(0, from) + m.slice(ticks.length, m.length - ticks.length) + out.slice(offset + m.length - ticks.length);
    return m;
  });
  return blankInline(out);
}

// -> { prose, ident } line arrays: frontmatter, fences and HTML comments are blank in both.
function markdownPass(lines) {
  const prose = lines.slice();
  const ident = lines.map(spaces);
  let start = 0;
  if (prose.length > 0 && prose[0].trim() === "---") {
    const end = prose.findIndex((l, i) => i > 0 && (l.trim() === "---" || l.trim() === "..."));
    if (end !== -1) {
      for (let i = 0; i <= end; i++) prose[i] = spaces(prose[i]);
      start = end + 1;
    }
  }
  let fence = null;
  let inComment = false;
  for (let i = start; i < prose.length; i++) {
    const step = inComment ? { fence, marker: false } : fenceStep(prose[i], fence);
    const inside = fence !== null || step.marker;
    fence = step.fence;
    if (inside) { prose[i] = spaces(prose[i]); continue; }
    const [line, open] = blankComments(prose[i], inComment);
    inComment = open;
    prose[i] = blankInline(line);
    ident[i] = codeSpanContents(line);
  }
  return { prose, ident };
}

// Keeps only the comment body of a code file: the marker becomes blanks, code lines go blank.
// -> { body, kept } — kept holds the 1-based numbers of the comment lines.
function commentLines(text, lines) {
  const kinds = new Map(classifyLines(text).map((c) => [c.lineNo, c.kind]));
  const kept = new Set();
  const body = lines.map((l, i) => {
    if (kinds.get(i + 1) !== "comment") return spaces(l);
    kept.add(i + 1);
    const b = l.replace(/^(\s*)(\/\*+|\*\/|\/\/+|#+|\*)/, (m) => spaces(m));
    return b.replace(/\*\/\s*$/, (m) => spaces(m));
  });
  return { body, kept };
}

// extractLayers(text, format) -> { prose, ident, commentLines }; format: "markdown" | "code".
// commentLines is empty for markdown.
function extractLayers(text, format) {
  const src = typeof text === "string" ? text.replace(/^[\u{FEFF}]/u, "") : "";
  const lines = src.split("\n").map((l) => l.replace(/\r$/, ""));
  const code = format === "code" ? commentLines(src, lines) : { body: lines, kept: new Set() };
  const { prose, ident } = markdownPass(code.body);
  return { prose: prose.join("\n"), ident: ident.join("\n"), commentLines: code.kept };
}

// extractCheckableText(text, format) -> the prose layer (the contract of #2529 S3).
function extractCheckableText(text, format) {
  return extractLayers(text, format).prose;
}

module.exports = { blankComments, isPathShaped, blankInline, markdownPass, commentLines, extractCheckableText, extractLayers };
