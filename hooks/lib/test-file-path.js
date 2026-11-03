"use strict";
// isTestFilePath(rel) — the write_tests evidence predicate (#2472), shared by every caller:
// a path under tests/ or test/ whose basename some test-language registry entry matches,
// whatever the entry's status (helpers such as _lib.sh count; fixtures and docs do not).
// An unreadable registry answers false (fail-closed) and says so on stderr.

const TLR = require("./test-language-registry");

function isTestFilePath(rel) {
  if (typeof rel !== "string" || rel === "") return false;
  const p = rel.replace(/\\/g, "/").replace(/^\.\//, "");
  if (!p.startsWith("tests/") && !p.startsWith("test/")) return false;
  const reg = TLR.tryLoadRegistry();
  if (!reg) {
    process.stderr.write(`test-file-path: test-language registry unreadable — ${p} not counted as a test file\n`);
    return false;
  }
  return TLR.matchBasename(p.slice(p.lastIndexOf("/") + 1), reg) !== null;
}

module.exports = { isTestFilePath };
