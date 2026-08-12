#!/usr/bin/env node
'use strict';
// Check a candidate path/branch component against private repo bare names.
// Usage: node check-private-repo-name.js <candidate>
// Exit: 0 = clean/undetermined (fail-open); 1 = private name found (fail-closed).
// Matching logic is SSOT'd in hooks/lib/is-private-repo.js (shared with
// hooks/scan-outbound.js, so the two gates never diverge on what counts as
// a boundary).
// Name-list source precedence: stdin (PRIVATE_REPO_NAMES_STDIN=1, keeps the
// full list out of every process's environment) > env cache
// (PRIVATE_REPO_NAMES_CACHE_SET=1 + PRIVATE_REPO_NAMES_CACHE, producer:
// bin/list-private-repo-names.js) > live gh lookup. Both STDIN=1 and
// CACHE_SET=1 are authoritative — an empty list means "confirmed no
// private repos", not "unknown".

const path = require('path');

// Not a truncation gap: derive-worktree-name.sh slugify() output is always
// a token-prefix of a TITLE that already passed scan_clean() pre-slugify.

function finish(candidate, privateNames) {
  const matched = findPrivateName(candidate, privateNames);
  if (matched !== null) {
    // Fixed literal — never interpolate `matched`/`candidate` (would leak the name).
    process.stderr.write('private repository name detected in candidate; rejecting\n');
    process.exit(1);
  }
  process.exit(0);
}

const candidate = process.argv[2];
if (!candidate) process.exit(0);

let listPrivateRepoNames, findPrivateName;
try {
  ({ listPrivateRepoNames, findPrivateName } = require(
    path.join(path.dirname(__dirname), 'hooks', 'lib', 'is-private-repo.js')
  ));
} catch (e) {
  process.exit(0); // fail-open: checker unavailable
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

// Placed above the env-cache block so precedence (stdin > env cache > live
// lookup) is structural. `return` is required: resolving stdin is async, so
// without it the synchronous blocks below would run first regardless.
if (process.env.PRIVATE_REPO_NAMES_STDIN === '1') {
  // readStdin() called inside the chain (not eagerly) so a synchronous
  // throw is also caught by .catch() — fail-open, never crash.
  Promise.resolve()
    .then(() => readStdin())
    .then((raw) => finish(candidate, raw.split('\n').filter(Boolean)))
    .catch(() => process.exit(0)); // fail-open: stdin unreadable
  return;
}

if (process.env.PRIVATE_REPO_NAMES_CACHE_SET === '1') {
  finish(
    candidate,
    (process.env.PRIVATE_REPO_NAMES_CACHE || '').split('\n').filter(Boolean)
  );
}

// Called inside the chain (not eagerly) so a synchronous throw is also
// caught by .catch() — fail-open, never crash.
Promise.resolve()
  .then(() => listPrivateRepoNames())
  .then((privateNames) => finish(candidate, privateNames))
  .catch(() => process.exit(0)); // fail-open: unexpected rejection
