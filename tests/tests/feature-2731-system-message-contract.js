"use strict";
// Tests: tests/lib/system-message-contract.js
// Tags: TL1, test-infra, node-test, system-message-contract, conv-lang, scope:issue-specific
// The shared systemMessage contract helper (#2731 S3) must reject short English prose after the tag
// ("[x] Retry now", "[x] Retry") while accepting language-neutral fact lines, through both the JS
// API and the `check` CLI that the bash consumers call.
// TL3 gap: none — the helper is pure string logic with no host dependency.
const { isolate } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const { after, describe, test } = require("node:test");

const restore = isolate();
after(() => restore());

const HELPER = path.resolve(__dirname, "..", "lib", "system-message-contract.js");
const C = require(HELPER);

function cli(msg) {
  const r = spawnSync(process.execPath, [HELPER, "check", msg], { encoding: "utf8", timeout: 30000 });
  assert.strictEqual(r.status, 0, `cli exit=${r.status} stderr=${r.stderr}`);
  return r.stdout;
}

const REJECTED = [
  ["two-word imperative", "[x] Retry now"],
  ["one-word capitalized imperative", "[x] Retry"],
  ["one-word imperative with punctuation", "[x] Run."],
  ["two lowercase words", "[bash-guard] retry later"],
  ["imperative after a fact token", "[pr-created] #12 Open it"],
  ["second line carries the imperative", "[a] key=value\n[b] Retry now"],
  ["three-word sentence (pre-existing bound)", "[x] Please retry now"],
];

const ACCEPTED = [
  ["path line", "[plan] C:/tmp/plans/outline.md"],
  ["key=value line", "[EM Supervisor] block severity=error findings=2"],
  ["identifier line", "[bash-guard] BG-REDIRECT-OUT"],
  ["URL line", "[pr-created] #123 https://github.com/example/repo/pull/123"],
  ["bracketed enum only", "[confirm-skipped: CONFIRM_DETAIL=off]"],
  ["lone lowercase enum value", "[x] pending"],
  ["lone ALL-CAPS enum value", "[supervisor] WARN"],
  ["quoted command string", "[run-tests] \"bash tests/run-all.sh\" exit=1"],
];

describe("short English prose is rejected", () => {
  for (const [name, msg] of REJECTED) {
    test(`${name}: ${JSON.stringify(msg)}`, () => {
      const problems = C.systemMessageProblems(msg);
      assert.ok(problems.some((p) => /english-(run|word)/.test(p)), `problems=${JSON.stringify(problems)}`);
      assert.throws(() => C.assertSystemMessageContract(msg), /breaks the contract/);
      assert.match(cli(msg), /^BAD:.*english-(run|word)/);
    });
  }
});

describe("language-neutral fact lines are accepted", () => {
  for (const [name, msg] of ACCEPTED) {
    test(`${name}: ${JSON.stringify(msg)}`, () => {
      assert.deepStrictEqual(C.systemMessageProblems(msg), []);
      assert.doesNotThrow(() => C.assertSystemMessageContract(msg));
      assert.strictEqual(cli(msg), "OK");
    });
  }
});

describe("non-prose contract breaks still reported", () => {
  test("untagged line", () => assert.ok(C.systemMessageProblems("plain").some((p) => p.startsWith("line1-untagged"))));
  test("empty message", () => assert.deepStrictEqual(C.systemMessageProblems("  "), ["empty"]));
  test("directive inside systemMessage", () => {
    assert.ok(C.systemMessageProblems(`[x] ${C.directiveSentence("japanese")}`).includes("directive-in-system-message"));
  });
});
