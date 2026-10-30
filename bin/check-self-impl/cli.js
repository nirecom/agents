#!/usr/bin/env node
"use strict";
// check-self-impl: report a test that builds its own harness through the caseEmbedRules self-impl
// op (#2507 D7; the verdict lives in hooks/lib/test-gates/self-impl-judge.js).
//   check-self-impl.sh [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]]] <file>... | --manifest <m>
// Two heads (a merge, #2812) count head1 + head2 - base per key. --manifest lines are
// "<rel>\t<copy>[\t<head1>[\t<head2>[\t<base>]]]". Exit 0 no HIGH, 1 a HIGH, 2 usage, a missing
// file, the registry unreadable or an op failure.

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const { judge } = require("../../hooks/lib/test-gates/self-impl-judge");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");
const { nativeMap } = require("./msys-paths");

const ME = "check-self-impl.sh";
const USAGE = `Usage: ${ME} [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]]] <file>... | --manifest <manifest>`;

class Exit extends Error {
  constructor(rc) {
    super(`exit ${rc}`);
    this.rc = rc;
  }
}

function parse(argv, err) {
  const usage = (msg) => {
    err(USAGE);
    if (msg) err(`${ME}: ${msg}`);
    throw new Exit(2);
  };
  const o = { rel: "", head: "", head2: "", base: "", manifest: "", files: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const value = (key) => {
      if (i + 1 >= argv.length || !argv[i + 1]) usage(`--${key} needs a value`);
      const v = argv[i + 1];
      i += 1;
      return v;
    };
    if (a === "--rel" || a === "--base" || a === "--manifest") o[a.slice(2)] = value(a.slice(2));
    else if (a === "--head") {
      const v = value("head");
      if (!o.head) o.head = v;
      else if (!o.head2) o.head2 = v;
      else usage("--head takes at most two copies");
    } else if (a === "--") {
      o.files.push(...argv.slice(i + 1));
      break;
    } else if (a.startsWith("-")) usage(`unknown option: ${a}`);
    else o.files.push(a);
  }
  if (o.manifest) {
    if (o.rel || o.head || o.files.length) usage("--manifest takes no --rel, --head or file");
    if (o.base) usage("--manifest takes no --base");
  } else {
    if (!o.files.length) usage();
    if (o.base && !o.head2) usage("--base needs two --head copies");
    if (o.rel && o.files.length !== 1) usage("--rel takes exactly one file");
    if (o.head && o.files.length !== 1) usage("--head takes exactly one file");
  }
  return { o, usage };
}

// manifestRows(text) — [rel, copy, head1, head2, base] per line as `IFS=$'\t' read -r rel copy head
// head2 base` reads it (repeated tabs collapse; a later column only exists with the one before it).
function manifestRows(text) {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines.map((l) => {
    const f = l.replace(/^\t+|\t+$/g, "").split(/\t+/);
    const tail = f.slice(4).join("\t");
    return [f[0] || "", f[1] || "", f[2] || "", f[3] || "", tail];
  });
}

function main({ argv, cwd, env, stdout, stderr }) {
  const out = (l) => stdout.write(`${l}\n`);
  const err = (l) => stderr.write(`${l}\n`);
  if (!R.tryReg()) {
    err(`${ME}: registry unreadable`);
    return 2;
  }
  let native = new Map();
  const abs = (p) => path.resolve(toWindowsPath(cwd), native.get(p) || toWindowsPath(p));
  const isFile = (p) => {
    try {
      return fs.statSync(abs(p)).isFile();
    } catch {
      return false;
    }
  };
  const notFound = (p) => {
    err(`${ME}: file not found: ${p}`);
    throw new Exit(2);
  };
  const state = { high: false, infra: false };
  const need = (...copies) => copies.forEach((c) => { if (c && !isFile(c)) notFound(c); });
  const check = (file, rel, head, head2, base) => {
    if (!isFile(file)) notFound(file);
    const heads = [head, head2].filter(Boolean).map(abs);
    const j = judge({ name: rel || file, file: abs(file), heads, base: base && head2 ? abs(base) : null });
    for (const l of j.lines) (l.err ? err : out)(l.text);
    if (j.high) state.high = true;
    if (j.infra) state.infra = true;
  };
  try {
    const { o, usage } = parse(argv, err);
    if (o.manifest) {
      if (!isFile(o.manifest)) notFound(o.manifest);
      const rows = manifestRows(fs.readFileSync(abs(o.manifest), "utf8"));
      native = nativeMap(rows.flatMap(([, ...copies]) => copies), env);
      for (const [rel, copy, head, head2, base] of rows) {
        if (!rel) continue;
        if (!copy) usage(`malformed manifest line: ${rel}`);
        need(head, head2, base);
        check(copy, rel, head, head2, base);
      }
    } else {
      need(o.head, o.head2, o.base);
      for (const f of o.files) check(f, o.rel, o.head, o.head2, o.base);
    }
  } catch (e) {
    if (e instanceof Exit) return e.rc;
    throw e;
  }
  if (state.high) return 1;
  return state.infra ? 2 : 0;
}

function run({ argv = [], cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr } = {}) {
  return R.withEnv(env, () => main({ argv, cwd, env, stdout, stderr }));
}

if (require.main === module) process.exitCode = run({ argv: process.argv.slice(2) });

module.exports = { run, manifestRows };
