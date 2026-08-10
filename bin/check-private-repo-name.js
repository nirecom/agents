#!/usr/bin/env node
'use strict';
// Check a candidate string (e.g. a task-name slug destined for a public branch
// name) against the list of the user's private repo names, so a private repo's
// bare name cannot leak into a public branch name via a path that
// bin/scan-outbound.sh's static allowlist/blocklist scan never covers.
//
// Matching deliberately differs from the dynamic check in hooks/scan-outbound.js,
// because the input class differs. That hook scans free-form outbound content,
// where a private repo is usually written in full `owner/repo` form; this script
// scans a single path/branch component, which is validated elsewhere to contain
// no '/' at all. So the `owner/` prefix is stripped first and only the bare repo
// name is matched. The boundary class is [^a-zA-Z0-9] rather than [^\w/.-]:
// slugs are hyphen-joined, so '-' and '_' must count as boundaries or an
// embedded private name (e.g. 'secret-thing' inside '1910-secret-thing-fix')
// would never match. The match is case-insensitive because a repo name is not
// case-normalized while a derived task-name slug always is.
//
// Usage: node check-private-repo-name.js <candidate>
// Exit: 0 = clean or unable to determine (fail-open, matches
//       listPrivateRepoNames()'s own fail-open contract); 1 = a private repo
//       name was found in the candidate (fail-closed on a positive match).
// stderr on match: one fixed, non-identifying line. It names neither the
// matched private repo nor the candidate string — echoing either would leak
// the very name this gate exists to keep out of more-visible surfaces (CI
// logs, terminal transcripts, captured test output).
//
// Cache contract (avoids N redundant `gh repo list` round-trips per caller):
// when PRIVATE_REPO_NAMES_CACHE_SET=1, the name list is read from
// PRIVATE_REPO_NAMES_CACHE (newline-joined; empty string means "confirmed
// empty list") and neither gh nor hooks/lib/is-private-repo.js is touched.
// Producer: bin/list-private-repo-names.js.

const path = require('path');

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Returns the matched bare private repo name, or null when the candidate is
// clean. Cached names are already bare and live names are 'owner/repo', so
// split('/').pop() normalizes both without branching.
function findPrivateName(candidate, privateNames) {
  for (const name of privateNames) {
    const bare = name.split('/').pop();
    if (!bare) continue;
    const re = new RegExp('(^|[^a-zA-Z0-9])' + escapeRegex(bare) + '([^a-zA-Z0-9]|$)', 'i');
    if (re.test(candidate)) return bare;
  }
  return null;
}

// Always terminates: exit 1 on a positive match, exit 0 otherwise.
function finish(candidate, privateNames) {
  const matched = findPrivateName(candidate, privateNames);
  if (matched !== null) {
    // Fixed literal: never interpolate `matched` or `candidate` — see the
    // "stderr on match" note at the top of this file.
    process.stderr.write('private repository name detected in candidate; rejecting\n');
    process.exit(1);
  }
  process.exit(0);
}

const candidate = process.argv[2];
if (!candidate) {
  // Nothing to check — fail-open, same as an empty listPrivateRepoNames().
  process.exit(0);
}

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
  // Cannot load the checker — fail-open (informational only, not a hard gate).
  process.exit(0);
}

Promise.resolve(listPrivateRepoNames())
  .then((privateNames) => finish(candidate, privateNames))
  .catch(() => {
    // listPrivateRepoNames() already fails open internally; this catch is a
    // last-resort guard against an unexpected rejection.
    process.exit(0);
  });
