"use strict";
// The real-engine shape and run-order matrix (#2658). Rows are grouped so each entrypoint stays inside
// the per-file timeout: one engine run costs seconds. Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const { test } = require("node:test");
const { FILE, FROM_B, EDITED, NESTED, inW, readW, makeTools } = require("./tools");

const JSONL = `${JSON.stringify({ uuid: "t1", type: "user", timestamp: "2026-01-02T03:04:05.000Z" })}\n`;

function aReplacesFile(F, T, w, row) {
  fs.rmSync(inW(w.a, row.file));
  F.write(inW(w.a, row.nested), NESTED);
  T.commitAllOnL(w.a, "L replaces the file with a directory");
}
function aAddsNested(F, T, w, row) {
  F.write(inW(w.a, row.nested), NESTED);
  T.commitAllOnL(w.a, "L adds the directory side");
}
function bAddsFileAfterANested(F, T, w, row) {
  aAddsNested(F, T, w, row);
  F.write(inW(w.b, row.file), FROM_B);
}
function aPushesBeforeBAddsFile(F, T, w, row) {
  aAddsNested(F, T, w, row);
  T.runStep(w, "A push");
  F.write(inW(w.b, row.file), FROM_B);
}
function aReplacesFileBEdits(F, T, w, row) {
  aReplacesFile(F, T, w, row);
  F.write(inW(w.b, row.file), EDITED);
}

// settledAfter: from that many steps on, the remote head no longer moves. Every row ends with both
// machines in sync. moved: contents that must end in a copy. bKeeps: B's W at the file path at the end.
const MATRIX = [
  {
    group: "a", name: "(a) L replaces a with a/b, R keeps a",
    file: "a", nested: "a/b", seed: { a: FILE }, arrange: aReplacesFile,
    steps: ["A push", "A push", "A push", "B pull", "B pull", "B push"], settledAfter: 1,
    moved: [FILE], bKeeps: FILE,
  },
  {
    group: "a", name: "(a) with B's W edited: the edit and the moved blob are two copies",
    file: "a", nested: "a/b", seed: { a: FILE }, arrange: aReplacesFileBEdits,
    steps: ["A push", "B pull", "B pull", "B push", "B push", "A pull"], settledAfter: 4,
    moved: [FILE, EDITED], bKeeps: EDITED,
  },
  {
    group: "a", name: "(a) on a nested .jsonl path, with the directory side two levels deep",
    file: "p1/t.jsonl", nested: "p1/t.jsonl/y/z", seed: { "p1/t.jsonl": JSONL }, arrange: aReplacesFile,
    steps: ["A push", "A push", "B pull", "B push"], settledAfter: 1,
    moved: [JSONL], bKeeps: JSONL,
  },
  {
    group: "b", name: "(b) R adds a while L has a/b, B first",
    file: "a", nested: "a/b", seed: {}, arrange: bAddsFileAfterANested,
    steps: ["B push", "A push", "A push", "A push", "B pull", "B pull", "B pull", "B push"], settledAfter: 2,
    moved: [FROM_B], bKeeps: FROM_B,
  },
  {
    group: "b", name: "(b) R adds a while L has a/b, A first",
    file: "a", nested: "a/b", seed: {}, arrange: aPushesBeforeBAddsFile,
    steps: ["B push", "B push", "A pull", "A push", "B pull"], settledAfter: 1,
    moved: [FROM_B], bKeeps: FROM_B,
  },
];

function assertRowEnd(F, T, w, row) {
  const files = T.filesAt(w.remote);
  assert.ok(!files.includes(row.file), `${row.file} must leave the remote tree: ${files}`);
  assert.strictEqual(F.show(w.remote, "main", row.nested), NESTED, "the directory side stays in the remote");
  const expected = row.moved.map((text) => T.copyPath(row.file, text));
  assert.deepStrictEqual(T.copiesAt(w.remote), [...expected].sort());
  row.moved.forEach((text, i) => assert.strictEqual(F.show(w.remote, "main", expected[i]), text, "the copy holds the file side"));
  T.assertNothingLost(w, [...row.moved, NESTED]);
  T.assertBothMatchRemote(w);
  row.moved.forEach((text, i) => {
    assert.strictEqual(readW(w.a, expected[i]), text, "A's W holds the copy");
    assert.strictEqual(readW(w.b, expected[i]), text, "B's W holds the copy");
  });
  assert.strictEqual(readW(w.b, row.file), row.bKeeps, "B's W keeps its file");
}

function pathShapeMatrix(F, group) {
  const T = makeTools(F);
  for (const row of MATRIX.filter((r) => r.group === group)) {
    test(`matrix: ${row.name}: ${row.steps.join(", ")}`, () => {
      const w = F.world({ seed: row.seed });
      row.arrange(F, T, w, row);
      let settled = null;
      row.steps.forEach((step, i) => {
        const m = T.runStep(w, step);
        if (m === w.a) {
          assert.strictEqual(F.show(m.projects, "main", row.nested), NESTED, `${step} (${i}): the directory side must stay on A's main`);
          assert.strictEqual(readW(m, row.nested), NESTED, `${step} (${i}): the directory side must stay in A's W`);
        }
        if (i + 1 === row.settledAfter) settled = T.head(w.remote);
        if (settled) assert.strictEqual(T.head(w.remote), settled, `${step} (${i}): the remote must not move any further`);
      });
      assertRowEnd(F, T, w, row);
      T.assertRepeatsChangeNothing(w, ["A push", "B pull"]);
    });
  }
}

module.exports = { pathShapeMatrix };
