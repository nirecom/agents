#!/usr/bin/env node
'use strict';
// Check a candidate path/branch component against private repo bare names.
// Usage: node check-private-repo-name.js <candidate>
// Exit: 0 = clean/undetermined (fail-open); 1 = private name found (fail-closed).
// Boundary class is [^a-zA-Z0-9], not [^\w/.-] like hooks/scan-outbound.js —
// slugs are hyphen/underscore-joined, so those must count as boundaries too.
// Cache: PRIVATE_REPO_NAMES_CACHE_SET=1 reads PRIVATE_REPO_NAMES_CACHE instead
// of calling gh (producer: bin/list-private-repo-names.js).

const path = require('path');

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// split('/').pop() normalizes both cached (bare) and live ('owner/repo') names.
function findPrivateName(candidate, privateNames) {
  for (const name of privateNames) {
    const bare = name.split('/').pop();
    if (!bare) continue;
    const re = new RegExp('(^|[^a-zA-Z0-9])' + escapeRegex(bare) + '([^a-zA-Z0-9]|$)', 'i');
    if (re.test(candidate)) return bare;
  }
  return null;
}

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

if (process.env.PRIVATE_REPO_NAMES_CACHE_SET === '1') {
  finish(
    candidate,
    (process.env.PRIVATE_REPO_NAMES_CACHE || '').split('\n').filter(Boolean)
  );
}

let listPrivateRepoNames;
try {
  ({ listPrivateRepoNames } = require(
    path.join(path.dirname(__dirname), 'hooks', 'lib', 'is-private-repo.js')
  ));
} catch (e) {
  process.exit(0); // fail-open: checker unavailable
}

Promise.resolve(listPrivateRepoNames())
  .then((privateNames) => finish(candidate, privateNames))
  .catch(() => process.exit(0)); // fail-open: unexpected rejection
