#!/usr/bin/env node
'use strict';
// Check a candidate path/branch component against private repo bare names.
// Usage: node check-private-repo-name.js <candidate>
// Exit: 0 = clean/undetermined (fail-open); 1 = private name found (fail-closed).
// Matching logic (findPrivateName/escapeRegex) is SSOT'd in
// hooks/lib/is-private-repo.js — shared with hooks/scan-outbound.js so the two
// gates can never diverge on what counts as a boundary.
// Cache: PRIVATE_REPO_NAMES_CACHE_SET=1 reads PRIVATE_REPO_NAMES_CACHE instead
// of calling gh (producer: bin/list-private-repo-names.js).
// Stdin: PRIVATE_REPO_NAMES_STDIN=1 reads the newline-separated list from stdin
// instead, so the full list never has to sit in the environment of the caller
// and every process it spawns. Highest precedence of the three sources. Same
// authoritative-empty semantics as the env cache above: STDIN=1 declares "this
// list is authoritative", so empty stdin means "confirmed no private repos",
// not "unknown".

const path = require('path');

// Partial disclosure via truncation is not a gap here: derive-worktree-name.sh
// slugify() keeps only the first 5 tokens / 40 chars, so a truncated private
// name could evade findPrivateName()'s whole-name match — but the raw
// pre-slugify TITLE is always passed through scan_clean() first, and
// slugify()'s output is always a token-prefix of a string that already passed
// that scan.

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

// Placed above the env-cache block so the source precedence (stdin > env cache >
// live lookup) is structural rather than incidental.
if (process.env.PRIVATE_REPO_NAMES_STDIN === '1') {
  // readStdin() is called inside the chain (not as an eager argument to
  // Promise.resolve()) for the same reason the live-lookup chain at the bottom
  // of this file is: a synchronous throw from it is then caught by .catch()
  // too, honoring the fail-open contract instead of crashing the process.
  // The bare `return` is what makes this branch terminal — resolving stdin is
  // asynchronous, so without it the synchronous blocks below would run first
  // and defeat the precedence this placement establishes.
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

// listPrivateRepoNames() is called inside the chain (not as an eager argument
// to Promise.resolve()) so a synchronous throw from it is caught by .catch()
// too, honoring this file's fail-open contract instead of crashing the process.
Promise.resolve()
  .then(() => listPrivateRepoNames())
  .then((privateNames) => finish(candidate, privateNames))
  .catch(() => process.exit(0)); // fail-open: unexpected rejection
