"use strict";
// Real-commit part of tests/hooks/feature-2507-precommit-node.js (#2507): the marker sequence of a
// clean commit, the stop point and wording of every blocking section, the test-file gates, a
// foreign repo reached through a global core.hooksPath, and the early end at a non-GitHub origin.
// No case markers.
const assert = require("node:assert");
const { test } = require("node:test");
const { SECTIONS, GATES, GATE_MARKERS, AGENTS_SEQUENCE, HARD_TERM, show } = require("./commit-template");

const commentRun = (n) => `"use strict";\n${Array.from({ length: n }, (_, i) => `// fixture comment line ${i}`).join("\n")}\nmodule.exports = 1;\n`;

function cleanSequence(X) {
  test("a clean agents-repo commit prints the eleven sections with the six gates inside agents-repo-gates", () => {
    const dir = X.agents("clean");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    X.write(dir, "app.txt", "x\n");
    X.stage(dir, ["app.txt"]);
    const r = X.commit(dir);
    assert.strictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 2, "the commit was made");
    assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE);
    assert.deepStrictEqual(r.calls.filter((c) => c !== "prompt-extraction"), GATES.map(([, , n]) => n));
    assert.ok(!r.stderr.includes("Commit blocked"), show(r));
  });
}

// [label, setup(X, dir) -> env, wording that must appear, last marker]
const BLOCKS = [
  ["enforce-worktree", () => ({ ENFORCE_WORKTREE: "on" }),
    ["ENFORCE_WORKTREE: commits from main worktree are blocked.", "Work from a linked worktree. Run: /worktree-start"], "enforce-worktree"],
  ["code-lang", (X, dir) => {
    X.write(dir, "lang.js", "// 日本語のコメントです\nmodule.exports = 1;\n");
    X.stage(dir, ["lang.js"]);
    return { CODE_LANG: "english" };
  }, ["Commit blocked: CODE_LANG policy violation in staged files.", "lang-check: ignore"], "code-lang"],
  ["sh-exec-bit", (X, dir) => {
    X.write(dir, "tool.sh", "#!/bin/bash\necho x\n");
    X.stage(dir, ["tool.sh"], { exec: false });
    return {};
  }, ["pre-commit: .sh files lacking execute permission:", "tool.sh", "Run: git update-index --chmod=+x <file>"], "sh-exec-bit"],
  ["prompt-extraction", () => ({ F2507_PE_FAIL: "prompt-extraction:1" }),
    ["gate-out prompt-extraction", "Commit blocked: prompt extraction violations in staged files."], "prompt-extraction"],
  ["tests-frontmatter", (X, dir) => {
    X.write(dir, "tests/flat-fixture.sh", "#!/bin/bash\necho x\n");
    X.stage(dir, ["tests/flat-fixture.sh"], { exec: true });
    return {};
  }, ["Commit blocked: new test entrypoint placed directly under tests/."], "tests-frontmatter"],
  ["agents-repo gate", () => ({ F2507_GATE_FAIL: "check-root-names:2" }),
    ["gate-out check-root-names", "Commit blocked: root-name violations (checker rc=2).", "See docs/architecture/claude-code/root-names.md."],
    GATE_MARKERS[5]],
  ["comment-block-size", (X, dir) => {
    X.write(dir, "lib-fixture.js", commentRun(14));
    X.stage(dir, ["lib-fixture.js"]);
    return {};
  }, ["Commit blocked: staged code carries over-threshold comment blocks."], "comment-block-size"],
  ["env-file-block", (X, dir) => {
    X.write(dir, "sub/.env", "K=v\n");
    X.stage(dir, ["sub/.env"], { force: true });
    return {};
  }, ["pre-commit: .env file(s) staged for commit:", "  sub/.env", "Use .env.example / .env.sample / .env.template instead."], "env-file-block"],
  ["outbound-scan hard", (X, dir) => {
    X.write(dir, "leak.txt", `value ${HARD_TERM}\n`);
    X.stage(dir, ["leak.txt"]);
    return {};
  }, ["Commit blocked: private information detected in staged files."], "outbound-scan"],
];

function blockingSections(X) {
  for (const [label, setup, wording, last] of BLOCKS) {
    test(`${label}: the commit is refused with the bash wording and ends at ${last}`, () => {
      const dir = X.agents(`block-${last}`);
      X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
      X.write(dir, "app.txt", "x\n");
      X.stage(dir, ["app.txt"]);
      const env = setup(X, dir);
      const r = X.commit(dir, { env });
      assert.notStrictEqual(r.status, 0, show(r));
      assert.strictEqual(X.headCount(dir), 1, "no commit was made");
      for (const w of wording) assert.ok(r.stderr.includes(w), `missing ${JSON.stringify(w)}\n${show(r)}`);
      assert.strictEqual(r.markers[r.markers.length - 1], last, show(r));
      assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf(last) + 1));
    });
  }
}

