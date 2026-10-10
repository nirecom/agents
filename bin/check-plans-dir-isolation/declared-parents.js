"use strict";

// Declared parent edges (#2512 stage 4). A part file whose parent reaches it through a
// shape source-resolve cannot follow — a loop variable, an "$SCRIPT_CHECKOUT_ROOT" path, a name
// list, or `bash <part>` after the parent exported its pins — names that parent on a
// comment line, relative to its own directory:
//   # isolation: inherits-from ../feature-x.sh
// The edge is drawn only when the parent is a scanned unit whose code (comments and
// heredoc bodies excluded) mentions the child's basename (without .sh); it sits at that
// first mention, so the parent's pin must precede it. A stale declaration draws nothing
// and the child stays top-level.

const path = require("path");

const DECL_RE = /^\s*#\s*isolation:\s*inherits-from\s+(\S+)\s*$/;
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// declaredParents(file, text) → absolute parent paths named by the file.
function declaredParents(file, text) {
  const out = [];
  for (const raw of text.split("\n")) {
    const m = DECL_RE.exec(raw);
    if (m) out.push(path.resolve(path.dirname(file), m[1]));
  }
  return out;
}

// mentionAt(lines, child) → { line, idx } of the first code mention of child's basename;
// `lines` are parseShell logical lines, whose `text` already ends before any comment.
function mentionAt(lines, child) {
  const name = path.basename(child, ".sh");
  const re = new RegExp(`(?<![\\w.-])${escapeRe(name)}(?![\\w-])`);
  for (const l of lines) {
    if (l.comment || l.heredoc) continue;
    const rows = l.text.split("\n");
    for (let k = 0; k < rows.length; k++) {
      const m = re.exec(rows[k]);
      if (m) return { line: l.line + k, idx: m.index };
    }
  }
  return null;
}

// addDeclaredEdges(units) — units: Map<absPath, { text, lines, edges }>; appends a
// parent→child edge to the parent unit for every verified declaration.
function addDeclaredEdges(units) {
  for (const [child, u] of units) {
    for (const parent of declaredParents(child, u.text)) {
      const p = units.get(parent);
      if (!p || parent === child) continue;
      const at = mentionAt(p.lines, child);
      if (at) p.edges.push({ target: child, at });
    }
  }
}

module.exports = { addDeclaredEdges };
