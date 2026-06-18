#!/usr/bin/env node
"use strict";

// Compute the staged-tests evidence token for /review-tests Step 4a.
// Resolves the correct linked worktree (the one with staged test files),
// then delegates to computeStagedTestsToken() from review-tests-evidence.js.
//
// Fail-open strategy:
//   - No linked worktree has staged tests → falls back to process.cwd() (may
//     return a token or empty string depending on the main worktree's index).
//   - Any unhandled exception → writes empty string and exits 0.
// Always exits 0.

const { execFileSync } = require('child_process');
const path = require('path');

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
    const wt = paths[i];
    let buf;
    try {
      buf = execFileSync('git', ['-C', wt, 'diff', '--cached', '--name-only', '-z'], {
        timeout: 5000,
        encoding: 'buffer',
      });
    } catch (_e) {
      continue;
    }
    const text = buf.toString('utf8');
    const files = text.split('\0').filter(Boolean);
    for (const f of files) {
      if (f.startsWith('tests/') || f.startsWith('test/')) {
        return wt;
      }
    }
  }

  return null;
}

try {
  const repoDir = findRepoDirWithStagedTests() || process.cwd();
  const { computeStagedTestsToken } = require(
    path.join(process.env.AGENTS_CONFIG_DIR, 'hooks/workflow-gate/review-tests-evidence')
  );
  const token = computeStagedTestsToken(repoDir);
  process.stdout.write(token || '');
} catch (_e) {
  process.stdout.write('');
}

process.exit(0);
