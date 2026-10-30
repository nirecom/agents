"use strict";
// Tests: bin/check-test-frontmatter/cli.js
// Tags: TL2, bin, check-test-frontmatter, staged, cat-file, real-git, fail-closed, table-driven, scope:issue-specific
// check-test-frontmatter --staged cases of tests/hooks/feature-2507-git-blobs-fail-closed.js (#2507).
// Holds no case markers. run() reads the staged and HEAD blobs through one cat-file --batch; a
// failed read must end rc 2 with its reason, never rc 0 / 1 judged over a blob that was not read.
const assert = require("node:assert");
const { test } = require("node:test");
const { withCatFile, parseBatch, buildBatch, spawnError } = require("./fixture");

const valid = (target) => ['"use strict";', `// Tests: ${target}`, "// Tags: TL1, scope:issue-specific", 'const { caseBegin, caseEnd } = require("../lib/harness");', `caseBegin("one", "${target}");`, "caseEnd();", ""].join("\n");
const noTags = (target) => ['"use strict";', `// Tests: ${target}`, 'const { caseBegin, caseEnd } = require("../lib/harness");', ""].join("\n");

const NEW = "tests/hooks/feature-1-new.js";
const FLAT = "tests/flat-old.js";

// fixture(name) — FLAT tracked in HEAD and modified in the index (allowed only because HEAD has it),
// NEW added (HEAD:NEW is a missing reply).
function fixture(F, name) {
  return F.repo(name, { [FLAT]: valid("hooks/old.js") }, { [FLAT]: valid("hooks/old2.js"), [NEW]: valid("hooks/new.js") });
}

function stagedReads(F) {
  test("a new test file and a modified tracked flat file pass: missing HEAD side is no failure", () => {
    const dir = fixture(F, "cli-ok");
    const got = F.runCli(dir, ["--staged", NEW, FLAT]);
    assert.strictEqual(got.rc, 0, `rc (stderr ${JSON.stringify(got.stderr)})`);
  });
  test("the staged blob is judged, not the worktree copy", () => {
    const dir = F.repo("cli-staged-wins", {}, { [NEW]: noTags("hooks/new.js") });
    F.write(dir, NEW, valid("hooks/new.js"));
    const got = F.runCli(dir, ["--staged", NEW]);
    assert.strictEqual(got.rc, 1, `the staged copy lacks Tags: (stderr ${JSON.stringify(got.stderr)})`);
    assert.ok(got.stderr.includes(NEW), `names the file: ${JSON.stringify(got.stderr)}`);
  });
  test("the HEAD blob is read: a flat file HEAD lacks is rejected, the tracked one is not", () => {
    const dir = F.repo("cli-head", { [FLAT]: valid("hooks/old.js") }, { "tests/flat-new.js": valid("hooks/new.js") });
    const tracked = F.runCli(dir, ["--staged", FLAT]);
    assert.strictEqual(tracked.rc, 0, `tracked flat file (stderr ${JSON.stringify(tracked.stderr)})`);
    const added = F.runCli(dir, ["--staged", "tests/flat-new.js"]);
    assert.strictEqual(added.rc, 1, `new flat file (stderr ${JSON.stringify(added.stderr)})`);
  });
}

const CLI_ROWS = [
  ["spawn error ETIMEDOUT", (r) => spawnError("ETIMEDOUT", r.stdout)],
  ["spawn error with status 0 and the whole reply", (r) => ({ ...r, error: spawnError("ETIMEDOUT").error })],
  ["spawn error ENOBUFS", (r) => spawnError("ENOBUFS", r.stdout.subarray(0, 30))],
  ["spawn error ENOENT", () => spawnError("ENOENT")],
  ["non-zero exit", (r) => ({ ...r, status: 128 })],
  ["killed by a signal", (r) => ({ ...r, status: null, signal: "SIGKILL" })],
  ["reply cut after the first object", (r) => ({ ...r, stdout: buildBatch(parseBatch(r.stdout).slice(0, 1)) })],
  ["no LF after the last body", (r) => {
    const o = parseBatch(r.stdout);
    const last = o.length - 1;
    return { ...r, stdout: buildBatch(o.map((x, i) => (i === last ? { ...x, end: "" } : x))) };
  }],
];

function stagedFailsClosed(F) {
  const dir = fixture(F, "cli-closed");
  test("control: the parsed-and-rebuilt reply still ends rc 0", () => {
    const { value: got } = withCatFile((r) => ({ ...r, stdout: buildBatch(parseBatch(r.stdout)) }), () => F.runCli(dir, ["--staged", NEW, FLAT]));
    assert.strictEqual(got.rc, 0, `rc (stderr ${JSON.stringify(got.stderr)})`);
  });
  for (const [label, edit] of CLI_ROWS) {
    test(`--staged ends rc 2 with the reason: ${label}`, () => {
      let got;
      try {
        got = withCatFile(edit, () => F.runCli(dir, ["--staged", NEW, FLAT])).value;
      } catch (e) {
        if (e && e.fromEdit) throw e;
        assert.fail(`${label}: run() threw instead of returning rc 2: ${e && e.message}`);
      }
      assert.strictEqual(got.rc, 2, `${label}: rc (stderr ${JSON.stringify(got.stderr)})`);
      assert.ok(/cat-file/.test(got.stderr), `${label}: stderr names the failed read: ${JSON.stringify(got.stderr)}`);
    });
  }
}

module.exports = { stagedReads, stagedFailsClosed };
