// npm-engine-check.js <range> - does the running Node satisfy an engines.node range?
// Exit 0 = satisfied (empty range = no constraint), 1 = not satisfied, 2 = cannot tell.
// npm-engine-check.js --pick <range> <major> - read Node versions from stdin (one per line),
// print the highest <major>.x.y satisfying <range>. Exit 0 = printed, 1 = none, 2 = cannot tell.
// Uses the semver bundled with npm so no extra dependency is needed.
'use strict';

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const pick = args[0] === '--pick';
const range = ((pick ? args[1] : args[0]) || '').trim();
if (!pick && range === '') process.exit(0);

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
  if (range !== '' && semver.validRange(range) === null) process.exit(2);
  if (!pick) {
    process.exit(semver.satisfies(process.version, range, { includePrerelease: true }) ? 0 : 1);
  }
  const major = String(args[2] || '').trim();
  const versions = fs.readFileSync(0, 'utf8').split(/\r?\n/)
    .map((line) => (line.match(/v?(\d+\.\d+\.\d+)(?![\d.-])/) || [])[1])
    .filter((v) => v && v.split('.')[0] === major && (range === '' || semver.satisfies(v, range)))
    .sort(semver.compare);
  if (versions.length === 0) process.exit(1);
  process.stdout.write(`${versions[versions.length - 1]}\n`);
  process.exit(0);
} catch {
  process.exit(2);
}
