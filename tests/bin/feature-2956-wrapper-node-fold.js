// tests/bin/feature-2956-wrapper-node-fold.js
// Tests: bin/lib/test-wrappers/node-reporter.mjs, bin/lib/test-wrappers/node.js
// Tags: scope:issue-specific, test-language-wrapper, node, run-all, result-dir, fail-details, tl2
// #2956 S3: the node wrapper writes one fail-details.tsv record (<seq>\t<case>\t<text>) per failed
// test, holding the whole error message folded by the shared rule; every row of
// tests/fixtures/fail-detail-fold.tsv must come out as its expected text, and the record's seq must
// be the one cases.tsv gives the same case after node.js renumbers the scratch seqs.
"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const WRAPPER = path.join(ROOT, "bin", "lib", "test-wrappers", "node.js");
const FIXTURE = path.join(ROOT, "tests", "fixtures", "fail-detail-fold.tsv");

const expand = (s) => s.replace(/@@REP:(\d+):([A-Za-z])@@/g, (_, n, c) => c.repeat(Number(n)));
const ESC = { "\\": "\\", t: "\t", r: "\r", n: "\n" };
const decode = (s) => s.replace(/\\([\\trn])/g, (_, c) => ESC[c]);

function loadRows() {
  return fs
    .readFileSync(FIXTURE, "utf8")
    .split("\n")
    .filter((l) => l !== "" && !l.startsWith("#"))
    .map((l) => {
      const [name, input, want] = l.replace(/\r$/, "").split("\t");
      return { name, input: expand(decode(input)), want: expand(want) };
    });
}

// runFold() — a node:test fixture with one failing test per row; returns the result dir.
function runFold(rows) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "f2956-node-"));
  const inDir = path.join(tmp, "in");
  const res = path.join(tmp, "res");
  fs.mkdirSync(inDir);
  fs.mkdirSync(res);
  rows.forEach((r, i) => fs.writeFileSync(path.join(inDir, `${i}.txt`), r.input));
  const body = rows
    .map((_, i) => `test("row_${i}_end", () => { assert.fail(fs.readFileSync(${JSON.stringify(path.join(inDir, `${i}.txt`))}, "utf8")); });`)
    .join("\n");
  const fx = path.join(tmp, "fold.test.js");
  fs.writeFileSync(fx, `"use strict";\nconst { test } = require("node:test");\nconst assert = require("node:assert");\nconst fs = require("node:fs");\n${body}\n`);
  const env = { ...process.env, RUN_ALL_RESULT_DIR: res, RUN_ALL_RESULT_OWNER: fx };
  // A node:test parent marks its children; the wrapper's own runner must not inherit that mark.
  delete env.NODE_TEST_CONTEXT;
  const done = spawnSync(process.execPath, [WRAPPER, fx, "20.0"], { cwd: tmp, env, encoding: "utf8", timeout: 120000 });
  return { tmp, res, done };
}

const readTsv = (p) =>
  fs.existsSync(p) ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t")) : null;

caseBegin("fail-details-fold-matches-fixture", "bin/lib/test-wrappers/node-reporter.mjs");
test("each fixture row folds to its expected fail-details text", () => {
  const restore = isolate();
  const rows = loadRows();
  const { tmp, res, done } = runFold(rows);
  try {
    assert.equal(done.status, 1, `wrapper rc (stdout=${done.stdout} stderr=${done.stderr})`);
    const cases = readTsv(path.join(res, "cases.tsv")) || [];
    assert.equal(cases.filter((c) => c[1] === "FAIL").length, rows.length, "one FAIL case record per fixture row");
    const details = readTsv(path.join(res, "fail-details.tsv"));
    assert.ok(details, "fail-details.tsv written to the result dir");
    rows.forEach((r, i) => {
      const name = `row_${i}_end`;
      const got = details.filter((d) => d[1] === name);
      assert.equal(got.length, 1, `${r.name}: one record for ${name}`);
      assert.equal(got[0][2], r.want, `${r.name}: folded text`);
      const seq = cases.filter((c) => c[2] === name).map((c) => c[0]);
      assert.ok(seq.length > 0 && seq.includes(got[0][0]), `${r.name}: seq ${got[0][0]} matches cases.tsv ${seq}`);
    });
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
    restore();
  }
});
caseEnd();
