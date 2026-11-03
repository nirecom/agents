"use strict";
// Tests: hooks/lib/test-file-path.js
// Tags: TL2, hooks, write-tests, test-language-registry, fail-closed, scope:issue-specific
// Child driver: argv <agents-root> <rel>. Replaces the test-language registry module with one
// whose registry cannot be read (loadRegistry throws, tryLoadRegistry answers null), then asks
// isTestFilePath about <rel>. Prints one JSON line { result } or { error }.

const path = require("path");

const [root, rel] = process.argv.slice(2);
try {
  const regPath = require.resolve(path.join(root, "hooks", "lib", "test-language-registry.js"));
  const real = require(regPath);
  const unreadable = () => { throw new Error("fixture: registry unreadable"); };
  require.cache[regPath].exports = Object.assign({}, real, {
    loadRegistry: unreadable,
    tryLoadRegistry: () => null,
    matchBasename: (name, reg) => (reg ? real.matchBasename(name, reg) : unreadable()),
  });
  const { isTestFilePath } = require(path.join(root, "hooks", "lib", "test-file-path.js"));
  process.stdout.write(`${JSON.stringify({ result: isTestFilePath(rel) })}\n`);
} catch (e) {
  process.stdout.write(`${JSON.stringify({ error: String((e && e.message) || e).split("\n")[0] })}\n`);
}
