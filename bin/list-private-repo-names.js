#!/usr/bin/env node
'use strict';
// Print the bare name of every private repo visible to the user, one per line.
//
// Producer for the one-shot cache consumed by bin/check-private-repo-name.js:
// a caller that checks several candidates in one run (e.g.
// skills/worktree-start/scripts/derive-worktree-name.sh) runs this once and
// exports the result as PRIVATE_REPO_NAMES_CACHE / PRIVATE_REPO_NAMES_CACHE_SET,
// replacing N identical `gh repo list` round-trips with exactly one.
//
// listPrivateRepoNames() returns 'owner/repo' strings; only the bare repo name
// is emitted, matching what check-private-repo-name.js matches on.
//
// Usage: node list-private-repo-names.js
// Exit: always 0 (fail-open, matching listPrivateRepoNames()'s own contract).
//       No output means "no private repos" OR "could not determine" — the two
//       are deliberately indistinguishable, as they are for the live path.

const path = require('path');

let listPrivateRepoNames;
try {
  ({ listPrivateRepoNames } = require(
    path.join(path.dirname(__dirname), 'hooks', 'lib', 'is-private-repo.js')
  ));
} catch (e) {
  // Cannot load the lister — fail-open with no output.
  process.exit(0);
}

Promise.resolve(listPrivateRepoNames())
  .then((privateNames) => {
    const bare = privateNames.map((name) => name.split('/').pop()).filter(Boolean);
    // One write, then a natural exit: process.exit() can truncate a pending
    // async stdout write when stdout is a pipe, which is exactly how the
    // caller captures this (command substitution).
    if (bare.length > 0) process.stdout.write(bare.join('\n') + '\n');
  })
  .catch(() => {
    // listPrivateRepoNames() already fails open internally; last-resort guard.
    process.exit(0);
  });
