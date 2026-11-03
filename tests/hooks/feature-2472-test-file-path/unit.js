"use strict";
// Tests: hooks/lib/test-file-path.js
// Tags: TL2, hooks, write-tests, completion-evidence, test-language-registry, scope:issue-specific
// #2472 T5: isTestFilePath(rel) — under tests/ or test/ AND a basename some test-language
// registry entry matches. Fixtures and docs under tests/ are not test files; helpers are.
// A registry that cannot be read answers false (fail-closed).

const path = require("path");
const { spawnSync } = require("child_process");
const F = require("../../lib/run-tests-outcome-fixture");
const { check, eq, show, errText, mod } = F;

const TABLE = [
  ["tests/hooks/x.sh", true],
  ["tests/hooks/foo/_lib.sh", true],
  ["test/x.sh", true],
  ["tests/hooks/x.js", true],
  ["tests/x.md", false],
  ["tests/fixtures/a.json", false],
  ["tests/notes.txt", false],
  ["docs/x.sh", false],
  ["hooks/x.js", false],
];

function predicateTable() {
  let isTestFilePath = null;
  let error = null;
  try {
    ({ isTestFilePath } = mod("hooks/lib/test-file-path.js"));
    if (typeof isTestFilePath !== "function") error = `isTestFilePath is ${typeof isTestFilePath}`;
  } catch (e) {
    error = `test-file-path.js not loadable: ${errText(e).split("\n")[0]}`;
  }
  for (const [rel, want] of TABLE) {
    check(`T5: isTestFilePath(${rel}) is ${want}`, () => {
      if (error) return error;
      eq(isTestFilePath(rel), want, rel);
      return undefined;
    });
  }
}

function registryUnreadableFailsClosed() {
  const child = path.join(__dirname, "registry-unreadable-child.js");
  const ask = (rel) => {
    const r = spawnSync(process.execPath, [child, F.ROOT, rel], { encoding: "utf8", timeout: 30000, cwd: F.tmp(), env: process.env });
    try { return Object.assign(JSON.parse((r.stdout || "").trim()), { stderr: r.stderr || "" }); } catch (_) { return { error: `child output ${show(r.stdout)} ${r.stderr}` }; }
  };
  const got = ask("tests/hooks/x.sh");
  check("T5: registry unreadable — isTestFilePath(tests/hooks/x.sh) answers false and says why on stderr", () => {
    if (got.error) return got.error;
    eq(got.result, false, "result");
    if (got.stderr.trim() === "") return "nothing on stderr";
    return undefined;
  });
}

module.exports = { predicateTable, registryUnreadableFailsClosed };
