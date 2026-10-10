"use strict";

// Structural check (#2561): what a root name may be joined to, where the checkout root
// may cross a process boundary, who may write a carrier, and who may leave the decoy.
// Patterns are built from the name constants, so this file holds none of the shapes.

const { view, splitCommand, declared, isTest, escapeRe } = require("./line-scan");
const { spellings, SCR, AMR } = require("./table-match");

const IN_SCOPE = /^(?:bin|hooks|tests)\/|^skills\/(?:.*\/)?scripts\//;
const CODE_DIRS = "(bin|hooks|skills)";
const LEAVE_DECOY = ["root", "decoy", "use", "real", "main", "root"].join("_");
const CAMEL = spellings(SCR).camel;

// The agents root followed by a code directory: "$X/bin", `${X}/hooks`, join(X, "skills").
const SUBPATH_RE = new RegExp(`(?<![A-Za-z0-9_])${AMR}\\}?["']?(?:[\\\\/]|["'\`][\\\\/]|\\s*[,+]\\s*["'\`][\\\\/]?)${CODE_DIRS}(?![\\w-])`);
const JS_ENV_WRITE = new RegExp(`process\\.env(?:\\.${SCR}|\\[["']${SCR}["']\\])\\s*=(?!=)`);
const JS_ENV_KEY = new RegExp(`(?:^\\s*|[{,]\\s*)["']?${SCR}["']?\\s*:(?!:)`);
const PS_ENV_WRITE = new RegExp(`\\$env:${SCR}\\s*=(?!=)`, "i");
// A parameter named after the checkout root, with or without a modifier around it.
const PARAM_RE = new RegExp(`^(?:(?:[a-z][A-Za-z0-9]*${CAMEL[0].toUpperCase()}|${CAMEL[0]})${CAMEL.slice(1)}[A-Za-z0-9]*|${SCR})$`);
const NOT_A_FUNCTION = new Set(["if", "for", "while", "switch", "catch", "with", "return", "function", "await", "typeof"]);
const PARAM_LISTS = [
  /\bfunction\b\s*\*?\s*[A-Za-z0-9_$]*\s*\(([^)]*)\)/g,
  /\(([^()]*)\)\s*=>/g,
  /(?<![\w$.])([A-Za-z_$][\w$]*)\s*=>/g,
];
const METHOD_RE = /(?:^|[\s,{;])(?:async\s+)?([A-Za-z_$][\w$]*)\s*\(([^()]*)\)\s*\{/g;

function paramsOf(line) {
  const lists = [];
  for (const re of PARAM_LISTS) for (const m of line.matchAll(re)) lists.push(m[1]);
  for (const m of line.matchAll(METHOD_RE)) if (!NOT_A_FUNCTION.has(m[1])) lists.push(m[2]);
  const names = [];
  for (const list of lists) {
    for (const part of list.split(",")) names.push(...(part.replace(/=.*$/, "").match(/[A-Za-z_$][\w$]*/g) || []));
  }
  return names;
}

function shHandover(cmds) {
  for (const words of cmds) {
    const { assigns, word, args } = splitCommand(words);
    if (word === "export" || word === "declare" || word === "typeset") {
      const exported = word === "export" || args.some((a) => /^-[a-zA-Z]*x/.test(a));
      if (exported && declared(args).some((d) => d.name === SCR)) return "it is exported";
    }
    const prefixed = assigns.includes(SCR) || (word === "env" && args.some((a) => a.startsWith(`${SCR}=`)));
    // An inline -e / -c program is the same file's code, not another script.
    if (word !== null && prefixed && !args.some((a) => a === "-e" || a === "-c")) return "it is handed to another command";
  }
  return null;
}

// inDestructuring(line, index) — the position sits in a `const { a: b } = x` pattern (a read).
function inDestructuring(line, index) {
  for (const m of line.matchAll(/(?:const|let|var)\s*\{[^}]*\}\s*=(?!=)/g)) {
    if (index >= m.index && index < m.index + m[0].length) return true;
  }
  return false;
}

function carrierWrites(table, rel, v, i) {
  const out = [];
  const line = v.code[i];
  for (const c of table.carriers) {
    if (c.source === rel || !line.includes(c.token)) continue;
    const t = escapeRe(c.token);
    if (c.kind === "property") {
      const key = new RegExp(`(?:^\\s*|[{,]\\s*)["']?${t}["']?\\s*:(?!:)`).exec(line);
      const written = new RegExp(`\\.${t}\\s*=(?![=>])`).test(line) || (key && !inDestructuring(line, key.index));
      if (written) out.push("only the source of this carrier writes the property");
    } else if (c.kind === "function") {
      const defined = new RegExp(`\\bfunction\\s+${t}\\s*\\(|(?:const|let|var)\\s+${t}\\s*=(?!=)(?!\\s*require\\()`).test(line);
      if (defined) out.push("only the source of this carrier defines the function");
    }
  }
  return out;
}

// payloadKey(ctx, table) — the key is declared in its source, and a listed script that
// reads the key compares it with the property carrier.
function payloadKey(ctx, table) {
  const out = [];
  const property = table.carriers.find((c) => c.kind === "property");
  for (const c of table.carriers.filter((x) => x.kind === "payload-key")) {
    for (const file of ctx.files) {
      if (file.text === null) continue;
      if (file.rel === c.source) {
        if (!file.text.includes(c.token)) out.push(`${file.rel}: structural: the source of the payload key does not declare it`);
      } else if (c.files.has(file.rel) && view(file).lang === "js" && file.text.includes(c.token)) {
        if (!property || !file.text.includes(property.carrier)) {
          out.push(`${file.rel}: structural: a script that reads the payload key must compare it with its own checkout root`);
        }
      }
    }
  }
  return out;
}

function check(ctx) {
  const table = ctx.table();
  const out = ctx.repo === "agents" ? payloadKey(ctx, table) : [];
  for (const file of ctx.files) {
    if (file.text === null || !IN_SCOPE.test(file.rel)) continue;
    const v = view(file);
    if (v.lang !== "sh" && v.lang !== "js" && v.lang !== "ps") continue;
    const forms = table.grantsFor(file.rel, ctx.repo).forms;
    const say = (i, msg) => out.push(`${file.rel}:${i + 1}: structural: ${msg}`);
    for (let i = 0; i < v.code.length; i++) {
      const line = v.code[i];
      if (line.includes(AMR) && !forms.has("agents-root-subpath") && SUBPATH_RE.test(line)) {
        say(i, "the agents root is joined to a code directory; code comes from the script's own checkout");
      }
      if (line.includes(SCR)) {
        let how = null;
        if (v.lang === "sh") how = shHandover(v.cmds[i]);
        else if (v.lang === "js" && (JS_ENV_WRITE.test(line) || JS_ENV_KEY.test(line))) how = "it is put into an environment";
        else if (v.lang === "ps" && PS_ENV_WRITE.test(line)) how = "it is put into the environment";
        if (how) say(i, `the checkout root stays inside its own process, but ${how}`);
      }
      if (v.lang === "js") {
        if (!isTest(file.rel) && paramsOf(v.bare[i]).some((p) => PARAM_RE.test(p))) {
          say(i, "a function takes the checkout root as a parameter; each file derives its own");
        }
        if (ctx.repo === "agents" && !isTest(file.rel)) for (const msg of carrierWrites(table, file.rel, v, i)) say(i, msg);
      }
      if (v.lang === "sh" && line.includes(LEAVE_DECOY) && !forms.has("leave-decoy")) {
        const called = v.cmds[i].some((words) => splitCommand(words).word === LEAVE_DECOY);
        const definition = new RegExp(`^\\s*(?:function\\s+)?${LEAVE_DECOY}\\s*\\(\\s*\\)`).test(line);
        if (called && !definition) say(i, "leaving the decoy needs a named exception in the classification table");
      }
    }
  }
  return out;
}

module.exports = { check };
