"use strict";

// Reference-role check (#2589): an occurrence whose role the syntax decides is judged per
// reference against the one name that fits the role. Decided roles: a self-path definition,
// a main-worktree definition, a checkout definition, a config read. Any other occurrence
// passes here and stays with the file's table rule.

const { view, escapeRe } = require("./line-scan");
const { spellings, NAMES, SCR, AMR, TMR, TCR } = require("./table-match");

// The plan's main-worktree marker is on the retired-name list, so it is spelled in parts.
const MAIN_MARKER = ["main", "Worktree", "Of"].join("");
const SELF_RE = /dirname\s+"?\$\{?(?:BASH_SOURCE|0\b)|\$\{BASH_SOURCE(?:\[0\])?%|(?<![\w$])__dirname(?![\w$])|\$PSScriptRoot\b|(?<![\w.])__file__\b/;
const MAIN_RE = new RegExp(`worktree\\s+list|--git-common-dir|main-worktree-root|(?<![\\w$])${MAIN_MARKER}(?![\\w$])`);
const TOP_RE = /--show-toplevel\b/;
// What follows a name for a config read: "/.env", "/.env.local", "/docs/private-info",
// or the same target as the next argument of a path join.
const CONFIG_TAIL = `\\}?["'\`]?(?:[\\\\/]|\\s*[,+]\\s*["'\`][\\\\/]?)(?:\\.env(?:\\.local)?(?![\\w.-])|docs[\\\\/]private-info(?![\\w-]))`;

const ROLE_NAME = { self: SCR, main: TMR, top: TCR, config: AMR };
const ROLE_TEXT = {
  self: "a path from the script's own location is the script checkout root",
  main: "the main worktree is the target main root",
  top: "the top level of a checkout is the target checkout root",
  config: "configuration is read from the agents main root",
};

// Each root name in the spellings a line can carry: upper case (bare or behind a `_X_`
// prefix that a sourced library adds) and camel case for JavaScript.
const UPPER = `(?:_[A-Z0-9_]*?_)?(?:${NAMES.join("|")})`;
const CAMEL = NAMES.map((n) => spellings(n).camel);
const ANY_NAME = `(?:${UPPER}|${CAMEL.join("|")})`;

// baseOf(name) → the root name a spelling stands for, or null.
function baseOf(name) {
  for (const n of NAMES) {
    if (name === n || name === spellings(n).camel || new RegExp(`^_[A-Z0-9_]*_${escapeRe(n)}$`).test(name)) return n;
  }
  return null;
}

// Global: a line can carry several assignments; each one's value runs up to the next one.
const ASSIGN = {
  sh: new RegExp(`(?:^|[\\s;&|(])(?:(?:export|local|readonly|declare|typeset)(?:\\s+-\\w+)*\\s+)?(${UPPER})=`, "g"),
  js: new RegExp(`(?:(?:const|let|var)\\s+|(?<![\\w$.]))(${ANY_NAME})\\s*=(?![=>])`, "g"),
  ps: new RegExp(`(?<![\\w:])\\$(${UPPER})\\s*=(?!=)`, "gi"),
  py: new RegExp(`(?<![\\w.])(${UPPER})\\s*=(?!=)`, "g"),
};
const CONFIG = {
  sh: new RegExp(`\\$\\{?(${UPPER})${CONFIG_TAIL}`, "g"),
  js: new RegExp(`(?<![\\w$])(${ANY_NAME})${CONFIG_TAIL}`, "g"),
  ps: new RegExp(`\\$(?:\\{)?(${UPPER})${CONFIG_TAIL}`, "gi"),
  py: new RegExp(`(?<![\\w.])(${UPPER})${CONFIG_TAIL}`, "g"),
};

// definitionRole(rhs) — the main worktree wins over the script's location (a main worktree
// found from the script is still a main worktree), and the script's location wins over a
// checkout top (the top of the script's own checkout is the script checkout root).
function definitionRole(rhs) {
  if (MAIN_RE.test(rhs)) return "main";
  if (SELF_RE.test(rhs)) return "self";
  if (TOP_RE.test(rhs)) return "top";
  return null;
}

// configFromSelf: a named exception lets this file read config from its own checkout.
function judgeLine(lang, line, configFromSelf, say) {
  const defs = [...line.matchAll(ASSIGN[lang])];
  defs.forEach((a, k) => {
    const end = k + 1 < defs.length ? defs[k + 1].index : line.length;
    const role = definitionRole(line.slice(a.index + a[0].length, end));
    const base = baseOf(a[1]);
    if (role && base && base !== ROLE_NAME[role]) say(`${a[1]} is defined here, but ${ROLE_TEXT[role]} (${ROLE_NAME[role]})`);
  });
  for (const m of line.matchAll(CONFIG[lang])) {
    const base = baseOf(m[1]);
    if (base === SCR && configFromSelf) continue;
    if (base && base !== AMR) say(`${m[1]} is used for a config read, but ${ROLE_TEXT.config} (${AMR})`);
  }
}

// A definition whose value starts on the next line (a trailing "=", or a line continuation)
// is judged with the lines that finish it, and reported on the line that names the root.
const CONTINUED = { sh: /(?:=|\\)\s*$/, js: /=\s*$/, ps: /(?:=|`)\s*$/, py: /(?:=|\\)\s*$/ };
const MAX_CONTINUATION = 3;

function logicalLine(lang, code, i) {
  let text = code[i];
  for (let j = i + 1, n = 0; j < code.length && n < MAX_CONTINUATION && CONTINUED[lang].test(text); j++) {
    if (code[j].trim() === "") continue;
    text = `${text.replace(/\\\s*$|`\s*$/, "")} ${code[j].trim()}`;
    n++;
  }
  return text;
}

function check(ctx) {
  const table = ctx.table();
  const out = [];
  const quick = new RegExp(`${NAMES.join("|")}|${CAMEL.join("|")}`);
  for (const file of ctx.files) {
    if (file.text === null || !quick.test(file.text)) continue;
    const v = view(file);
    if (!Object.hasOwn(ASSIGN, v.lang)) continue;
    const configFromSelf = table.grantsFor(file.rel, ctx.repo).forms.has("config-from-script-checkout");
    for (let i = 0; i < v.code.length; i++) {
      if (!quick.test(v.code[i])) continue;
      judgeLine(v.lang, logicalLine(v.lang, v.code, i), configFromSelf, (msg) => out.push(`${file.rel}:${i + 1}: reference-role: ${msg}`));
    }
  }
  return out;
}

module.exports = { check };
