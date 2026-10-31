"use strict";
// comment-block-size check (#2507, #1894): blocks only on the scanner's rc 1; any other rc is an
// outage that leaves the commit alone with a diagnostic. COMMENT_BLOCK_ENFORCE is read from
// <cfgDir>/.env only, so an ambient export cannot switch the gate off.

const fs = require("fs");
const path = require("path");
const { out, err, linesOf } = require("../output");
const { fromCfg, captureStreams } = require("../lib/support");
const { readConfig } = require("../../lib/comment-block-review/config");

const CLI_MODULE = "bin/review-comment-block-size.d/cli.js";

async function run({ context, files, narrowed }) {
  const cliPath = path.join(context.cfgDir, CLI_MODULE);
  if (!fs.existsSync(cliPath)) return { verdict: "pass", messages: [] };
  if (readConfig(context.cfgDir).enforce === "off") {
    return { verdict: "pass", messages: [err("pre-commit: comment-block size gate disabled by COMMENT_BLOCK_ENFORCE=off")] };
  }
  const cap = captureStreams();
  const rc = await fromCfg(context.cfgDir, CLI_MODULE).run({ argv: ["--staged"], cwd: context.repoTop, env: context.env || process.env, stdout: cap.stdout, stderr: cap.stderr, cfgDir: context.cfgDir, only: narrowed ? files : undefined });
  const lines = linesOf(cap.text());
  if (rc === 1) {
    return {
      verdict: "block",
      messages: [...lines.map(out), out(""), out("Commit blocked: staged code carries over-threshold comment blocks."),
        out("Compress them, or see rules/coding/file-split.md (Pattern A).")],
    };
  }
  if (rc !== 0) {
    return { verdict: "pass", messages: [err(`pre-commit: review-comment-block-size rc=${rc} — comment-block check incomplete (commit continues)`), ...lines.map(err)] };
  }
  if (lines.some((l) => l.includes(": SKIPPED"))) {
    return { verdict: "pass", messages: [err("pre-commit: comment-block size check SKIPPED — scanner did not run (commit continues)")] };
  }
  return { verdict: "pass", messages: [] };
}

module.exports = { run };
