"use strict";
// Static scanner for the #2699 sweep: lists every string or template literal that starts with
// "[EM Supervisor]" or "[C4 " in a JS source, with the name of the innermost named function
// enclosing it (null at module scope or inside a bare `if` block). Comments, strings, template
// literals (with nested ${} code) and regex literals are skipped so braces inside them never
// move the function frames; literals joined by a bare `+` are judged as their concatenation.

const fs = require("fs");
const path = require("path");

const MARK = /^\[(EM Supervisor\]|C4 )/;
const KEYWORDS = new Set(["if", "for", "while", "switch", "catch", "with", "function", "return", "typeof"]);
const REGEX_PREV = /[(,=:[!&|?{};+\-*%<>~^]$/;

// The name a `{` opens, judged from the code text right before it (literals blanked).
function frameName(tail) {
  let m = tail.match(/function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\([^()]*\)\s*$/);
  if (m) return m[1];
  m = tail.match(/([A-Za-z_$][\w$]*)\s*[=:]\s*(?:async\s+)?function\s*\*?\s*[\w$]*\s*\([^()]*\)\s*$/);
  if (m) return m[1];
  m = tail.match(/([A-Za-z_$][\w$]*)\s*[=:]\s*(?:async\s+)?(?:\([^()]*\)|[A-Za-z_$][\w$]*)\s*=>\s*$/);
  if (m) return m[1];
  m = tail.match(/(?:^|[\s,{;])([A-Za-z_$][\w$]*)\s*\([^()]*\)\s*$/);
  if (m && !KEYWORDS.has(m[1]) && /[\n{,;}]\s*[A-Za-z_$][\w$]*\s*\([^()]*\)\s*$/.test(tail)) return m[1];
  if (/(?:function\s*\*?\s*\([^()]*\)|=>)\s*$/.test(tail)) return "<anonymous>";
  return undefined; // not a function body (block, object literal, class body)
}

function scanSource(src) {
  const found = [];
  const frames = []; // { name, depth }
  const modes = [];  // template-expression brace depths
  let depth = 0;
  let code = "";     // code text with literals blanked, for frameName lookbacks
  let line = 1;
  let i = 0;
  const innermost = () => {
    for (let k = frames.length - 1; k >= 0; k--) if (frames[k].name && frames[k].name !== "<anonymous>") return frames[k].name;
    return null;
  };
  const readQuoted = (q) => {
    let s = "";
    i++;
    while (i < src.length && src[i] !== q) {
      if (src[i] === "\\") { s += src[i + 1] || ""; i += 2; continue; }
      if (src[i] === "\n") line++;
      s += src[i++];
    }
    i++;
    return s;
  };
  // Reads a template literal from the backtick (or from the `}` closing a ${}) to its end or the
  // next ${; returns the raw text and whether a ${ was opened.
  const readTemplate = () => {
    let s = "";
    while (i < src.length) {
      const c = src[i];
      if (c === "\\") { s += src[i + 1] || ""; i += 2; continue; }
      if (c === "`") { i++; return { s, open: false }; }
      if (c === "$" && src[i + 1] === "{") { i += 2; return { s, open: true }; }
      if (c === "\n") line++;
      s += c;
      i++;
    }
    return { s, open: false };
  };
  // A literal joined to the previous one by a bare `+` ("[EM " + "Supervisor] x") is judged as the
  // concatenation, so a split marker is still detected; a literal that already matched alone stays
  // a separate hit. prev = the last closed literal (or the running concatenation).
  let prev = null;
  const record = (text, startLine, closed) => {
    let hit = null;
    if (prev && !prev.recorded && /^\s*\+\s*$/.test(code.slice(prev.codeLen))) {
      const joined = prev.text + text;
      if (MARK.test(joined)) hit = { line: prev.line, text: joined };
      else if (MARK.test(text)) hit = { line: startLine, text };
      prev = { text: joined, line: prev.line, recorded: !!hit };
    } else {
      if (MARK.test(text)) hit = { line: startLine, text };
      prev = { text, line: startLine, recorded: !!hit };
    }
    if (hit) found.push({ ...hit, fn: innermost() });
    code += '""';
    if (closed) prev.codeLen = code.length;
    else prev = null;
  };

  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];
    if (c === "\n") { line++; code += c; i++; continue; }
    if (c === "/" && n === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && n === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { if (src[i] === "\n") line++; i++; }
      i += 2;
      continue;
    }
    if (c === "'" || c === '"') { const l = line; record(readQuoted(c), l, true); continue; }
    if (c === "`") {
      const l = line;
      i++;
      const t = readTemplate();
      record(t.s, l, !t.open);
      if (t.open) { modes.push(depth); depth++; }
      continue;
    }
    if (c === "/" && REGEX_PREV.test(code.replace(/\s+$/, "")) ) {
      i++;
      let inClass = false;
      while (i < src.length && src[i] !== "\n") {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === "[") inClass = true;
        else if (src[i] === "]") inClass = false;
        else if (src[i] === "/" && !inClass) break;
        i++;
      }
      i++;
      while (/[a-z]/.test(src[i] || "")) i++;
      code += '""';
      continue;
    }
    if (c === "{") {
      const name = frameName(code.slice(-400));
      if (name !== undefined) frames.push({ name, depth });
      depth++;
      code += c;
      i++;
      continue;
    }
    if (c === "}") {
      depth--;
      while (frames.length && frames[frames.length - 1].depth >= depth) frames.pop();
      i++;
      if (modes.length && modes[modes.length - 1] === depth) {
        modes.pop();
        const t = readTemplate();
        if (t.open) { modes.push(depth); depth++; }
        continue;
      }
      code += c;
      continue;
    }
    code += c;
    i++;
  }
  return found;
}

// The #2699 sweep set under hooks/ (detail plan, test plan (1)), minus the registry itself.
function sweepFiles(hooksDir) {
  const out = [];
  const add = (p) => { if (fs.existsSync(p) && fs.statSync(p).isFile()) out.push(p); };
  for (const f of fs.readdirSync(hooksDir)) {
    if (/^supervisor-guard.*\.js$/.test(f)) add(path.join(hooksDir, f));
  }
  for (const f of ["stop-premature-stop-guard.js", "stop-l2-findings-display.js", "supervisor-trigger.js",
    "supervisor-off-proposal-shim.js", "workflow-gate/user-verified-audit.js", "workflow-gate/supervisor-check.js"]) {
    add(path.join(hooksDir, f));
  }
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".js")) add(p);
    }
  };
  walk(path.join(hooksDir, "supervisor-guard"));
  for (const f of fs.readdirSync(path.join(hooksDir, "lib"))) {
    if (/^supervisor-.*\.js$/.test(f) && f !== "supervisor-reason-registry.js") add(path.join(hooksDir, "lib", f));
  }
  return [...new Set(out)];
}

module.exports = { scanSource, sweepFiles };
