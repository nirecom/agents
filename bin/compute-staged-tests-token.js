#!/usr/bin/env node
"use strict";

// Compute the staged-tests evidence token for /review-tests Step 4a.
// Resolves the worktree whose staged tests the workflow-gate will verify at
// commit time (the commit target), then delegates to computeStagedTestsToken()
// from review-tests-evidence.js.
//
// Worktree selection (issue: parallel-worktree fingerprint mismatch):
//   The pre-commit gate always fingerprints the worktree where `git commit`
//   runs (the session's linked worktree). The emitted token MUST match that
//   same worktree, or the gate blocks forever on stale-token. When multiple
//   linked worktrees have staged tests concurrently (parallel sessions), the
//   naive "first linked worktree with staged tests" scan picks the wrong one.
//   Selection order, most authoritative first:
//     1. Explicit worktree path in argv[2] — caller states the commit target.
//     2. process.cwd()'s worktree, when it has staged tests — same worktree the
//        gate uses when the caller runs from the linked worktree.
//     3. Fallback scan: first linked worktree with staged tests (legacy).
//
// Fail-open strategy:
//   - No worktree has staged tests → falls back to process.cwd() (may return a
//     token or empty string depending on that worktree's index).
//   - Any unhandled exception → writes empty string and exits 0.
// Always exits 0.

const { execFileSync } = require('child_process');
const path = require('path');

// True when `dir` has at least one staged tests/** (or test/**) path.
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

// Legacy fallback: first linked worktree (skipping main) with staged tests.
function findRepoDirWithStagedTests() {
  let output;
  try {
    output = execFileSync('git', ['worktree', 'list', '--porcelain'], {
      cwd: process.cwd(),
      timeout: 5000,
      encoding: 'utf8',
    });
  } catch (_e) {
    return null;
  }

  const paths = [];
  for (const line of output.split(/\r?\n/)) {
    if (line.startsWith('worktree ')) {
      paths.push(line.slice('worktree '.length));
    }
  }

  // First path is main; skip it and only inspect linked worktrees.
  for (let i = 1; i < paths.length; i++) {
    if (dirHasStagedTests(paths[i])) {
      return paths[i];
    }
  }

  return null;
}

// Resolve the commit-target worktree per the selection order documented above.
function resolveRepoDir() {
  const explicit = process.argv[2];
  if (explicit) {
    return explicit;
  }
  if (dirHasStagedTests(process.cwd())) {
    return process.cwd();
  }
  return findRepoDirWithStagedTests() || process.cwd();
}

try {
  const repoDir = resolveRepoDir();
  const { computeStagedTestsToken } = require(
    path.join(process.env.AGENTS_CONFIG_DIR, 'hooks/workflow-gate/review-tests-evidence')
  );
  const token = computeStagedTestsToken(repoDir);
  process.stdout.write(token || '');
} catch (_e) {
  process.stdout.write('');
}

process.exit(0);
