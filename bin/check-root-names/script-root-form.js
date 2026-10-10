"use strict";

// Script-root-form check (#2561): a file assigns its own checkout root at most once,
// unconditionally, at the top, in the one standard form for its language and depth.

const { view, splitCommand, declared, escapeRe } = require("./line-scan");
const { SCR } = require("./table-match");

// The assignment belongs to the head of the file: at most this many lines of code before it.
const MAX_CODE_LINES_BEFORE = 40;
const DECLARERS = new Set(["export", "local", "readonly", "declare", "typeset"]);
const W = "[A-Za-z0-9_$]";

const shStandard = (name) =>
  new RegExp(`^${escapeRe(name)}="\\$\\(cd "\\$\\(dirname "\\$\\{BASH_SOURCE\\[0\\]\\}"\\)(?:/(\\.\\.(?:/\\.\\.)*))?" && pwd\\)"\\s*$`);
const SH_READ = new RegExp(`\\$\\{?${SCR}(?!\\w)`);
const JS_STANDARD = new RegExp(`^const ${SCR} = path\\.resolve\\(__dirname((?:, ["']\\.\\.["'])*)\\);\\s*$`);
const JS_ASSIGN = new RegExp(`(?:const|let|var)\\s+${SCR}(?!${W})|(?:const|let|var)\\s*\\{[^}]*(?<!${W})${SCR}(?!${W})[^}]*\\}\\s*=|(?<![\\w$.])${SCR}\\s*=(?![=>])`);
const PS_ASSIGN = new RegExp(`(?<![\\w:])\\$${SCR}\\s*=(?!=)`);
const PS_STANDARD = new RegExp(`^\\$${SCR}\\s*=\\s*(.+)$`);

const depthOf = (rel) => rel.split("/").length - 1;

// A sourced library shares its caller's variables, so it uses a name of its own.
function sourcedName(rel) {
  const base = rel.split("/").pop().replace(/\.[^.]*$/, "");
  return `_${base.replace(/[^A-Za-z0-9]/g, "_").toUpperCase()}_${SCR}`;
}

