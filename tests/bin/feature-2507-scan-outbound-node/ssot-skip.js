"use strict";
// Cases 5-6 (TL1): SKIP_PATTERNS keeps today's list and the new modules scan clean under it;
// hard-secret-patterns.js is the one pattern source both the scanner and secret-shape.js read;
// 6c/6d pin each of the 11 patterns with a detected value and a near miss.

const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const util = require("node:util");
const { abs, MOD, NEW_MODULE_FILES, dropPortCache, load, golden } = require("./common");
const SB = require("./sandbox");
const C = require("./corpus");

function runSkipAndSelfScan(root) {
  const { isSkippedPath } = load("precommitCheck");
  for (const [p, want] of Object.entries(golden("skip-patterns").cases)) {
    assert.strictEqual(isSkippedPath(p), want, `${p}: grep -qE SKIP_PATTERNS said ${want}`);
  }
  // The modules are not on the skip list, so their source must not trip the built-in patterns.
  const missing = NEW_MODULE_FILES.filter((f) => !fs.existsSync(abs(f)));
  assert.deepStrictEqual(missing, [], "every new module exists before it can be self-scanned");
  SB.setLists(root, C.LISTS.empty);
  const r = SB.runCli(root, { argv: NEW_MODULE_FILES.map(abs), stdin: null });
  assert.strictEqual(r.rc, 0, `self-scan of the new modules is clean; stdout=${r.stdout} stderr=${r.stderr}`);
}

const STUB_LABEL = "fixture-secret";
const STUB_VALUE = ["fixq", "_", "12345678"].join("");

function withStub(exportsDesc, fn) {
  const p = abs(MOD.hardSecret);
  // Copy descriptors, not values: a spread would fire the "unreadable" getter right here.
  const entry = { id: p, filename: p, loaded: true };
  Object.defineProperties(entry, Object.getOwnPropertyDescriptors(exportsDesc));
  require.cache[p] = entry;
  dropPortCache(p);
  try {
    fn();
  } finally {
    delete require.cache[p];
    dropPortCache();
  }
}

function runHardSecretTable() {
  const { HARD_SECRET_PATTERNS } = load("hardSecret");
  const want = golden("hard-secret-patterns").patterns;
  assert.strictEqual(want.length, 11, "the golden holds the 11 bash entries");
  assert.deepStrictEqual(HARD_SECRET_PATTERNS, want, "the entries equal the bash block, in order");
}

function runHardSecretShared() {
  const empty = { allow: [], blockHard: [], blockWarn: [] };

  withStub({ exports: { HARD_SECRET_PATTERNS: [{ label: STUB_LABEL, group: "-", ere: "fixq_[0-9]{8}" }] } }, () => {
    const shape = load("secretShape");
    assert.strictEqual(shape.isSecretShaped(`x ${STUB_VALUE} y`), true, "secret-shape reads the stubbed source");
    assert.strictEqual(shape.isSecretShaped(`x ${C.SECRETS.github} y`), false, "secret-shape no longer has a second source");
    const res = load("scanText").scanText(`x ${STUB_VALUE} y\n`, { file: "f.txt", lists: empty });
    const kinds = res.details.findings.map((f) => f.kind);
    assert.deepStrictEqual(kinds, [STUB_LABEL], "scanText reads the stubbed source too");
  });

  withStub({ exports: { HARD_SECRET_PATTERNS: [] } }, () => {
    assert.throws(() => load("secretShape").isSecretShaped("x"), "secret-shape throws on an empty pattern source");
    let incomplete = null;
    try {
      incomplete = load("scanText").scanText("x\n", { file: "f.txt", lists: empty }).details.incomplete;
    } catch {
      incomplete = { reason: "threw" };
    }
    assert.ok(incomplete, "scanText refuses to scan with no hard-secret patterns (bash: rc 4)");
  });

  withStub({ get exports() { throw new Error("fixture: unreadable pattern source"); } }, () => {
    assert.throws(() => load("secretShape").isSecretShaped("x"), "secret-shape throws on an unreadable pattern source");
  });
}

const sha = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
const LINE_RE = /^(.*?):(\d+): \[([^\]]+)\] (.*)$/;

// Findings grouped per table row ([{kind, matchedSha256}]); matched text is kept only as a hash.
function shapeRows(findings) {
  const rows = C.HARD_SECRET_SHAPES.map(() => []);
  for (const f of findings) rows[f.line - 1].push({ kind: f.kind, matchedSha256: sha(f.matched) });
  return Object.fromEntries(C.HARD_SECRET_SHAPES.map((s, i) => [s.name, rows[i]]));
}

// bash --stdin output -> shapeRows (the golden generator's recorder).
function shapeRowsFromStdout(stdout) {
  const found = stdout.split("\n").map((l) => LINE_RE.exec(l)).filter(Boolean);
  return shapeRows(found.map(([, , line, kind, matched]) => ({ line: Number(line), kind, matched })));
}

// 6c: the table covers all 11 labels with a hit and a near miss, and its explicit want equals
// what bash reported; a hit reports the whole value.
function runHardSecretShapeTable() {
  const g = golden("hard-secret-shapes").cases;
  const labels = golden("hard-secret-patterns").patterns.map((p) => p.label);
  assert.deepStrictEqual(Object.keys(g), C.HARD_SECRET_SHAPES.map((s) => s.name), "golden covers the table (regenerate after editing it)");
  for (const label of labels) {
    const rows = C.HARD_SECRET_SHAPES.filter((s) => s.label === label);
    assert.ok(rows.some((s) => s.name.endsWith("-hit") && s.want.includes(label)), `${label}: a detected example`);
    assert.ok(rows.some((s) => s.name.includes("-near-") && !s.want.includes(label)), `${label}: a near shape it does not detect`);
  }
  for (const s of C.HARD_SECRET_SHAPES) {
    assert.deepStrictEqual(g[s.name].map((f) => f.kind), s.want, `${s.name}: bash reported ${JSON.stringify(g[s.name].map((f) => f.kind))}`);
    if (s.name.endsWith("-hit")) assert.strictEqual(g[s.name][0].matchedSha256, sha(s.text), `${s.name}: the match is the whole value`);
  }
}

// 6d: scanText reports, per row, the labels and matched text bash reported.
function runHardSecretShapeScan() {
  const g = golden("hard-secret-shapes").cases;
  const res = load("scanText").scanText(C.hardSecretShapesInput().toString("utf8"), { file: "shapes.txt", lists: { allow: [], blockHard: [], blockWarn: [] } });
  const got = shapeRows(res.details.findings);
  const failures = C.HARD_SECRET_SHAPES.filter((s) => !util.isDeepStrictEqual(got[s.name], g[s.name]))
    .map((s) => `${s.name}: want ${JSON.stringify(s.want)}, got ${JSON.stringify(got[s.name].map((f) => f.kind))}`);
  assert.deepStrictEqual(failures, [], "every row equals the bash golden (labels and sha256 of the match)");
}

module.exports = { runSkipAndSelfScan, runHardSecretTable, runHardSecretShared, runHardSecretShapeTable, runHardSecretShapeScan, shapeRowsFromStdout };
