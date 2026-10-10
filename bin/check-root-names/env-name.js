"use strict";

// Env-name check (#2561): the agents root is an environment variable only — never a
// local — and is given a value in tests and named exceptions only; the other three
// names never become environment variables. Each file is read in its own language.

const { view, splitCommand, declared, isTest } = require("./line-scan");
const { SCR, AMR, TMR, TCR } = require("./table-match");

const LOCAL_DECLARERS = new Set(["local", "readonly", "declare", "typeset"]);
const NEVER_ENV = [SCR, TMR, TCR];
const TARGETS = [TMR, TCR];
const W = "[A-Za-z0-9_$]";
const any = (names) => `(?:${names.join("|")})`;
const envRef = (names) => `process\\.env(?:\\.${any(names)}(?!${W})|\\[["']${any(names)}["']\\])`;
const objectKey = (names) => new RegExp(`(?:^\\s*|[{,]\\s*)["']?${any(names)}["']?\\s*:(?!:)`);

const JS_LOCAL = new RegExp(`(?:const|let|var)\\s+${AMR}(?!${W})|(?<![\\w$.])${AMR}\\s*=(?![=>])`);
const JS_DESTRUCTURED = new RegExp(`(?:const|let|var)\\s*\\{[^}]*(?<![\\w$.])${AMR}(?!${W})(?!\\s*:)[^}]*\\}`);
const JS_SET = new RegExp(`${envRef([AMR])}\\s*=(?!=)`);
const JS_KEY = objectKey([AMR]);
const JS_NEVER_REF = new RegExp(envRef(NEVER_ENV));
const JS_NEVER_KEY = objectKey(TARGETS);
// A target name bound from, or spread next to, process.env is an environment read or hand-over.
const JS_NEVER_BOUND = new RegExp(`\\{[^}]*(?<!${W})${any(TARGETS)}(?!${W})[^}]*\\}\\s*=\\s*process\\.env(?!${W})`);
const JS_NEVER_SPREAD = new RegExp(`\\{[^}]*\\.\\.\\.process\\.env(?!${W})[^}]*(?<!${W})${any(TARGETS)}\\s*[,}]`);
const unquoted = (word) => word.replace(/^["']/, "");
const PS_LOCAL = new RegExp(`(?<![\\w:])\\$${AMR}\\s*=(?!=)`, "i");
const PS_SET = new RegExp(`\\$env:${AMR}\\s*=(?!=)|SetEnvironmentVariable\\(\\s*["']${AMR}["']`, "i");
const PS_NEVER_REF = new RegExp(`\\$\\{?env:${any(NEVER_ENV)}(?!\\w)|EnvironmentVariable\\(\\s*["']${any(NEVER_ENV)}["']`, "i");
const YAML_KEY = new RegExp(`^\\s*(?:-\\s*)?["']?${AMR}["']?\\s*:`);
const JSON_KEY = new RegExp(`"${AMR}"\\s*:`);

const LOCAL = "the agents root is an environment variable, never a local variable";
const SET = "the agents root is given a value here, but this file is neither a test nor a named exception";
const NEVER = "this root name never becomes an environment variable";

// inDestructuring(line, index) — the position sits in a `const { a: b } = x` pattern (a read).
function inDestructuring(line, index) {
  for (const m of line.matchAll(/(?:const|let|var)\s*\{[^}]*\}\s*=(?!=)/g)) {
    if (index >= m.index && index < m.index + m[0].length) return true;
  }
  return false;
}

// Each reader returns the findings of one line as a list of "local" / "set" / "never".
function shell(cmds) {
  const found = [];
  for (const words of cmds) {
    const { assigns, word, args } = splitCommand(words);
    const names = word === null ? [] : declared(args).map((d) => d.name);
    // `env` may sit behind a wrapper (`timeout 60 env NAME=v cmd`), and its words may be quoted.
    const envAt = word === "env" ? 0 : args.indexOf("env") + 1;
    const viaEnv = (n) => (word === "env" || envAt > 0) && args.slice(envAt).some((a) => unquoted(a).startsWith(`${n}=`));
    const handed = (n) => assigns.includes(n) || viaEnv(n);
    // A quoted "NAME=value" standing where a command starts is an element of an env array.
    const element = (n) => word !== null && word !== unquoted(word) && unquoted(word).startsWith(`${n}=`);
    if (word !== null && TARGETS.some((n) => handed(n) || element(n))) found.push("never");
    if (word === null) {
      if (assigns.includes(AMR)) found.push("local");
    } else if (LOCAL_DECLARERS.has(word)) {
      if (names.includes(AMR)) found.push("local");
      if (args.some((a) => /^-[A-Za-z]*x/.test(a)) && names.some((n) => NEVER_ENV.includes(n))) found.push("never");
    } else if (word === "read") {
      if (args.includes(AMR)) found.push("local");
    } else if (word === "for") {
      if (args[0] === AMR) found.push("local");
    } else if (word === "export") {
      if (names.includes(AMR)) found.push("set");
      if (names.some((n) => NEVER_ENV.includes(n))) found.push("never");
    } else if (handed(AMR)) {
      found.push("set");
    }
  }
  return found;
}

function node(code, bare) {
  const found = [];
  if (JS_LOCAL.test(bare) || JS_DESTRUCTURED.test(bare)) found.push("local");
  const key = JS_KEY.exec(code);
  if (JS_SET.test(code) || (key && !inDestructuring(code, key.index))) found.push("set");
  const neverKey = JS_NEVER_KEY.exec(code);
  const neverRead = JS_NEVER_REF.test(code) || JS_NEVER_BOUND.test(code) || JS_NEVER_SPREAD.test(code);
  if (neverRead || (neverKey && !inDestructuring(code, neverKey.index))) found.push("never");
  return found;
}

function powershell(code) {
  const found = [];
  if (PS_LOCAL.test(code)) found.push("local");
  if (PS_SET.test(code)) found.push("set");
  if (PS_NEVER_REF.test(code)) found.push("never");
  return found;
}

function check(ctx) {
  const table = ctx.table();
  const out = [];
  for (const file of ctx.files) {
    if (file.text === null || !NEVER_ENV.concat(AMR).some((n) => file.text.includes(n))) continue;
    const v = view(file);
    if (v.lang === "prose" || v.lang === "other" || v.lang === "binary") continue;
    const maySet = isTest(file.rel) || table.grantsFor(file.rel, ctx.repo).forms.has("set-agents-root");
    for (let i = 0; i < v.code.length; i++) {
      const line = v.code[i];
      let found = [];
      if (v.lang === "sh") found = shell(v.cmds[i]);
      else if (v.lang === "js") found = node(line, v.bare[i]);
      else if (v.lang === "ps") found = powershell(line);
      else if (v.lang === "yaml" ? YAML_KEY.test(line) : JSON_KEY.test(line)) found = ["set"];
      const at = `${file.rel}:${i + 1}: env-name:`;
      if (found.includes("local")) out.push(`${at} ${LOCAL}`);
      if (found.includes("set") && !maySet) out.push(`${at} ${SET}`);
      if (found.includes("never")) out.push(`${at} ${NEVER}`);
    }
  }
  return out;
}

module.exports = { check };
