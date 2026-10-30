#!/usr/bin/env node
"use strict";
// check-test-language-match: report a test written in another language than the code it tests
// (#2507 D7; the verdict lives in hooks/lib/test-gates/language-match.js).
//   check-test-language-match.sh [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]]
//     | --declaration-only] <file>...
// Two heads (a merge, #2812) judge the 3-way against both and --base; --declaration-only validates
// only the declaration (a file equal to a parent). Exit 0 no HIGH, 1 a HIGH, 2 usage, a missing
// file or the registry unreadable.

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const LM = require("../../hooks/lib/test-gates/language-match");
const G = require("../../hooks/lib/test-gates/git-blobs");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const ME = "check-test-language-match.sh";
const USAGE = `Usage: ${ME} [--rel <rel>] [--head <copy> [--head <copy> [--base <copy>]] | --declaration-only] <file>...`;

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
  const o = { rel: "", head: "", head2: "", base: "", declOnly: false, files: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--rel" || a === "--head" || a === "--base") {
      if (i + 1 >= argv.length || !argv[i + 1]) usage(`${a} needs a value`);
      const v = argv[i + 1];
      i += 1;
      if (a !== "--head") o[a.slice(2)] = v;
      else if (!o.head) o.head = v;
      else if (!o.head2) o.head2 = v;
      else usage("--head takes at most two copies");
    } else if (a === "--declaration-only") o.declOnly = true;
    else if (a === "--") {
      o.files.push(...argv.slice(i + 1));
      break;
    } else if (a.startsWith("-")) usage(`unknown option: ${a}`);
    else o.files.push(a);
  }
  if (!o.files.length) usage();
  if (o.declOnly && (o.head || o.base)) usage("--declaration-only takes no --head or --base");
  if (o.base && !o.head2) usage("--base needs two --head copies");
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
    for (const copy of [o.head, o.head2, o.base]) {
      if (copy && !isFile(copy)) {
        err(`${ME}: head copy not found: ${copy}`);
        return 2;
      }
    }
    const root = G.toplevel(cwd, env) || cwd;
    const head = o.head2 ? [abs(o.head), abs(o.head2)] : o.head ? abs(o.head) : null;
    const opts = { root, base: o.base ? abs(o.base) : null, declarationOnly: o.declOnly };
    for (const file of o.files) {
      if (!isFile(file)) {
        err(`${ME}: file not found: ${file}`);
        return 2;
      }
      const r = LM.check(abs(file), o.rel || file, head, opts);
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
