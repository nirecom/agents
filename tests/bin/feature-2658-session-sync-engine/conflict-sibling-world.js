"use strict";
// Two-clone conflict-sibling parts of the #2658 session-sync engine suite: when two clones push
// different lines under one uuid, the losing line must survive on both clones in a conflict copy,
// whichever machine pushes first, and a second round must not churn. Moved out of
// feature-2658-session-sync-engine-integrate-4.js to keep each entrypoint under the runner timeout.
// Holds no case markers; each export registers the tests of one case.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const lines = (...ls) => ls.join("\n") + "\n";
const A1 = jline("a1");
const TAG = ".sync-conflict-";

// ranked(F) -> [top, mid, low]: three lines of one uuid ordered by the winner union itself picks, so
// no case pins the exact winner rule.
function ranked(F) {
  const U = (...args) => F.lib("jsonl").union(...args);
  return ["alpha", "middle", "omega"]
    .map((message) => jline("k-conflict", { message }))
    .sort((a, b) => (U(lines(a), lines(b)).text === lines(a) ? -1 : 1));
}

const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
const k = (m) => path.join(m.projects, "p1", "k.jsonl");
const copies = (m) => fs.readdirSync(path.join(m.projects, "p1")).filter((n) => n.includes(TAG)).sort();

// conflictWorld(F, firstLine, secondLine) -> a world where A pushes firstLine, then B pushes secondLine.
function conflictWorld(F, firstLine, secondLine) {
  const w = F.world({ seed: { "p1/k.jsonl": lines(A1) } });
  fs.appendFileSync(k(w.a), firstLine + "\n");
  fs.appendFileSync(k(w.b), secondLine + "\n");
  okRun(F.engine(w.a, "push"), "A push");
  okRun(F.engine(w.b, "push"), "B push");
  okRun(F.engine(w.a, "pull"), "A pull");
  okRun(F.engine(w.b, "pull"), "B pull");
  return w;
}

function losingLineSurvives(F) {
  const rev = (w) => F.git(w.remote, ["rev-parse", "main"]);
  test("two clones converge and the losing line reaches both clones in a conflict copy, without churn", () => {
    const [top, , low] = ranked(F);
    const w = conflictWorld(F, top, low);
    const a = fs.readFileSync(k(w.a), "utf8");
    assert.strictEqual(a, fs.readFileSync(k(w.b), "utf8"), "byte-identical transcript");
    assert.strictEqual(a, lines(A1, top));
    assert.strictEqual(F.show(w.remote, "main", "p1/k.jsonl"), a);
    const names = copies(w.b);
    assert.strictEqual(names.length, 1, `one conflict copy: ${names}`);
    assert.deepStrictEqual(copies(w.a), names, "the conflict copy reached the other clone");
    for (const m of [w.a, w.b]) assert.strictEqual(fs.readFileSync(path.join(m.projects, "p1", names[0]), "utf8"), lines(low));
    assert.deepStrictEqual(F.readState(w.b).conflicts.map((c) => [c.path, c.copy, c.lostLines]), [["p1/k.jsonl", `p1/${names[0]}`, 1]]);

    const head = rev(w);
    okRun(F.engine(w.a, "push"), "A push again");
    okRun(F.engine(w.b, "push"), "B push again");
    okRun(F.engine(w.a, "pull"), "A pull again");
    okRun(F.engine(w.b, "pull"), "B pull again");
    assert.deepStrictEqual(copies(w.a), names, "no further conflict copy on A");
    assert.deepStrictEqual(copies(w.b), names, "no further conflict copy on B");
    assert.strictEqual(rev(w), head, "the second round moves nothing");
    assert.strictEqual(fs.readFileSync(k(w.a), "utf8"), a);
    assert.strictEqual(fs.readFileSync(k(w.b), "utf8"), a);
  });
}

function loserPushesFirst(F) {
  test("the losing line survives on the clones when the losing machine pushes first", () => {
    const [top, , low] = ranked(F);
    const w = conflictWorld(F, low, top);
    const a = fs.readFileSync(k(w.a), "utf8");
    assert.strictEqual(a, fs.readFileSync(k(w.b), "utf8"), "byte-identical transcript");
    const held = (m) => copies(m).map((n) => fs.readFileSync(path.join(m.projects, "p1", n), "utf8")).join("");
    assert.ok(held(w.a).includes(low), `A holds no copy of the losing line: copies=${copies(w.a)} transcript=${a}`);
    assert.ok(held(w.b).includes(low), `B holds no copy of the losing line: copies=${copies(w.b)}`);
  });
}

module.exports = { losingLineSurvives, loserPushesFirst };
