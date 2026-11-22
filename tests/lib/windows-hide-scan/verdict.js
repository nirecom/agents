"use strict";
// tests/lib/windows-hide-scan/verdict.js — judges one options argument of a child_process call:
// null when windowsHide: true is guaranteed, else the violation reason. Judgments (a)-(e) of the
// #3127 detail plan: object literal, Object.assign, spawn-env builder, in-file opts variable,
// in-file forwarding function.
const { mask, matchClose, splitTop, lineOf } = require("./parse");

const IDENT = /^[A-Za-z_$][\w$]*$/;
const UNDECIDED = Symbol("undecided");
const LACKS = "options literal lacks windowsHide: true";
const HIDE_ENTRY = /^(?:windowsHide|"windowsHide"|'windowsHide')\s*(?::\s*([\s\S]*))?$/;
const esc = (s) => s.replace(/[$]/g, "\\$");
const short = (t) => { const s = t.replace(/\s+/g, " "); return s.length > 40 ? s.slice(0, 40) + "…" : s; };
const wordRe = (w, flags = "g") => new RegExp("(?<![\\w$.])" + esc(w) + "(?![\\w$])", flags);

function isWrapped(t, open) {
  return t[0] === open && matchClose(mask(t), 0) === t.length - 1;
}

// makeContext(src, masked) -> file-level facts shared by every call of one file.
function makeContext(src, masked) {
  const triples = [...masked.matchAll(/const\s*\[\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\]\s*=\s*build(?:Gh|Git|BashScript)Spawn\(/g)]
    .map((m) => [m[1], m[2], m[3]]);
  const functions = [];
  for (const m of masked.matchAll(/\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/g)) {
    const open = m.index + m[0].length - 1, close = matchClose(masked, open);
    const params = splitTop(src.slice(open + 1, close), masked.slice(open + 1, close)).map((p) => p.replace(/=[\s\S]*$/, "").trim());
    const bodyOpen = masked.indexOf("{", close);
    if (bodyOpen < 0) continue;
    functions.push({ name: m[1], nameIdx: m.index + m[0].indexOf(m[1], 8), params, bodyOpen, bodyClose: matchClose(masked, bodyOpen) });
  }
  const exportRegions = [];
  for (const m of masked.matchAll(/(?<![\w$.])(?:module\.exports|exports)\b/g)) {
    const eq = masked.indexOf("=", m.index);
    const lineEnd = masked.indexOf("\n", m.index) < 0 ? masked.length : masked.indexOf("\n", m.index);
    const after = eq < 0 ? -1 : eq + 1 + (masked.slice(eq + 1).length - masked.slice(eq + 1).trimStart().length);
    const end = after >= 0 && masked[after] === "{" ? matchClose(masked, after) : lineEnd;
    exportRegions.push(masked.slice(m.index, end + 1));
  }
  return { src, masked, triples, functions, exportRegions };
}

// evalLiteral(text, j) -> null | reason | UNDECIDED: the last entry that decides windowsHide wins.
function evalLiteral(text, j) {
  const inner = text.slice(1, -1);
  const entries = splitTop(inner, mask(inner));
  const hasTrue = entries.some((e) => { const m = HIDE_ENTRY.exec(e); return m && m[1] && m[1].trim() === "true"; });
  for (let k = entries.length - 1; k >= 0; k--) {
    const e = entries[k];
    if (e.startsWith("...")) {
      const x = e.slice(3).trim();
      if (IDENT.test(x) && declOk(x, j)) return null;
      return hasTrue ? `windowsHide: true can be overridden by later spread ...${short(x)}` : LACKS;
    }
    if (e.startsWith("[")) return "windowsHide: true can be overridden by later computed key";
    const m = HIDE_ENTRY.exec(e);
    if (!m) continue;
    const value = (m[1] || "").trim();
    if (value === "true") return null;
    return value === "false" ? "windowsHide: false" : LACKS;
  }
  return UNDECIDED;
}

function assignVerdict(t, j) {
  const inner = t.slice(t.indexOf("(") + 1, -1);
  const parts = splitTop(inner, mask(inner));
  for (let k = parts.length - 1; k >= 0; k--) {
    const p = parts[k];
    if (isWrapped(p, "{")) {
      const r = evalLiteral(p, j);
      if (r !== UNDECIDED) return r;
    } else if (IDENT.test(p)) {
      return identVerdict(p, j);
    } else return `options expression not analyzable: ${short(p)}`;
  }
  return LACKS;
}

// judgeExpr(text, j) -> null | reason. j = { ctx, args, pos, allowForward, seen }.
function judgeExpr(text, j) {
  const t = text.trim();
  if (isWrapped(t, "{")) { const r = evalLiteral(t, j); return r === UNDECIDED ? LACKS : r; }
  if (/^Object\.assign\s*\(/.test(t) && t.endsWith(")") && matchClose(mask(t), t.indexOf("(")) === t.length - 1) return assignVerdict(t, j);
  if (IDENT.test(t)) return identVerdict(t, j);
  return `options expression not analyzable: ${short(t)}`;
}

function builderOk(x, j) {
  return Boolean(j.args) && j.ctx.triples.some(([a, b, o]) => o === x && j.args[0] === a && j.args[1] === b);
}

// (d): every `const|let|var X =` initializer is a literal or Object.assign that judges OK.
function declOk(x, j) {
  const seen = j.seen || new Set();
  if (seen.has(x)) return false;
  const { src, masked } = j.ctx;
  const decls = [...masked.matchAll(new RegExp("\\b(?:const|let|var)\\s+" + esc(x) + "\\s*=(?![=>])\\s*", "g"))];
  if (decls.length === 0) return false;
  const next = { ...j, args: [], seen: new Set([...seen, x]), allowForward: false };
  return decls.every((m) => {
    const start = m.index + m[0].length;
    let end;
    if (masked[start] === "{") end = matchClose(masked, start);
    else if (masked.startsWith("Object.assign", start)) end = matchClose(masked, masked.indexOf("(", start));
    else return false;
    return judgeExpr(src.slice(start, end + 1), next) === null;
  });
}

function identVerdict(x, j) {
  if (builderOk(x, j) || declOk(x, j)) return null;
  if (j.allowForward !== false) {
    const r = forwardVerdict(x, j);
    if (r !== undefined) return r;
  }
  return `options identifier ${x} has no in-file declaration with windowsHide: true`;
}

// (e): undefined when x is not a parameter of an enclosing function declaration.
function forwardVerdict(p, j) {
  const { ctx } = j;
  const fn = ctx.functions
    .filter((f) => f.bodyOpen < j.pos && j.pos < f.bodyClose && f.params.includes(p))
    .sort((a, b) => b.bodyOpen - a.bodyOpen)[0];
  if (!fn) return undefined;
  const head = `forwarded parameter ${p} of ${fn.name}: `;
  if (ctx.exportRegions.some((r) => wordRe(fn.name, "").test(r))) return head + "exported";
  const names = [fn.name];
  const callOpens = [];
  for (const m of ctx.masked.matchAll(wordRe(fn.name))) {
    if (m.index === fn.nameIdx) continue;
    const rest = ctx.masked.slice(m.index + fn.name.length);
    if (/^\s*\(/.test(rest)) { callOpens.push(m.index + fn.name.length + rest.indexOf("(")); continue; }
    const ls = ctx.masked.lastIndexOf("\n", m.index) + 1;
    const le = ctx.masked.indexOf("\n", m.index) < 0 ? ctx.masked.length : ctx.masked.indexOf("\n", m.index);
    const alias = new RegExp("^\\s*(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*(?:[^;\\n]*\\|\\|\\s*)?" + esc(fn.name) + "\\s*;?\\s*$")
      .exec(ctx.masked.slice(ls, le));
    if (!alias) return head + "non-call reference";
    names.push(alias[1]);
  }
  for (const a of names.slice(1)) {
    for (const m of ctx.masked.matchAll(new RegExp("(?<![\\w$.])" + esc(a) + "\\s*\\(", "g"))) callOpens.push(m.index + m[0].length - 1);
  }
  const pIdx = fn.params.indexOf(p);
  for (const open of callOpens) {
    const close = matchClose(ctx.masked, open);
    const args = splitTop(ctx.src.slice(open + 1, close), ctx.masked.slice(open + 1, close));
    const arg = args[pIdx];
    if (arg === undefined || judgeExpr(arg, { ctx, args, pos: open, allowForward: false }) !== null) {
      return head + `caller at ${lineOf(ctx.src, open)} lacks windowsHide: true`;
    }
  }
  return null;
}

module.exports = { makeContext, judgeExpr };
