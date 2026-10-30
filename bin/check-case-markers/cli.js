#!/usr/bin/env node
"use strict";
// check-case-markers: case-marker placement in test files that cover several Tests: paths
// (#2507 D7; the verdict lives in hooks/lib/test-gates/case-markers.js).
//   check-case-markers.sh [--rel <rel>] <file1> [file2 ...]
// Exit 0 no HIGH, 1 a HIGH / no file / a missing file, 2 a reader unavailable or a bad --rel.

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const { judge } = require("../../hooks/lib/test-gates/case-markers");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const ME = "check-case-markers.sh";

function main({ argv, cwd, stdout, stderr }) {
  const err = (l) => stderr.write(`${l}\n`);
  let args = argv;
  let rel = "";
  if (args[0] === "--rel") {
    if (args.length < 2 || !args[1]) {
      err(`${ME}: --rel needs a value`);
      return 2;
    }
    rel = args[1];
    args = args.slice(2);
  }
  if (args.length === 0) {
    err(`Usage: ${ME} <file1> [file2 ...]`);
    return 1;
  }
  if (rel && args.length !== 1) {
    err(`${ME}: --rel takes exactly one file`);
    return 2;
  }
  let high = false;
  let readerFailed = false;
  for (const file of args) {
    const abs = path.resolve(toWindowsPath(cwd), toWindowsPath(file));
    let isFile = false;
    try {
      isFile = fs.statSync(abs).isFile();
    } catch {
      isFile = false;
    }
    if (!isFile) {
      err(`${ME}: file not found: ${file}`);
      return 1;
    }
    const j = judge(abs, rel || file);
    for (const l of j.lines) (l.err ? stderr : stdout).write(`${l.text}\n`);
    if (j.high) high = true;
    if (j.readerFailed) readerFailed = true;
  }
  if (high) return 1;
  return readerFailed ? 2 : 0;
}

function run({ argv = [], cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr } = {}) {
  return R.withEnv(env, () => main({ argv, cwd, stdout, stderr }));
}

if (require.main === module) process.exitCode = run({ argv: process.argv.slice(2) });

module.exports = { run };
