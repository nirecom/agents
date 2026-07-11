#!/usr/bin/env node
"use strict";

// Compute the staged-tests evidence token for /review-tests Step 4a.
// Resolves the worktree whose staged tests the workflow-gate will verify at
// commit time (the commit target), then delegates to computeStagedTestsToken()
// from review-tests-evidence.js.
//
// Worktree selection (session-bound, issue #1316):
//   The pre-commit gate always fingerprints the worktree where `git commit`
//   runs (the session's linked worktree). The emitted token MUST match that
//   same worktree, or the gate blocks forever on stale-token. CWD-based
//   resolution is unreliable (subagents, background runs) and the main
//   worktree must never be selected. Selection order, most authoritative first:
//     1. Explicit worktree path in argv[2] — caller states the commit target.
//     2. Session state cwd (SESSION_ID / CLAUDE_SESSION_ID → readState().cwd),
//        rejected when it resolves to the main worktree.
//
// Fail-safe strategy:
//   - Nothing resolves → returns null; main() writes empty string and exits 0.
//   - NEVER falls back to process.cwd().
//   - Any unhandled exception → writes empty string and exits 0.
// Always exits 0.

const fs = require('fs');
const path = require('path');
const { execSync, execFileSync } = require('child_process');

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

// True when `dir` is the main worktree (git-dir === git-common-dir).
// Fail-safe: any error is treated as "is main worktree" (reject).
function isMainWorktree(dir) {
  try {
    const gitDir = execSync(`git -C "${dir}" rev-parse --git-dir`, {
      timeout: 5000,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    const gitCommonDir = execSync(`git -C "${dir}" rev-parse --git-common-dir`, {
      timeout: 5000,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    return path.resolve(gitDir) === path.resolve(gitCommonDir);
  } catch (_e) {
    return true;
  }
}

// Resolve the commit-target worktree per the selection order documented above.
// Returns null when nothing resolves (NEVER process.cwd()).
function resolveRepoDir() {
  const explicit = process.argv[2];
  if (explicit) {
    return explicit;
  }
  const sessionId = process.env.SESSION_ID || process.env.CLAUDE_SESSION_ID;
  if (sessionId) {
    try {
      const { readState } = require('../hooks/lib/workflow-state/state-io.js');
      const state = readState(sessionId);
      if (state && typeof state.cwd === 'string' && fs.existsSync(state.cwd)) {
        if (!isMainWorktree(state.cwd)) {
          return state.cwd;
        }
      }
    } catch (_e) {
      return null;
    }
  }
  return null;
}

try {
  const repoDir = resolveRepoDir();
  if (!repoDir) {
    process.stdout.write('');
    process.exit(0);
  }
  const { computeStagedTestsToken } = require(
    path.join(process.env.AGENTS_CONFIG_DIR, 'hooks/workflow-gate/review-tests-evidence')
  );
  const token = computeStagedTestsToken(repoDir);
  process.stdout.write(token || '');
} catch (_e) {
  process.stdout.write('');
}

process.exit(0);