// Two staged JS tests that pass the frontmatter gate: one names two targets without case
// markers, one tests a bash target. The harness helper is in the template's index.
const NO_MARKERS = ["\"use strict\";", "// Tests: hooks/workflow-state.js, hooks/lib/session-markers.js",
  "// Tags: TL1, fixture, scope:issue-specific", "const { isolate } = require(\"../lib/harness\");",
  "const { test } = require(\"node:test\");", "isolate();", "test(\"fixture case\", () => {});", ""].join("\n");
const WRONG_LANG = ["\"use strict\";", "// Tests: bin/scan-outbound.sh", "// Tags: TL1, fixture, scope:issue-specific",
  "const { caseBegin, caseEnd } = require(\"../lib/harness\");", "const { test } = require(\"node:test\");",
  "caseBegin(\"one\", \"bin/scan-outbound.sh\");", "test(\"fixture case\", () => {});", "caseEnd();", ""].join("\n");
const TEST_GATES = [
  ["case-marker", "tests/hooks/cm-fixture.js", NO_MARKERS, [
    "HIGH: tests/hooks/cm-fixture.js", "code=MISSING_CASE_MARKERS", "Commit blocked: new test file(s) fail the case-marker gate.",
    "Wrap each case in column-0 caseBegin(\"<name>\", \"<target>\") and caseEnd() calls."]],
  ["language-match", "tests/hooks/lm-fixture.js", WRONG_LANG, [
    "HIGH: tests/hooks/lm-fixture.js: test language js does not match code language bash of bin/scan-outbound.sh (new file shape: <name>.sh) code=TEST_LANGUAGE_MISMATCH",
    "Commit blocked: test file(s) fail the language-match gate.",
    "Write the test in the code's language (see the new file shape), or declare a valid test-lang-exception in Tags: (rules/test.md)."]],
];

// One fixture copy serves both commits (the TL2 time budget): the first file leaves the index
// before the second is staged.
function testFileGates(X) {
  test("case-marker and language-match violations are refused at tests-frontmatter with the bash wording", () => {
    const dir = X.agents("test-gates");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    for (const [label, rel, body, wording] of TEST_GATES) {
      X.write(dir, rel, body);
      X.stage(dir, [rel]);
      const r = X.commit(dir);
      assert.notStrictEqual(r.status, 0, `${label}\n${show(r)}`);
      assert.strictEqual(X.headCount(dir), 1, `${label}: no commit was made`);
      for (const w of wording) assert.ok(r.stderr.includes(w), `${label}: missing ${JSON.stringify(w)}\n${show(r)}`);
      assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf("tests-frontmatter") + 1), label);
      X.git(dir, ["rm", "-q", "--cached", "--", rel]);
    }
  });
}

function foreignRepo(X) {
  test("a foreign repo through a global core.hooksPath: no prompt-extraction, gates or comment-block stop", () => {
    const hook = X.agents("foreign-hook");
    const dir = X.foreign("foreign", hook);
    X.write(dir, ".prompt-extraction-allowlist", "");
    X.write(dir, "big-comment.js", commentRun(14));
    X.write(dir, "rules/fixture.md", "prompt body\n");
    X.stage(dir, [".prompt-extraction-allowlist", "big-comment.js", "rules/fixture.md"]);
    const r = X.commit(dir, { hookRepo: hook, env: { F2507_PE_FAIL: "prompt-extraction:1", F2507_GATE_FAIL: "check-on-demand-rules:1" } });
    assert.strictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 2);
    assert.deepStrictEqual(r.markers, SECTIONS, "the eleven sections and no gate marker, as the bash hook prints");
    assert.deepStrictEqual(r.calls, [], "no gate and no prompt-extraction checker ran");
    assert.ok(!r.stderr.includes("Commit blocked"), show(r));
  });
}

function nonGithubOrigin(X) {
  test("a non-GitHub origin ends the hook at repo-visibility: no env-file-block, no outbound-scan", () => {
    const dir = X.agents("non-github");
    X.git(dir, ["remote", "add", "origin", "https://example.invalid/agents-fixture.git"]);
    X.write(dir, "sub/.env", "K=v\n");
    X.write(dir, "leak.txt", `value ${HARD_TERM}\n`);
    X.stage(dir, ["sub/.env"], { force: true });
    X.stage(dir, ["leak.txt"]);
    const r = X.commit(dir);
    assert.strictEqual(r.status, 0, show(r));
    assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf("repo-visibility") + 1));
    assert.ok(!r.markers.includes("env-file-block") && !r.markers.includes("outbound-scan"));
  });
}

module.exports = { cleanSequence, blockingSections, testFileGates, foreignRepo, nonGithubOrigin };
