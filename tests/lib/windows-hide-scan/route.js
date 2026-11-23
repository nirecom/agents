"use strict";
// tests/lib/windows-hide-scan/route.js — finds the child_process calls of one file through its
// bindings (module alias, destructured name with alias, inline require, ESM import), picks the
// options argument of each call and reports every call whose options do not guarantee windowsHide: true.
const { maskDetailed, matchClose, splitTop, lineOf } = require("./parse");
const { makeContext, judgeExpr } = require("./verdict");

const FNS = ["spawnSync", "spawn", "execFileSync", "execFile", "execSync", "exec", "fork"];
const FN_ALT = FNS.join("|");
const MOD = String.raw`["'](?:node:)?child_process["']`;
const ID = String.raw`[A-Za-z_$][\w$]*`;
const esc = (s) => s.replace(/[$]/g, "\\$");
const short = (t) => { const s = t.replace(/\s+/g, " "); return s.length > 40 ? s.slice(0, 40) + "…" : s; };
const REASON_UNPARSABLE = "scanner cannot parse file (unterminated string/template/comment)";

// Positions come from src; the masked text confirms the keyword sits in code, not a comment or string.
function codeMatches(src, masked, re, word) {
  return [...src.matchAll(re)].filter((m) => masked.startsWith(word, m.index + m[0].indexOf(word)));
}

function namedEntries(list, sep) {
  const pairs = [];
  for (const raw of list.split(",")) {
    const e = raw.replace(/=[\s\S]*$/, "").trim();
    const m = new RegExp("^(" + ID + ")(?:\\s*" + sep + "\\s*(" + ID + "))?$").exec(e);
    if (m && FNS.includes(m[1])) pairs.push([m[2] || m[1], m[1]]);
  }
  return pairs;
}

function collectBindings(src, masked) {
  const modules = new Set(), names = new Map();
  const req = String.raw`require\s*\(\s*${MOD}\s*\)`;
  for (const m of codeMatches(src, masked, new RegExp(String.raw`\b(?:const|let|var)\s+(${ID})\s*=\s*${req}(?!\s*\.)`, "g"), "require")) modules.add(m[1]);
  for (const m of codeMatches(src, masked, new RegExp(String.raw`\b(?:const|let|var)\s*\{([^}]*)\}\s*=\s*${req}`, "g"), "require")) {
    for (const [local, fn] of namedEntries(m[1], ":")) names.set(local, fn);
  }
  for (const m of codeMatches(src, masked, new RegExp(String.raw`\bimport\s+(?:\*\s+as\s+)?(${ID})\s+from\s+${MOD}`, "g"), "import")) modules.add(m[1]);
  for (const m of codeMatches(src, masked, new RegExp(String.raw`\bimport\s*\{([^}]*)\}\s*from\s+${MOD}`, "g"), "import")) {
    for (const [local, fn] of namedEntries(m[1], "as")) names.set(local, fn);
  }
  return { modules, names };
}

// findCalls -> [{ idx, open, callee, fn }]: fn "computed" for X[expr](...).
function findCalls(src, masked, { modules, names }) {
  const calls = [];
  for (const x of modules) {
    for (const m of masked.matchAll(new RegExp("(?<![\\w$.])" + esc(x) + "\\s*\\.\\s*(" + FN_ALT + ")\\s*\\(", "g"))) {
      calls.push({ idx: m.index, open: m.index + m[0].length - 1, callee: `${x}.${m[1]}`, fn: m[1] });
    }
    for (const m of masked.matchAll(new RegExp("(?<![\\w$.])" + esc(x) + "\\s*\\[", "g"))) {
      const bracket = m.index + m[0].length - 1, close = matchClose(masked, bracket);
      const paren = /^\s*\(/.exec(masked.slice(close + 1));
      if (!paren) continue;
      calls.push({ idx: m.index, open: close + paren[0].length, callee: `${x}[${short(src.slice(bracket + 1, close))}]`, fn: "computed" });
    }
  }
  for (const [local, fn] of names) {
    for (const m of masked.matchAll(new RegExp("(?<![\\w$.])" + esc(local) + "\\s*\\(", "g"))) {
      if (/\bfunction\s*\*?\s*$/.test(masked.slice(Math.max(0, m.index - 20), m.index))) continue;
      calls.push({ idx: m.index, open: m.index + m[0].length - 1, callee: local, fn });
    }
  }
  const inline = new RegExp(String.raw`require\s*\(\s*${MOD}\s*\)\s*\.\s*(${FN_ALT})\s*\(`, "g");
  for (const m of codeMatches(src, masked, inline, "require")) {
    calls.push({ idx: m.index, open: m.index + m[0].length - 1, callee: `require("child_process").${m[1]}`, fn: m[1] });
  }
  return calls.sort((a, b) => a.idx - b.idx);
}

function optionsArg(fn, args) {
  if (fn === "computed") return args.length >= 2 ? args[args.length - 1] : null;
  if (fn === "execSync" || fn === "exec") return args[1] === undefined ? null : args[1];
  if (args.length >= 3) return args[2];
  if (args.length === 2) return args[1].startsWith("[") ? null : args[1];
  return null;
}

// scanSource(rel, src) -> [{ rel, line, call, reason }] sorted by line.
function scanSource(rel, src) {
  const { text: masked, unterminatedAt } = maskDetailed(src);
  if (unterminatedAt !== null) return [{ rel, line: lineOf(src, unterminatedAt), call: "", reason: REASON_UNPARSABLE }];
  const ctx = makeContext(src, masked);
  const out = [], spans = [];
  for (const c of findCalls(src, masked, collectBindings(src, masked))) {
    const close = matchClose(masked, c.open);
    const args = splitTop(src.slice(c.open + 1, close), masked.slice(c.open + 1, close));
    const opt = optionsArg(c.fn, args);
    const reason = opt === null ? "no options argument" : judgeExpr(opt, { ctx, args, pos: c.idx });
    if (reason === null) continue;
    spans.push([c.open, close]);
    out.push({ rel, line: lineOf(src, c.idx), call: `${c.callee}(${short(args[0] || "")}${args.length > 1 ? ", …" : ""})`, reason });
  }
  for (const m of masked.matchAll(/\bwindowsHide\s*:\s*false\b/g)) {
    if (spans.some(([a, b]) => a < m.index && m.index < b)) continue;
    out.push({ rel, line: lineOf(src, m.index), call: "", reason: "windowsHide: false" });
  }
  return out.sort((a, b) => a.line - b.line);
}

module.exports = { scanSource, REASON_UNPARSABLE };
