"use strict";

// Resolve the target of a `source` / `.` line by path only (#2512 stage 4).
// Only shapes whose directory is statically known resolve; anything else —
// a loop variable, an undefined or multiply-assigned variable, a glob —
// yields null so no inheritance edge is drawn.

const path = require("path");

const SELF = '(?:\\$0|\\$\\{0\\}|\\$\\{BASH_SOURCE(?:\\[0\\])?\\}|\\$BASH_SOURCE)';
// A self-dir expression: "$(dirname "$0")", "$(dirname "${BASH_SOURCE[0]}")", "${BASH_SOURCE%/*}".
const DIR_EXPR = `(?:"?\\$\\(dirname\\s+"?${SELF}"?\\)"?|"?\\$\\{BASH_SOURCE(?:\\[0\\])?%/\\*\\}"?)`;
const TOP_EXPR = '"?\\$\\(git\\s+rev-parse\\s+--show-toplevel\\)"?';
// Path-expression grammar: BASE REL, where BASE is a self-dir, the repo top, a
// `$(cd "<path>" && pwd)` subshell, or a once-assigned variable (resolved recursively).
const SELF_DIR_RE = new RegExp(`^"?${DIR_EXPR}`);
const TOP_RE = new RegExp(`^"?${TOP_EXPR}`);
const CD_OPEN_RE = /^"?\$\(cd\s+/;
const CD_CLOSE_RE = /^"?\s*&&\s*pwd(?:\s+-P)?\s*\)"?/;
const VAR_RE = /^"?\$(?:([A-Za-z_]\w*)|\{([A-Za-z_]\w*)\})/;
const REL_RE = /^(?:\/[A-Za-z0-9._+-]+)*/;
const ARG_END_RE = /^"?(?=\s*(?:$|[;&|)]))/;
const VAL_END_RE = /^"?\s*(?:$|[;&|])/;

const SOURCE_RE = /(?:^|[\s;&|(`{!])(?:source|\.)\s+(?=\S)/g;
const ASSIGN_RE = /(?:^|[\s;&|(])(?:(?:readonly|local|export|declare(?:\s+-\w+)*)\s+)?([A-Za-z_]\w*)\+?=/g;
const FOR_RE = /(?:^|[\s;&|(])for\s+([A-Za-z_]\w*)\s+in\b/g;

// assignments(lines) → Map<name, [{ value }]> over every logical line.
function assignments(lines) {
  const out = new Map();
  const add = (name, value) => {
    if (!out.has(name)) out.set(name, []);
    out.get(name).push({ value });
  };
  for (const l of lines) {
    if (l.heredoc || l.comment) continue;
    let m;
    ASSIGN_RE.lastIndex = 0;
    while ((m = ASSIGN_RE.exec(l.code)) !== null) {
      add(m[1], l.text.slice(m.index + m[0].length));
    }
    FOR_RE.lastIndex = 0;
    while ((m = FOR_RE.exec(l.code)) !== null) add(m[1], null);
  }
  return out;
}

// parseBase(s, ctx, seen) → { dir, len } for the BASE at the start of s, or null.
function parseBase(s, ctx, seen) {
  let m = SELF_DIR_RE.exec(s);
  if (m) return { dir: ctx.dir, len: m[0].length };
  m = TOP_RE.exec(s);
  if (m) return { dir: ctx.repoRoot, len: m[0].length };
  m = CD_OPEN_RE.exec(s);
  if (m) {
    const inner = parsePath(s.slice(m[0].length), ctx, seen);
    if (!inner) return null;
    const close = CD_CLOSE_RE.exec(s.slice(m[0].length + inner.len));
    return close ? { dir: inner.dir, len: m[0].length + inner.len + close[0].length } : null;
  }
  m = VAR_RE.exec(s);
  if (m) {
    const dir = varDir(m[1] || m[2], ctx, seen);
    return dir ? { dir, len: m[0].length } : null;
  }
  return null;
}

// parsePath(s, ctx, seen) → { dir, len } for BASE REL at the start of s, or null.
function parsePath(s, ctx, seen) {
  const base = parseBase(s, ctx, seen);
  if (!base) return null;
  const rel = REL_RE.exec(s.slice(base.len))[0];
  return { dir: path.resolve(base.dir, "." + rel), len: base.len + rel.length };
}

// whole(s, endRe, ctx, seen) → resolved path when BASE REL spans s up to endRe.
function whole(s, endRe, ctx, seen) {
  const p = parsePath(s, ctx, seen);
  return p && endRe.test(s.slice(p.len)) ? p.dir : null;
}

// varDir(name, ctx, seen) → absolute dir a once-assigned variable holds, or null.
// `seen` cuts a variable cycle (A="$B/x"; B="$A/y").
function varDir(name, ctx, seen) {
  const list = ctx.assigns.get(name);
  if (!list || list.length !== 1 || list[0].value === null || seen.has(name)) return null;
  seen.add(name);
  const dir = whole(list[0].value.trim(), VAL_END_RE, ctx, seen);
  seen.delete(name);
  return dir;
}

// resolveArg(arg, ctx) → absolute path of the sourced file, or null.
function resolveArg(arg, ctx) {
  return whole(arg, ARG_END_RE, ctx, new Set());
}

// sourceEdges(file, lines, repoRoot) → [{ target, at: { line, idx } }] (resolved only).
function sourceEdges(file, lines, repoRoot) {
  const ctx = { dir: path.dirname(file), repoRoot, assigns: assignments(lines) };
  const edges = [];
  for (const l of lines) {
    if (l.heredoc || l.comment || l.inString) continue;
    let m;
    SOURCE_RE.lastIndex = 0;
    while ((m = SOURCE_RE.exec(l.code)) !== null) {
      const start = m.index + m[0].length;
      const target = resolveArg(l.text.slice(start), ctx);
      if (!target) continue;
      const at = l.fnStart !== null ? { line: l.fnStart, idx: -1 } : { line: l.line, idx: start };
      edges.push({ target, at });
    }
  }
  return edges;
}

module.exports = { sourceEdges };
