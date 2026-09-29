#!/usr/bin/env node
"use strict";

// bin/compute-review-scope-fingerprint.js — the review-scope fingerprint for /review-tests
// RT-5a, computed on the commit-target worktree (#1316): argv[2] when given, else
// resolveSessionWorktreePath() (never the main worktree, NEVER process.cwd()).
// Fail-closed (#2327): 16-hex + exit 0; empty + exit 0 for a 0-file scope;
// exit 1 + stderr on any resolution or git error.

const { execFileSync } = require('child_process');
const { resolveSessionWorktreePath } = require('../hooks/workflow-state/resolve-worktree-path');
const { computeReviewScopeFingerprint } = require('../hooks/workflow-gate/review-tests-evidence');
const { toWindowsPath } = require('../hooks/lib/branch-diff');

// True when `dir` has at least one staged tests/** (or test/**) path.
// Retained for test use.
function dirHasStagedTests(dir) {
  let buf;
  try {
    buf = execFileSync('git', ['-C', dir, 'diff', '--cached', '--name-only', '-z'], {
      timeout: 5000,
      encoding: 'buffer',
    });
  } catch (_e) {
    return false;
  }
  const files = buf.toString('utf8').split('\0').filter(Boolean);
  return files.some((f) => f.startsWith('tests/') || f.startsWith('test/'));
}

function resolveRepoDir() {
  const explicit = process.argv[2];
  if (explicit) return toWindowsPath(explicit);
  return resolveSessionWorktreePath();
}

function main() {
  const repoDir = resolveRepoDir();
  if (!repoDir) {
    process.stderr.write('compute-review-scope-fingerprint: no worktree resolved (pass it as argv[2])\n');
    return 1;
  }
  const res = computeReviewScopeFingerprint(repoDir);
  if (!res.ok) {
    process.stderr.write(`compute-review-scope-fingerprint: ${res.error || 'calculation failed'}\n`);
    return 1;
  }
  process.stdout.write(res.fingerprint || '');
  return 0;
}

if (require.main === module) {
  let code = 1;
  try {
    code = main();
  } catch (e) {
    process.stderr.write(`compute-review-scope-fingerprint: ${(e && e.message) || e}\n`);
  }
  process.exit(code);
}

module.exports = { dirHasStagedTests };
