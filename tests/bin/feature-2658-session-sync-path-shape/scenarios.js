"use strict";
// Real-engine path-shape scenarios outside the matrix (#2658). Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { TAG, FILE, FROM_B, NESTED, okRun, inW, readW, isFileInW, makeTools } = require("./tools");

function pullOnly(F) {
  const T = makeTools(F);
  test("(b-pull) a pull-only machine exits 0 twice, keeps a/b, gets the copy, and a later push publishes it", () => {
    const w = F.world();
    F.write(inW(w.a, "a/b"), NESTED);
    T.commitAllOnL(w.a, "L adds a/b");
    F.write(inW(w.b, "a"), FROM_B);
    T.runStep(w, "B push");
    const remoteHead = T.head(w.remote);
    const copy = T.copyPath("a", FROM_B);

    T.runStep(w, "A pull");
    const afterFirst = { head: T.head(w.a.projects), conflicts: T.conflictCount(w.a) };
    assert.strictEqual(readW(w.a, copy), FROM_B);
    assert.strictEqual(readW(w.a, "a/b"), NESTED);
    assert.deepStrictEqual(T.filesAt(w.a.projects).filter((n) => n === "a"), [], "A's main holds no file a");

    T.runStep(w, "A pull");
    assert.deepStrictEqual({ head: T.head(w.a.projects), conflicts: T.conflictCount(w.a) }, afterFirst);
    assert.strictEqual(T.head(w.remote), remoteHead, "a pull publishes nothing");

    T.runStep(w, "A push");
    T.runStep(w, "B pull");
    T.assertBothMatchRemote(w);
    assert.strictEqual(F.show(w.remote, "main", copy), FROM_B);
  });
}

const RESET_SHAPES = [
  {
    name: "B keeps file a while the remote holds a/b",
    prepare(F, T, w) {
      F.write(inW(w.a, "a/b"), NESTED);
      T.commitAllOnL(w.a, "L adds a/b");
      T.runStep(w, "A push");
      F.write(inW(w.b, "a"), FROM_B);
      return w.b;
    },
    blocked: true,
  },
  {
    name: "A holds a/b in W while the remote holds file a",
    prepare(F, T, w) {
      F.write(inW(w.b, "a"), FROM_B);
      T.runStep(w, "B push");
      F.write(inW(w.a, "a/b"), NESTED);
      return w.a;
    },
    blocked: false,
  },
];

function resetShapes(F) {
  const T = makeTools(F);
  for (const shape of RESET_SHAPES) {
    test(`reset, ${shape.name}: the repeat makes no new copy, and a push then publishes the copy`, () => {
      const w = F.world();
      const m = shape.prepare(F, T, w);
      const copy = T.copyPath("a", FROM_B);
      const copiesInW = () => fs.readdirSync(m.projects).filter((n) => n.includes(TAG));

      okRun(F.engine(m, "reset"), "first reset");
      assert.deepStrictEqual(copiesInW(), [copy]);
      assert.strictEqual(readW(m, copy), FROM_B);
      const conflicts = T.conflictCount(m);
      const main = T.head(m.projects);

      okRun(F.engine(m, "reset"), "second reset");
      assert.deepStrictEqual(copiesInW(), [copy], "no new copy");
      assert.strictEqual(T.conflictCount(m), conflicts, "no new conflict record");
      assert.strictEqual(T.head(m.projects), main, "main stays");
      if (shape.blocked) assert.ok(F.readState(m).writeBlocked.count > 0, "the blocked write is reported");

      okRun(F.engine(m, "push"), "push after the reset");
      if (!shape.blocked) assert.strictEqual(readW(m, "a/b"), NESTED, "the directory side survives in W");
      T.assertNothingLost(w, [FROM_B, NESTED]);
    });
  }
}

const STATUS_LINE = (r) => r.stdout.split("\n").filter((l) => l.startsWith("writeBlocked:"));

function residualBehaviour(F) {
  const T = makeTools(F);
  test("documenting behaviour: a machine keeping blocking file a keeps its content, gets the copy but not a/b, and reports it; reset after deleting a restores a/b", () => {
    const w = F.world({ seed: { a: FILE } });
    fs.rmSync(inW(w.a, "a"));
    F.write(inW(w.a, "a/b"), NESTED);
    T.commitAllOnL(w.a, "L replaces a with a/b");
    T.runStep(w, "A push");
    T.runStep(w, "B pull");

    assert.strictEqual(readW(w.b, "a"), FILE, "the blocking file is unchanged");
    assert.ok(isFileInW(w.b, "a"));
    assert.strictEqual(readW(w.b, T.copyPath("a", FILE)), FILE, "the copy still arrives");
    assert.strictEqual(F.show(w.b.projects, "main", "a/b"), NESTED, "main is complete even though W is not");
    const blocked = F.readState(w.b).writeBlocked;
    assert.ok(blocked.count >= 1, JSON.stringify(blocked));
    assert.strictEqual(blocked.path, "a/b");

    const blockedStatus = F.engine(w.b, "status");
    okRun(blockedStatus, "B status");
    assert.deepStrictEqual(STATUS_LINE(blockedStatus), [`writeBlocked: ${blocked.count} (last: a/b)`]);
    const cleanStatus = F.engine(w.a, "status");
    okRun(cleanStatus, "A status");
    assert.deepStrictEqual(STATUS_LINE(cleanStatus), ["writeBlocked: 0"], "zero-shaped when nothing was blocked");

    fs.rmSync(inW(w.b, "a"));
    okRun(F.engine(w.b, "reset"), "B reset after the user deleted a");
    assert.strictEqual(readW(w.b, "a/b"), NESTED, "reset restores a/b");
    assert.strictEqual(readW(w.b, T.copyPath("a", FILE)), FILE, "the copy stays");
    T.assertBothMatchRemote(w);
  });
}

function plansThroughEngine(F) {
  const T = makeTools(F);
  test("a push exits 0 with plans as a file in projects, and a plans/ directory from the other machine moves that file to a copy", () => {
    const w = F.world();
    F.write(inW(w.b, "plans"), "a file named plans\n");
    F.write(path.join(w.b.plans, "x.md"), "plan x\n");
    T.runStep(w, "B push");
    assert.strictEqual(F.show(w.remote, "main", "plans"), "a file named plans\n");

    F.write(inW(w.a, "plans/y.md"), "plan y\n");
    T.commitAllOnL(w.a, "L adds plans/y.md");
    T.runStep(w, "A push");
    T.runStep(w, "B pull");
    assert.strictEqual(F.show(w.remote, "main", "plans/y.md"), "plan y\n");
    assert.strictEqual(F.show(w.remote, "main", T.copyPath("plans", "a file named plans\n")), "a file named plans\n");
    assert.strictEqual(readW(w.b, "plans"), "a file named plans\n");
  });
}

module.exports = { pullOnly, resetShapes, residualBehaviour, plansThroughEngine };
