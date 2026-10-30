#!/usr/bin/env node
"use strict";
// CLI adapter of the comment-block size review (#2507): review-comment-block-size [--staged | --all].
// Exit: 0 performed or skipped; 1 BLOCK (--staged only); 3 internal error. The review itself and
// its settings live in hooks/lib/comment-block-review/.

const path = require("path");
const { review, HDR } = require("../../hooks/lib/comment-block-review/review");
const { cliCfgDir } = require("../../hooks/lib/comment-block-review/config");

const CFG_DIR = path.resolve(__dirname, "..", "..");

function parseMode(argv) {
  let all = false;
  let staged = false;
  let bad = false;
  for (const a of argv) {
    if (a === "--all") all = true;
    else if (a === "--staged") staged = true;
    else bad = true;
  }
  if (all && staged) return { skip: "--staged and --all are mutually exclusive" };
  if (bad) return { skip: "unrecognized argument" };
  if (!all && !staged) return { skip: "no mode selected (use --staged or --all)" };
  return { mode: staged ? "staged" : "all" };
}

// run({ argv, cwd, env, stdout, stderr, cfgDir, only }) -> rc; pre-commit passes its own cfgDir
// and the staged paths it may review (only), a standalone run resolves cfgDir like the bash CLI did.
function run({ argv = [], cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr, cfgDir, only } = {}) {
  const m = parseMode(argv);
  const dir = cfgDir || cliCfgDir(env, CFG_DIR);
  const { lines, rc } = m.skip
    ? { lines: [`${HDR}: SKIPPED — ${m.skip}`], rc: 0 }
    : review({ mode: m.mode, cwd, env, cfgDir: dir, stderr, only });
  stdout.write(lines.map((l) => `${l}\n`).join(""));
  return rc;
}

module.exports = { run };

if (require.main === module) process.exitCode = run({ argv: process.argv.slice(2) });
