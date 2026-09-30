#!/usr/bin/env node
"use strict";

// bin/select-review-scope.js — /review-tests RT-2 scope selection (#2327).
// Usage: select-review-scope.js --session <sid> --worktree <path-or-empty>
// Stdout, one item per line: SCOPE=<full|delta>, REASON=<...>, REVIEW\t<abs>,
// DELETED\t<rel>, INVENTORY\t<rel>, SOURCE\t<abs>.
// Exit: 0 ok; 2 usage / malformed session id; 4 input error (manifest failure, or a
// REVIEW/SOURCE path missing from the worktree — the #1455 deterministic pre-check).

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { SESSION_ID_VALID_RE } = require("../hooks/workflow-state/state-io/core");
const { readState } = require("../hooks/workflow-state/state-io");
const { resolveSessionWorktreePath } = require("../hooks/workflow-state/resolve-worktree-path");
const { computeReviewScopeManifest } = require("../hooks/workflow-gate/review-tests-evidence");
const { latestRecordedManifest, decideReviewScope } = require("../hooks/workflow-gate/review-scope-delta");
const { toWindowsPath } = require("../hooks/lib/branch-diff");

const NAME = "select-review-scope";

function parseArgs(argv) {
  const out = { session: null, worktree: "" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if ((a === "--session" || a === "--worktree") && i + 1 < argv.length) {
      out[a.slice(2)] = argv[++i];
    } else {
      return { error: `unknown or incomplete argument: ${a}` };
    }
  }
  if (!out.session) return { error: "--session <sid> is required" };
  if (!SESSION_ID_VALID_RE.test(out.session)) return { error: "--session value malformed" };
  return out;
}

function slash(p) {
  return String(p).replace(/\\/g, "/").replace(/\/+$/, "");
}

function resolveWorktree(sid, explicit) {
  if (explicit) return toWindowsPath(explicit);
  const fromState = resolveSessionWorktreePath(sid);
  if (fromState) return toWindowsPath(fromState);
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (_) {
    return null;
  }
}

function main(argv) {
  const args = parseArgs(argv);
  if (args.error) {
    process.stderr.write(`${NAME}: ${args.error}\n`);
    return 2;
  }
  const worktree = resolveWorktree(args.session, args.worktree);
  if (!worktree) {
    process.stderr.write(`${NAME}: no worktree resolved (pass --worktree)\n`);
    return 4;
  }
  const current = computeReviewScopeManifest(worktree);
  if (!current.ok) {
    process.stderr.write(`${NAME}: review-scope manifest failed: ${current.error}\n`);
    return 4;
  }
  const state = readState(args.session);
  const decision = state
    ? decideReviewScope(latestRecordedManifest(state.events), current)
    : { ...decideReviewScope(null, current), reason: "no-state" };

  const root = slash(worktree);
  const abs = (rel) => `${root}/${rel}`;
  const missing = [...decision.review, ...decision.sources].filter((rel) => !fs.existsSync(path.join(worktree, rel)));
  if (missing.length > 0) {
    for (const rel of missing) process.stderr.write(`${NAME}: review input missing from worktree: ${abs(rel)}\n`);
    return 4;
  }

  const lines = [`SCOPE=${decision.scope}`, `REASON=${decision.reason}`];
  for (const rel of decision.review) lines.push(`REVIEW\t${abs(rel)}`);
  for (const rel of decision.deleted) lines.push(`DELETED\t${rel}`);
  for (const rel of decision.inventory) lines.push(`INVENTORY\t${rel}`);
  for (const rel of decision.sources) lines.push(`SOURCE\t${abs(rel)}`);
  process.stdout.write(lines.join("\n") + "\n");
  return 0;
}

if (require.main === module) {
  let code = 4;
  try {
    code = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`${NAME}: ${(e && e.message) || e}\n`);
  }
  process.exit(code);
}

module.exports = { main };
