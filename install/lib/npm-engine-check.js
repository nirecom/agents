// npm-engine-check.js <range> - does the running Node satisfy an engines.node range?
// Exit 0 = satisfied (empty range = no constraint), 1 = not satisfied, 2 = cannot tell.
// Uses the semver bundled with npm so no extra dependency is needed.
'use strict';

const path = require('path');

const range = (process.argv[2] || '').trim();
if (range === '') process.exit(0);

const nodeDir = path.dirname(process.execPath);
const candidates = [
  path.join(nodeDir, 'node_modules', 'npm', 'node_modules', 'semver'),
  path.join(nodeDir, '..', 'lib', 'node_modules', 'npm', 'node_modules', 'semver'),
];

let semver = null;
for (const candidate of candidates) {
  try {
    semver = require(candidate);
    break;
  } catch {
    // try the next layout
  }
}
if (semver === null) process.exit(2);

try {
  process.exit(semver.satisfies(process.version, range, { includePrerelease: true }) ? 0 : 1);
} catch {
  process.exit(2);
}
