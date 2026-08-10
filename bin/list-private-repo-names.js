#!/usr/bin/env node
'use strict';
// Print the bare name of every private repo visible to the user, one per line.
// Producer for the PRIVATE_REPO_NAMES_CACHE consumed by bin/check-private-repo-name.js.
// Usage: node list-private-repo-names.js
// Exit: always 0. No output means "no private repos" or "could not determine" —
// deliberately indistinguishable, matching listPrivateRepoNames()'s own contract.

const path = require('path');

let listPrivateRepoNames;
try {
  ({ listPrivateRepoNames } = require(
    path.join(path.dirname(__dirname), 'hooks', 'lib', 'is-private-repo.js')
  ));
} catch (e) {
  process.exit(0); // fail-open: lister unavailable
}

Promise.resolve(listPrivateRepoNames())
  .then((privateNames) => {
    const bare = privateNames.map((name) => name.split('/').pop()).filter(Boolean);
    // Write before exit: process.exit() can truncate a pending async stdout
    // write when stdout is piped (the caller uses command substitution).
    if (bare.length > 0) process.stdout.write(bare.join('\n') + '\n');
  })
  .catch(() => process.exit(0)); // fail-open: unexpected rejection
