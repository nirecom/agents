#!/usr/bin/env node
// Print the issue numbers an aborted session claimed, one per line: the state's closes_issues
// plus the intent's `## Issues` (deduped). argv[2] = session id. Exit 0 always; a source that
// cannot be read contributes nothing and is reported on stderr.

'use strict';

const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const sid = process.argv[2] || '';
const out = new Set();
// An entry is a bare number (state closes_issues) or {number, repo?} (intent `## Issues`);
// an entry naming another repo is not this repository's WIP, so it contributes nothing.
const add = (list) => {
  for (const e of Array.isArray(list) ? list : []) {
    if (e && typeof e === 'object' && e.repo) {
      process.stderr.write(`warn: ${e.repo}#${e.number} belongs to another repository — its WIP mark is not released here\n`);
      continue;
    }
    const n = Number(e && typeof e === 'object' ? e.number : e);
    if (Number.isInteger(n) && n > 0) out.add(n);
  }
};

try {
  const { readState } = require(path.join(ROOT, 'hooks', 'workflow-state', 'state-io'));
  add((readState(sid) || {}).closes_issues);
} catch (e) {
  process.stderr.write(`warn: state closes_issues unreadable for ${sid}: ${e.message}\n`);
}
try {
  const { getClosesIssues } = require(path.join(ROOT, 'hooks', 'workflow-state', 'session-facts.js'));
  add(getClosesIssues(sid));
} catch (e) {
  process.stderr.write(`warn: intent issues unreadable for ${sid}: ${e.message}\n`);
}
process.stdout.write([...out].map((n) => `${n}\n`).join(''));
