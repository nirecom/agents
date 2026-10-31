#!/usr/bin/env node
"use strict";

// bin/list-staged-review-paths.js — the staged listing /review-tests RT-1 / RT-1a read (#2842).
// Usage: list-staged-review-paths.js --repo <dir> [--added-only]
// Stdout: `git diff --cached --name-only` (`--diff-filter=A` with --added-only), one path per
// line, minus merge-incoming paths (dropMergeIncomingPaths, the review-scope SSOT). Docs are
// not excluded here. Exit: 0 ok; 2 usage; 1 git failure.

const { spawnSync } = require("child_process");
const { dropMergeIncomingPaths } = require("../hooks/workflow-gate/review-tests-evidence");
const { toWindowsPath } = require("../hooks/lib/branch-diff");

const NAME = "list-staged-review-paths";

function parseArgs(argv) {
  const out = { repo: null, addedOnly: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--repo" && i + 1 < argv.length) out.repo = argv[++i];
    else if (a === "--added-only") out.addedOnly = true;
    else return { error: `unknown or incomplete argument: ${a}` };
  }
  if (!out.repo) return { error: "--repo <dir> is required" };
  return out;
}

function main(argv) {
  const args = parseArgs(argv);
  if (args.error) {
    process.stderr.write(`${NAME}: ${args.error}\n`);
    return 2;
  }
  const repo = toWindowsPath(args.repo);
  const gitArgs = ["diff", "--cached", "--name-only", "-z"];
  if (args.addedOnly) gitArgs.push("--diff-filter=A");
  const res = spawnSync("git", gitArgs, { cwd: repo, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, windowsHide: true });
  if (res.error || res.status !== 0) {
    const why = res.error ? res.error.message : String(res.stderr || "").trim();
    process.stderr.write(`${NAME}: git diff --cached failed: ${why}\n`);
    return 1;
  }
  const staged = res.stdout.split("\0").filter(Boolean);
  // One path per line is the output contract; a newline inside a path would split it into two
  // phantom paths for RT-1 / RT-1a, so refuse (fail-closed) rather than misreport the scope.
  const bad = staged.find((p) => p.includes("\n"));
  if (bad !== undefined) {
    process.stderr.write(`${NAME}: staged path contains a newline, which the line-based listing cannot represent: ${JSON.stringify(bad)}\n`);
    return 1;
  }
  const { paths } = staged.length > 0 ? dropMergeIncomingPaths(repo, staged) : { paths: [] };
  if (paths.length > 0) process.stdout.write(`${paths.join("\n")}\n`);
  return 0;
}

if (require.main === module) {
  let code = 1;
  try {
    code = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${NAME}: ${(e && e.message) || e}\n`);
  }
  process.exit(code);
}

module.exports = { main };
