"use strict";
// The code language of a Tests: token (#2507 D7; was _trl_token_index in
// bin/lib/test-route-destination/language.sh): by codeLanguage.sourcePatterns on the basename,
// supported entries in table order; else, for an extensionless file read from the working
// tree, by the interpreter its shebang line names.

const fs = require("fs");
const path = require("path");
const R = require("./registry");
const { toWindowsPath } = require("../branch-diff");

// A registry glob as bash [[ == ]] reads it: `*` is any run, empty included.
const globRe = (g) => new RegExp(`^${g.split("*").map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[\\s\\S]*")}$`);

function supported() {
  return R.reg().entries.filter((e) => e.status === "supported");
}

// The shebang's command name: the first word's basename, past `env` and its options.
function shebangCommand(file) {
  let text;
  try {
    if (!fs.statSync(file).isFile()) return "";
    fs.accessSync(file, fs.constants.R_OK);
    text = fs.readFileSync(file, "latin1");
  } catch {
    return "";
  }
  const nl = text.indexOf("\n");
  const first = (nl === -1 ? text : text.slice(0, nl)).replace(/\r$/, "");
  if (!first.startsWith("#!")) return "";
  const words = first.slice(2).split(/[ \t\n]+/).filter(Boolean);
  const base = (w) => (w === undefined ? "" : w.slice(w.lastIndexOf("/") + 1));
  let cmd = base(words[0]);
  if (cmd === "env") {
    let w = 1;
    while (w < words.length && (words[w].startsWith("-") || words[w].includes("="))) w += 1;
    cmd = base(words[w]);
  }
  return cmd;
}

// tokenLanguage(token, { root }) -> the entry id of the token's code language, or null.
function tokenLanguage(token, opts = {}) {
  const t = String(token);
  const name = t.slice(t.lastIndexOf("/") + 1);
  const entries = supported();
  for (const e of entries) {
    const pats = (e.codeLanguage && e.codeLanguage.sourcePatterns) || [];
    if (pats.some((p) => globRe(p).test(name))) return e.id;
  }
  if (name.includes(".")) return null;
  const file = opts.root ? path.join(toWindowsPath(String(opts.root)), t) : toWindowsPath(t);
  const cmd = shebangCommand(file);
  if (!cmd) return null;
  for (const e of entries) {
    if (((e.codeLanguage && e.codeLanguage.shebangInterpreters) || []).includes(cmd)) return e.id;
  }
  return null;
}

module.exports = { tokenLanguage, globRe };