// shAssigned(cmds, line) → the variable names this shell line assigns or declares.
function shAssigned(cmds, line) {
  const names = [];
  for (const words of cmds) {
    const { assigns, word, args } = splitCommand(words);
    if (word === null) names.push(...assigns);
    else if (DECLARERS.has(word)) names.push(...declared(args).map((d) => d.name));
    else if (word === "read") names.push(...args.filter((a) => /^[A-Za-z_]\w*$/.test(a)));
    else if (word === "for" && args.length > 0) names.push(args[0]);
  }
  for (const m of line.matchAll(/\$\{([A-Za-z_]\w*):?=/g)) names.push(m[1]);
  return names;
}

function codeLinesBefore(v, index) {
  let n = 0;
  for (let i = 0; i < index; i++) if (v.code[i].trim() !== "") n++;
  return n;
}

// "Unconditional" is where the line stands, not how it is indented: each language reports
// whether any block is still open when line `index` starts.

// A ")" with no paren open is a `case` pattern, so it closes nothing.
function shNested(v, index) {
  let blocks = 0;
  const parens = [];
  for (let i = 0; i < index; i++) {
    for (const mark of v.marks[i]) {
      if (mark === "+") blocks++;
      else if (mark === "-") blocks = Math.max(0, blocks - 1);
      else if (mark === ")") parens.pop();
      else parens.push(mark === "(+");
    }
  }
  return blocks > 0 || parens.includes(true);
}

function bracesOpen(lines, index) {
  let open = 0;
  for (let i = 0; i < index; i++) {
    for (const ch of lines[i]) {
      if (ch === "{") open++;
      else if (ch === "}") open = Math.max(0, open - 1);
    }
  }
  return open > 0;
}

const psUnquoted = (line) => line.replace(/'[^']*'|"[^"]*"/g, "");

// The levels a PowerShell expression climbs from $PSScriptRoot: one per "..", one per
// Split-Path (which yields the parent unless told to yield another part).
function psClimb(expr) {
  if (/-(?:Leaf|LeafBase|Extension|Qualifier|NoQualifier|IsAbsolute)\b/i.test(expr)) return null;
  return (expr.match(/\.\./g) || []).length + (expr.match(/\bSplit-Path\b/gi) || []).length;
}

function checkShell(file, v, sourced, say) {
  const want = sourced ? sourcedName(file.rel) : SCR;
  const prefixed = new RegExp(`^_[A-Z0-9_]*${SCR}$`);
  const at = [];
  let read = -1;
  for (let i = 0; i < v.code.length; i++) {
    if (!v.code[i].includes(SCR)) continue;
    if (read < 0 && SH_READ.test(v.code[i].replace(/'[^']*'/g, ""))) read = i;
    for (const name of shAssigned(v.cmds[i], v.code[i])) {
      if (name === want) at.push(i);
      else if (sourced && (name === SCR || prefixed.test(name))) say(i, "a sourced library assigns the checkout root under its own prefixed name only");
    }
  }
  // A sourced library may read its caller's value; any other file that reads the name
  // without assigning it would take the value from the environment.
  if (!sourced && read >= 0 && at.length === 0) say(read, "the checkout root is read but not assigned in this file");
  judge(file, v, at, say, (i) => {
    const m = shStandard(want).exec(v.raw[i]);
    if (!m || shNested(v, i)) return null;
    return m[1] ? m[1].split("/").length : 0;
  });
}

function checkNode(file, v, say) {
  const at = [];
  for (let i = 0; i < v.code.length; i++) if (v.bare[i].includes(SCR) && JS_ASSIGN.test(v.bare[i])) at.push(i);
  judge(file, v, at, say, (i) => {
    const m = JS_STANDARD.exec(v.raw[i]);
    if (!m || bracesOpen(v.bare, i)) return null;
    return (m[1].match(/\.\./g) || []).length;
  });
}

function checkPowerShell(file, v, say) {
  const at = [];
  for (let i = 0; i < v.code.length; i++) if (PS_ASSIGN.test(v.code[i])) at.push(i);
  judge(file, v, at, say, (i) => {
    const m = PS_STANDARD.exec(v.raw[i]);
    if (!m || !m[1].includes("$PSScriptRoot") || /\$env:|\bgit\b/i.test(m[1])) return null;
    if (bracesOpen(v.code.map(psUnquoted), i)) return null;
    return psClimb(m[1]);
  });
}

// judge — at: the lines that assign the name; climbOf(i): the levels the standard form
// on line i climbs, or null when the line is not in the standard form.
function judge(file, v, at, say, climbOf) {
  if (at.length === 0) return;
  if (at.length > 1) {
    for (const i of at.slice(1)) say(i, "the checkout root is assigned more than once");
    return;
  }
  const i = at[0];
  const climb = climbOf(i);
  if (climb === null) say(i, "the checkout root is not assigned in the standard form (once, unconditional, unexported, from the script's own location)");
  else if (climb !== depthOf(file.rel)) say(i, `the standard form climbs ${climb} level(s) but this file sits ${depthOf(file.rel)} below the root`);
  else if (codeLinesBefore(v, i) > MAX_CODE_LINES_BEFORE) say(i, "the checkout root is assigned too far from the top of the file");
}

function check(ctx) {
  const table = ctx.table();
  const out = [];
  for (const file of ctx.files) {
    if (file.text === null || !file.text.includes(SCR)) continue;
    const v = view(file);
    if (v.lang !== "sh" && v.lang !== "js" && v.lang !== "ps") continue;
    if (table.grantsFor(file.rel, ctx.repo).forms.has("own-script-root-form")) continue;
    const say = (i, msg) => out.push(`${file.rel}:${i + 1}: script-root-form: ${msg}`);
    if (v.lang === "sh") checkShell(file, v, table.ruleFor(file.rel, ctx.repo)?.sourced === true, say);
    else if (v.lang === "js") checkNode(file, v, say);
    else checkPowerShell(file, v, say);
  }
  return out;
}

module.exports = { check };
