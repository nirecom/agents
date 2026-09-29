#!/usr/bin/env node
"use strict";

// bin/stage-review-scope-files.js — /write-code WCD-7 (#2327): stage the implementation
// files write-code edited so the write_code completion snapshot sees them.
// Usage: stage-review-scope-files.js --worktree <path> [--] <path>...
// Stdout: STAGED\t<rel> | SKIPPED\t<p>\t<test|excluded|outside-worktree|missing>.
// Exit: 0 ok; 2 usage; 3 git or internal error (same meaning as check-unstaged-tracked.sh).
// Routing is owned by review-tests-evidence.js — never restated here.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { isReviewScopeExcludedPath, isReviewScopeTestPath } = require("../hooks/workflow-gate/review-tests-evidence");
const { hasUnstagedTrackedChanges } = require("../hooks/workflow-gate/staged-evidence");
const { toWindowsPath } = require("../hooks/lib/branch-diff");

const NAME = "stage-review-scope-files";

function parseArgs(argv) {
  const out = { worktree: null, paths: [] };
  let rest = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (rest) out.paths.push(a);
    else if (a === "--") rest = true;
    else if (a === "--worktree" && i + 1 < argv.length) out.worktree = argv[++i];
    else if (a.startsWith("--")) return { error: `unknown argument: ${a}` };
    else out.paths.push(a);
  }
  if (!out.worktree) return { error: "--worktree <path> is required" };
  return out;
}

function git(cwd, args) {
  return execFileSync("git", args, { cwd, encoding: "utf8", timeout: 10000, stdio: ["pipe", "pipe", "pipe"] });
}

// Worktree-relative slash path, or null when the path lies outside the worktree.
function toRelative(root, worktree, p) {
  const native = toWindowsPath(p);
  const abs = path.isAbsolute(native) ? native : path.resolve(worktree, native);
  const rel = path.relative(root, abs);
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return rel.replace(/\\/g, "/");
}

function main(argv) {
  const args = parseArgs(argv);
  if (args.error) {
    process.stderr.write(`${NAME}: ${args.error}\n`);
    return 2;
  }
  const worktree = toWindowsPath(args.worktree);
  let root;
  try {
    root = toWindowsPath(git(worktree, ["rev-parse", "--show-toplevel"]).trim());
  } catch (e) {
    process.stderr.write(`${NAME}: not a git worktree: ${args.worktree}\n`);
    return 3;
  }
  const unstaged = hasUnstagedTrackedChanges(root);
  if (unstaged.error) return 3;

  const lines = [];
  const candidates = new Set(unstaged.files);
  for (const p of args.paths) {
    const rel = toRelative(root, worktree, p);
    if (rel === null) lines.push(`SKIPPED\t${p}\toutside-worktree`);
    else candidates.add(rel);
  }
  const tracked = new Set(git(root, ["ls-files", "-z"]).split("\0").filter(Boolean));
  const toStage = [];
  for (const rel of [...candidates].sort()) {
    if (isReviewScopeTestPath(rel)) lines.push(`SKIPPED\t${rel}\ttest`);
    else if (isReviewScopeExcludedPath(rel)) lines.push(`SKIPPED\t${rel}\texcluded`);
    else if (!tracked.has(rel) && !fs.existsSync(path.join(root, rel))) lines.push(`SKIPPED\t${rel}\tmissing`);
    else toStage.push(rel);
  }
  if (toStage.length > 0) {
    try {
      // Literal: a path holding glob or `:(magic)` characters must stage only itself.
      git(root, ["--literal-pathspecs", "add", "-A", "--", ...toStage]);
    } catch (e) {
      process.stderr.write(`${NAME}: git add failed: ${String(e.stderr || e.message).trim()}\n`);
      return 3;
    }
    for (const rel of toStage) lines.push(`STAGED\t${rel}`);
  }
  if (lines.length > 0) process.stdout.write(lines.join("\n") + "\n");
  return 0;
}

if (require.main === module) {
  let code = 3;
  try {
    code = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${NAME}: ${(e && e.message) || e}\n`);
  }
  process.exit(code);
}

module.exports = { main };
