#!/usr/bin/env node
"use strict";
// check-self-impl: report a test that builds its own harness through the caseEmbedRules self-impl
// op (#2507 D7; the verdict lives in hooks/lib/test-gates/self-impl-judge.js).
//   check-self-impl.sh [--rel <rel>] [--head <head-copy>] <file>... | --manifest <manifest>
// --manifest lines are "<rel>\t<copy>\t<head-copy or empty>". Exit 0 no HIGH, 1 a HIGH, 2 usage,
// a missing file, the registry unreadable or an op failure.

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const { judge } = require("../../hooks/lib/test-gates/self-impl-judge");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");
const { nativeMap } = require("./msys-paths");

const ME = "check-self-impl.sh";
const USAGE = `Usage: ${ME} [--rel <rel>] [--head <head-copy>] <file>... | --manifest <manifest>`;

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
  const o = { rel: "", head: "", manifest: "", files: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const value = (key) => {
      if (i + 1 >= argv.length || !argv[i + 1]) usage(`--${key} needs a value`);
      o[key] = argv[i + 1];
      i += 1;
    };
    if (a === "--rel" || a === "--head" || a === "--manifest") value(a.slice(2));
    else if (a === "--") {
      o.files.push(...argv.slice(i + 1));
      break;
    } else if (a.startsWith("-")) usage(`unknown option: ${a}`);
    else o.files.push(a);
  }
  if (o.manifest) {
    if (o.rel || o.head || o.files.length) usage("--manifest takes no --rel, --head or file");
  } else {
    if (!o.files.length) usage();
    if (o.rel && o.files.length !== 1) usage("--rel takes exactly one file");
    if (o.head && o.files.length !== 1) usage("--head takes exactly one file");
  }
  return { o, usage };
}

// manifestRows(text) — [rel, copy, head] per line as `IFS=$'\t' read -r rel copy head` reads it.
function manifestRows(text) {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines.map((l) => {
    const m = /^([^\t]*)(?:\t+([^\t]*)(?:\t+(.*))?)?$/s.exec(l.replace(/^\t+|\t+$/g, ""));
    return [m[1], m[2] || "", m[3] || ""];
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
  const check = (file, rel, head) => {
    if (!isFile(file)) notFound(file);
    const j = judge({ name: rel || file, file: abs(file), head: head ? abs(head) : null });
    for (const l of j.lines) (l.err ? err : out)(l.text);
    if (j.high) state.high = true;
    if (j.infra) state.infra = true;
  };
  try {
    const { o, usage } = parse(argv, err);
    if (o.manifest) {
      if (!isFile(o.manifest)) notFound(o.manifest);
      const rows = manifestRows(fs.readFileSync(abs(o.manifest), "utf8"));
      native = nativeMap(rows.flatMap(([, copy, head]) => [copy, head]), env);
      for (const [rel, copy, head] of rows) {
        if (!rel) continue;
        if (!copy) usage(`malformed manifest line: ${rel}`);
        if (head && !isFile(head)) notFound(head);
        check(copy, rel, head);
      }
    } else {
      if (o.head && !isFile(o.head)) notFound(o.head);
      for (const f of o.files) check(f, o.rel, o.head);
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
