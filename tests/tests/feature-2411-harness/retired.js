"use strict";
// Retired relay names for tests/tests/feature-2411-harness.js (#2673). They are read from the
// tombstone checker, because test text may not name them; a name added there later fails the
// harness cases until every harness clears it as well.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

function retiredNames(root) {
  const text = fs.readFileSync(path.join(root, "bin", "check-session-id-ssot.sh"), "utf8");
  const found = /^TOMBSTONE_NAMES='([^']+)'\r?$/m.exec(text);
  assert.ok(found, "bin/check-session-id-ssot.sh has a TOMBSTONE_NAMES line");
  const names = found[1].split("|");
  assert.ok(names.length >= 2 && names.every((n) => n !== ""), `two or more non-empty names in ${found[1]}`);
  return names;
}

// The names of the list that are set in this process.
const leftSet = (names) => names.filter((n) => process.env[n] !== undefined);

module.exports = { retiredNames, leftSet };
