// Shared module: detect whether a git remote is in a pre-bootstrap state.
// A "pre-bootstrap" remote is a brand-new GitHub repository that has no default
// branch yet (HEAD on the remote does not resolve to refs/heads/<name>).
//
// Used by /commit-push and /worktree-end to route new-repo first-commit
// scenarios into a special autonomous bootstrap path (push branch:main and
// set default branch) instead of the normal PR flow.
//
// CommonJS module — match surrounding hooks/lib style.

'use strict';

const { spawnSync } = require('child_process');

// Regex tables exported for test introspection (_PATTERNS).
const _PATTERNS = {
  // Successful HEAD probe of a populated remote.
  symref: /^ref:\s+refs\/heads\/\S+\s+HEAD$/m,
  // stderr classifications when ls-remote fails.
  network: [
    /remote (repository|end) hung up/i,
    /fatal: unable to access/i,
    /Could not resolve host/i,
    /Connection (refused|timed out)/i,
  ],
  auth: [
    /Permission denied \(publickey\)/i,
    /fatal: Authentication failed/i,
    /could not read Username/i,
  ],
  notFound: [
    /Repository not found/i,
    /fatal: repository .* does not exist/i,
  ],
};

function matchesAny(text, patterns) {
  if (!text) return false;
  for (const p of patterns) {
    if (p.test(text)) return true;
  }
  return false;
}

// Probe the remote and classify its state.
// Returns: { preBootstrap: boolean, reason: string, classification: string }
//   classification values:
//     "ok"          — remote has a default branch
//     "empty-repo"  — remote responded but has no refs (pre-bootstrap)
//     "network"     — host/transport failure
//     "auth"        — credentials missing or rejected
//     "not-found"   — repo does not exist (or no read access)
//     "timeout"     — spawnSync killed by timeoutMs (SIGTERM)
//     "spawn-error" — could not spawn git at all
//     "unknown"     — non-zero exit not matching any known pattern
//   preBootstrap is only true for "empty-repo".
function isRemoteInPreBootstrap(repoRoot, opts) {
  const {
    remote = 'origin',
    timeoutMs = 5000,
    gitPath = 'git',
  } = opts || {};

  let result;
  try {
    result = spawnSync(
      gitPath,
      ['-C', repoRoot, 'ls-remote', '--symref', remote, 'HEAD'],
      {
        encoding: 'utf8',
        timeout: timeoutMs,
        env: {
          ...process.env,
          GIT_TERMINAL_PROMPT: '0',
          // /bin/true doesn't exist on Windows; 'echo' is a universal no-op credential helper.
          GIT_ASKPASS: process.platform === 'win32' ? 'echo' : '/bin/true',
        },
      }
    );
  } catch (e) {
    return {
      preBootstrap: false,
      reason: `spawnSync threw: ${e.message}`,
      classification: 'spawn-error',
    };
  }

  // On Windows, spawnSync does not throw when the binary is missing or the
  // timeout fires; it returns result.error. Classify these conditions before
  // touching result.status (which is null in these cases).
  if (result.error) {
    const code = result.error.code;
    if (code === 'ETIMEDOUT') {
      return {
        preBootstrap: false,
        reason: `ls-remote killed by timeout after ${timeoutMs}ms`,
        classification: 'timeout',
      };
    }
    if (code === 'ENOENT' || code === 'EACCES') {
      return {
        preBootstrap: false,
        reason: `git not found or not executable: ${result.error.message}`,
        classification: 'spawn-error',
      };
    }
    return {
      preBootstrap: false,
      reason: `spawnSync error: ${result.error.message}`,
      classification: 'spawn-error',
    };
  }

  if (result.status === 0) {
    const stdout = (result.stdout || '').trim();
    if (_PATTERNS.symref.test(result.stdout || '')) {
      return {
        preBootstrap: false,
        reason: 'remote HEAD resolves to a default branch',
        classification: 'ok',
      };
    }
    if (stdout === '') {
      return {
        preBootstrap: true,
        reason: 'remote ls-remote returned no refs (empty repository)',
        classification: 'empty-repo',
      };
    }
    // Exit 0 but no symref and not empty — treat as unknown.
    return {
      preBootstrap: false,
      reason: 'ls-remote succeeded but output did not match symref or empty patterns',
      classification: 'unknown',
    };
  }

  // status !== 0 (including null on signal).
  if (result.signal === 'SIGTERM') {
    return {
      preBootstrap: false,
      reason: `ls-remote killed by timeout after ${timeoutMs}ms`,
      classification: 'timeout',
    };
  }

  const stderr = result.stderr || '';
  if (matchesAny(stderr, _PATTERNS.network)) {
    return {
      preBootstrap: false,
      reason: 'network/transport failure contacting remote',
      classification: 'network',
    };
  }
  if (matchesAny(stderr, _PATTERNS.auth)) {
    return {
      preBootstrap: false,
      reason: 'authentication failed for remote',
      classification: 'auth',
    };
  }
  if (matchesAny(stderr, _PATTERNS.notFound)) {
    return {
      preBootstrap: false,
      reason: 'remote repository not found',
      classification: 'not-found',
    };
  }

  return {
    preBootstrap: false,
    reason: `ls-remote exited ${result.status} with unrecognised stderr`,
    classification: 'unknown',
  };
}

module.exports = { isRemoteInPreBootstrap, _PATTERNS };
