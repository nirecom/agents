#!/usr/bin/env node
"use strict";
// check-test-language-match: report a test written in another language than the code it tests
// (#2507 D7; the verdict lives in hooks/lib/test-gates/language-match.js).
//   check-test-language-match.sh [--rel <rel>] [--head <head-copy>] <file>...
// Exit 0 no HIGH, 1 a HIGH, 2 usage, a missing file or the registry unreadable.

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const LM = require("../../hooks/lib/test-gates/language-match");
const G = require("../../hooks/lib/test-gates/git-blobs");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const ME = "check-test-language-match.sh";
const USAGE = `Usage: ${ME} [--rel <rel>] [--head <head-copy>] <file>...`;

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
  const o = { rel: "", head: "", files: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--rel" || a === "--head") {
      if (i + 1 >= argv.length || !argv[i + 1]) usage(`${a} needs a value`);
      o[a.slice(2)] = argv[i + 1];
      i += 1;
    } else if (a === "--") {
      o.files.push(...argv.slice(i + 1));
      break;
    } else if (a.startsWith("-")) usage(`unknown option: ${a}`);
    else o.files.push(a);
  }
  if (!o.files.length) usage();
  if (o.rel && o.files.length !== 1) usage("--rel takes exactly one file");
  if (o.head && o.files.length !== 1) usage("--head takes exactly one file");
  return o;
}

function main({ argv, cwd, env, stdout, stderr }) {
  const err = (l) => stderr.write(`${l}\n`);
  if (!R.tryReg()) {
    err(`${ME}: registry unreadable`);
    return 2;
  }
  const abs = (p) => path.resolve(toWindowsPath(cwd), toWindowsPath(p));
  const isFile = (p) => {
    try {
      return fs.statSync(abs(p)).isFile();
    } catch {
      return false;
    }
  };
  let violation = false;
  let infra = false;
  try {
    const o = parse(argv, err);
    if (o.head && !isFile(o.head)) {
      err(`${ME}: head copy not found: ${o.head}`);
      return 2;
    }
    const root = G.toplevel(cwd, env) || cwd;
    for (const file of o.files) {
      if (!isFile(file)) {
        err(`${ME}: file not found: ${file}`);
        return 2;
      }
      const r = LM.check(abs(file), o.rel || file, o.head ? abs(o.head) : null, { root });
      for (const l of r.lines) (l.err ? stderr : stdout).write(`${l.text}\n`);
      if (r.violation) violation = true;
      if (r.infra) infra = true;
    }
  } catch (e) {
    if (e instanceof Exit) return e.rc;
    throw e;
  }
  if (violation) return 1;
  return infra ? 2 : 0;
}

function run({ argv = [], cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr } = {}) {
  return R.withEnv(env, () => main({ argv, cwd, env, stdout, stderr }));
}

if (require.main === module) process.exitCode = run({ argv: process.argv.slice(2) });

module.exports = { run };
