"use strict";
// diffTree parts of tests/bin/feature-2658-session-sync-engine.js (#2658): the entry fields the
// local-delete restore reads, against real commits. Holds no case markers.
const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");
const { commitOnL } = require("./local-delete");

function diffTreeModes(F) {
  test("diffTree returns oldMode on a deletion, a modification, a mode change and an addition", () => {
    const G = F.lib("git");
    const w = F.world({ seed: { "p1/doc.md": "one\n", "p1/run.sh": "#!/bin/sh\n", "p1/flip.sh": "#!/bin/sh\n" } });
    const dir = w.a.projects;
    const at = () => F.git(dir, ["rev-parse", "HEAD"]);
    F.git(dir, ["update-index", "--chmod=+x", "p1/run.sh"]);
    commitOnL(F, w.a, "make run.sh executable");
    const before = at();
    F.write(path.join(dir, "p1", "doc.md"), "two\n");
    F.git(dir, ["add", "p1/doc.md"]);
    F.git(dir, ["update-index", "--chmod=+x", "p1/flip.sh"]);
    commitOnL(F, w.a, "modify doc.md, flip flip.sh");
    const changed = at();
    F.git(dir, ["rm", "-q", "p1/doc.md", "p1/run.sh"]);
    commitOnL(F, w.a, "delete doc.md and run.sh");
    const deleted = at();

    const mod = G.diffTree(dir, before, changed);
    assert.strictEqual(mod.get("p1/doc.md").oldMode, "100644");
    assert.strictEqual(mod.get("p1/doc.md").mode, "100644");
    assert.ok(mod.get("p1/doc.md").oldBlob && mod.get("p1/doc.md").newBlob);
    assert.notStrictEqual(mod.get("p1/doc.md").oldBlob, mod.get("p1/doc.md").newBlob);
    assert.strictEqual(mod.get("p1/flip.sh").oldMode, "100644");
    assert.strictEqual(mod.get("p1/flip.sh").mode, "100755");

    const del = G.diffTree(dir, changed, deleted);
    assert.deepStrictEqual(
      [del.get("p1/doc.md").status, del.get("p1/doc.md").oldMode, del.get("p1/doc.md").mode, del.get("p1/doc.md").newBlob],
      ["D", "100644", "000000", null]);
    assert.strictEqual(del.get("p1/doc.md").oldBlob, mod.get("p1/doc.md").newBlob);
    assert.deepStrictEqual([del.get("p1/run.sh").oldMode, del.get("p1/run.sh").mode], ["100755", "000000"]);

    const add = G.diffTree(dir, deleted, changed);
    assert.deepStrictEqual([add.get("p1/run.sh").status, add.get("p1/run.sh").oldMode, add.get("p1/run.sh").mode], ["A", "000000", "100755"]);
    assert.strictEqual(add.get("p1/run.sh").oldBlob, null);
  });
  test("diffTree throws on a commit that does not exist", () => {
    const G = F.lib("git");
    const w = F.world();
    assert.throws(() => G.diffTree(w.a.projects, "0".repeat(40), "HEAD"), /diff-tree/);
  });
}

module.exports = { diffTreeModes };
