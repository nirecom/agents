"use strict";
// Local-deletion parts of tests/bin/feature-2658-session-sync-engine.js (#2658): a path deleted only
// by an unpushed commit on local main must not leave the remote. Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const NO_CHANGE = "No changes to push.";
const FILE_KINDS = [
  { kind: "non-jsonl", rel: "p1/note.md", text: "keep me\n", newer: "written again\n" },
  { kind: "jsonl", rel: "p1/t.jsonl", text: jline("keep") + "\n", newer: jline("again") + "\n" },
];
const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
const inW = (m, rel) => path.join(m.projects, ...rel.split("/"));

// World clones carry no core.hooksPath of their own, so the installed pre-commit hook must be kept out here.
function commitOnL(F, m, message) {
  F.git(m.projects, ["config", "core.hooksPath", "/dev/null"]);
  F.git(m.projects, ["commit", "-q", "-m", message]);
}

function deleteOnL(F, m, rel) {
  F.git(m.projects, ["rm", "-q", rel]);
  commitOnL(F, m, `L deletes ${rel}`);
}

function assertSecondPushIsQuiet(F, m) {
  const again = F.engine(m, "push");
  okRun(again, "second push");
  assert.strictEqual(again.stdout.trim(), NO_CHANGE, "the sync must converge, not ping-pong");
}

function keptInRemote(F) {
  for (const { kind, rel, text } of FILE_KINDS) {
    test(`a ${kind} path deleted only on L stays in the remote and out of W, and a second push reports no change`, () => {
      const w = F.world({ seed: { [rel]: text } });
      deleteOnL(F, w.a, rel);
      F.write(inW(w.a, "p1/other.md"), "another change\n");
      const r = F.engine(w.a, "push");
      okRun(r, "A push");
      assert.strictEqual(r.stdout.trim(), "Pushed session data.");
      assert.ok(F.show(w.remote, "main", "p1/other.md") !== null, "the other change is published");
      assert.strictEqual(F.show(w.remote, "main", rel), text, "the push must not delete the path from the remote");
      assert.strictEqual(F.show(w.a.projects, "main", rel), text, "L is rebuilt on M");
      assert.ok(!fs.existsSync(inW(w.a, rel)), "W stays without the path");
      assertSecondPushIsQuiet(F, w.a);
      assert.ok(!fs.existsSync(inW(w.a, rel)), "W stays without the path after the second push");
      okRun(F.engine(w.b, "pull"), "B pull");
      assert.strictEqual(fs.readFileSync(inW(w.b, rel), "utf8"), text, "another machine keeps the path");
    });
  }
  test("a delete-only commit on L publishes nothing", () => {
    const { rel, text } = FILE_KINDS[0];
    const w = F.world({ seed: { [rel]: text } });
    const tip = F.git(w.remote, ["rev-parse", "main"]);
    deleteOnL(F, w.a, rel);
    const r = F.engine(w.a, "push");
    okRun(r, "A push");
    assert.strictEqual(r.stdout.trim(), NO_CHANGE);
    assert.strictEqual(F.git(w.remote, ["rev-parse", "main"]), tip, "the remote tip does not move");
    assert.ok(!fs.existsSync(inW(w.a, rel)), "W stays without the path");
  });
  test("the path deleted on L goes back with its executable mode", () => {
    const w = F.world({ seed: { "p1/run.sh": "#!/bin/sh\n" } });
    F.git(w.a.projects, ["update-index", "--chmod=+x", "p1/run.sh"]);
    commitOnL(F, w.a, "make it executable");
    F.git(w.a.projects, ["push", "-q", "origin", "main"]);
    deleteOnL(F, w.a, "p1/run.sh");
    F.write(inW(w.a, "p1/other.md"), "another change\n");
    okRun(F.engine(w.a, "push"), "A push");
    assert.match(F.git(w.remote, ["ls-tree", "main", "p1/run.sh"]), /^100755 /);
  });
}

function recreatedInW(F) {
  for (const { kind, rel, text, newer } of FILE_KINDS) {
    test(`a ${kind} path deleted on L and written again in W publishes the new content`, () => {
      const w = F.world({ seed: { [rel]: text } });
      deleteOnL(F, w.a, rel);
      F.write(inW(w.a, rel), newer);
      okRun(F.engine(w.a, "push"), "A push");
      assert.strictEqual(F.show(w.remote, "main", rel), newer);
      assert.strictEqual(fs.readFileSync(inW(w.a, rel), "utf8"), newer, "W keeps the new content");
      assertSecondPushIsQuiet(F, w.a);
    });
  }
  test("a path deleted on L and written back with the same content moves nothing", () => {
    const { rel, text } = FILE_KINDS[0];
    const w = F.world({ seed: { [rel]: text } });
    const tip = F.git(w.remote, ["rev-parse", "main"]);
    deleteOnL(F, w.a, rel);
    F.write(inW(w.a, rel), text);
    const r = F.engine(w.a, "push");
    okRun(r, "A push");
    assert.strictEqual(r.stdout.trim(), NO_CHANGE);
    assert.strictEqual(F.git(w.remote, ["rev-parse", "main"]), tip);
    assert.strictEqual(fs.readFileSync(inW(w.a, rel), "utf8"), text);
  });
}

function remoteChanged(F) {
  for (const { kind, rel, text, newer } of FILE_KINDS) {
    test(`a remote change to a ${kind} path deleted on L wins over the delete and reaches W`, () => {
      const w = F.world({ seed: { [rel]: text } });
      deleteOnL(F, w.a, rel);
      F.write(inW(w.b, rel), newer);
      okRun(F.engine(w.b, "push"), "B push");
      const remote = F.show(w.remote, "main", rel);
      assert.ok(remote.includes(newer), `B's change must be on the remote: ${remote}`);
      okRun(F.engine(w.a, "push"), "A push");
      assert.strictEqual(F.show(w.remote, "main", rel), remote, "the remote change survives");
      assert.strictEqual(fs.readFileSync(inW(w.a, rel), "utf8"), remote, "A's W takes the remote version");
      assertSecondPushIsQuiet(F, w.a);
    });
  }
  test("a pull also brings back a path deleted on L when the remote changed it", () => {
    const { rel, text, newer } = FILE_KINDS[0];
    const w = F.world({ seed: { [rel]: text } });
    deleteOnL(F, w.a, rel);
    F.write(inW(w.b, rel), newer);
    okRun(F.engine(w.b, "push"), "B push");
    okRun(F.engine(w.a, "pull"), "A pull");
    assert.strictEqual(F.show(w.a.projects, "main", rel), newer);
    assert.strictEqual(fs.readFileSync(inW(w.a, rel), "utf8"), newer);
  });
  test("a path deleted on both L and the remote stays deleted", () => {
    const { rel, text } = FILE_KINDS[0];
    const w = F.world({ seed: { [rel]: text } });
    deleteOnL(F, w.b, rel);
    F.git(w.b.projects, ["push", "-q", "origin", "main"]);
    deleteOnL(F, w.a, rel);
    okRun(F.engine(w.a, "push"), "A push");
    assert.strictEqual(F.show(w.remote, "main", rel), null);
    assert.ok(!fs.existsSync(inW(w.a, rel)));
    assertSecondPushIsQuiet(F, w.a);
  });
  test("a path deleted on L, written again in W and changed on the remote keeps both versions", () => {
    const rel = "p1/note.md";
    const w = F.world({ seed: { [rel]: "base\n" } });
    deleteOnL(F, w.a, rel);
    F.write(inW(w.a, rel), "from A\n");
    F.write(inW(w.b, rel), "from B\n");
    okRun(F.engine(w.b, "push"), "B push");
    okRun(F.engine(w.a, "push"), "A push");
    assert.strictEqual(F.show(w.remote, "main", rel), "from B\n");
    const copies = fs.readdirSync(inW(w.a, "p1")).filter((n) => n.startsWith("note.sync-conflict-"));
    assert.strictEqual(copies.length, 1, `copies: ${copies}`);
    assert.strictEqual(F.show(w.remote, "main", `p1/${copies[0]}`), "from A\n", "the local version is synced as a copy");
  });
}

const NOW = new Date(Date.UTC(2026, 0, 2, 3, 4, 5));
const COPY = "p1/note.sync-conflict-hostA-20260102T030405Z.md";

// classifyConflict(F, w, editLDiff) — sync classification of machine A with a fixed host and clock.
function classifyConflict(F, w, editLDiff) {
  const G = F.lib("git");
  const dir = w.a.projects;
  F.git(dir, ["fetch", "-q", "origin"]);
  const L = G.revParse(dir, G.MAIN);
  const R = G.revParse(dir, G.ORIGIN);
  const B = G.mergeBase(dir, L, R);
  const lDiff = G.diffTree(dir, B, L);
  editLDiff(lDiff);
  const localBlob = F.git(dir, ["hash-object", "-w", "p1/note.md"]);
  const stats = F.lib("state").newStats();
  const { out } = F.lib("classify").classify({
    mode: "sync", dir, host: "hostA", now: NOW, R, lMap: G.lsTree(dir, L), stats, lDiff,
    w: new Map([["p1/note.md", { kind: "mod", blob: localBlob, mode: "100644", sig: null }]]),
    rDiff: G.diffTree(dir, B, R),
  });
  assert.strictEqual(stats.conflicts.length, 1, JSON.stringify(stats.conflicts));
  return { out, copy: stats.conflicts[0].copy, localBlob };
}

function siblingAvoidsLDeleted(F) {
  test("addSibling does not reuse a name L deleted and R still has, and the unit is forced onto that collision", () => {
    const w = F.world({ seed: { "p1/note.md": "base\n", [COPY]: "an older copy\n" } });
    deleteOnL(F, w.a, COPY);
    F.write(inW(w.a, "p1/note.md"), "from A\n");
    F.write(inW(w.b, "p1/note.md"), "from B\n");
    okRun(F.engine(w.b, "push"), "B push");

    const taken = classifyConflict(F, w, () => {});
    const numbered = "p1/note.sync-conflict-hostA-20260102T030405Z-2.md";
    assert.strictEqual(taken.copy, numbered);
    assert.strictEqual(taken.out.delta.get(numbered).blob, taken.localBlob, "the copy holds the local content");
    assert.ok(taken.out.ops.some((op) => op.rel === numbered && op.blob === taken.localBlob), "the copy reaches W");
    assert.strictEqual(F.git(w.a.projects, ["cat-file", "blob", taken.out.delta.get(COPY).blob]), "an older copy",
      "the L-deleted path keeps its own content in M");

    const free = classifyConflict(F, w, (lDiff) => lDiff.delete(COPY));
    assert.strictEqual(free.copy, COPY, "without the lDiff entry nothing else reserves the name");
  });
}

// classifyPure — sync classification with made-up blob ids, so only branches that never call git may run.
function classifyPure(F, { lDiff, lMap = new Map(), w = new Map(), rDiff = new Map() }) {
  return F.lib("classify").classify({
    mode: "sync", dir: F.TMP, host: "h", now: NOW, R: null, lMap, w, rDiff, lDiff: new Map(lDiff),
    stats: F.lib("state").newStats(),
  }).out;
}

const deletion = (oldMode = "100644") => ({ status: "D", mode: "000000", oldMode, oldBlob: "aaaa", newBlob: null });

function classifierVerdicts(F) {
  test("classify restores an L-deleted path with its old mode and blob, and queues no W op", () => {
    const out = classifyPure(F, { lDiff: [["p1/x.sh", deletion("100755")]] });
    assert.deepStrictEqual(out.delta.get("p1/x.sh"), { mode: "100755", blob: "aaaa" });
    assert.deepStrictEqual(out.ops, []);
  });
  for (const rel of ["workflow/state.json", "p1/a.tmp", ".gitignore", ".gitattributes", ".history.jsonl"]) {
    test(`classify does not restore the excluded or special L-deleted path ${rel}`, () => {
      const out = classifyPure(F, { lDiff: [[rel, deletion()]] });
      assert.strictEqual(out.delta.has(rel), false);
      assert.deepStrictEqual(out.ops, []);
    });
  }
  test("classify leaves paths L only added or modified to M's base tree", () => {
    const lEntry = { mode: "100644", blob: "bbbb" };
    const out = classifyPure(F, {
      lDiff: [
        ["p1/added.md", { status: "A", mode: "100644", oldMode: "000000", oldBlob: null, newBlob: "bbbb" }],
        ["p1/changed.md", { status: "M", mode: "100644", oldMode: "100644", oldBlob: "aaaa", newBlob: "bbbb" }],
      ],
      lMap: new Map([["p1/added.md", lEntry], ["p1/changed.md", lEntry]]),
    });
    assert.strictEqual(out.delta.size, 0, JSON.stringify([...out.delta]));
  });
  test("classify takes W's blob over the old one when W holds an L-deleted path again", () => {
    const out = classifyPure(F, {
      lDiff: [["p1/x.md", deletion()]],
      w: new Map([["p1/x.md", { kind: "mod", blob: "cccc", mode: "100644", sig: null }]]),
    });
    assert.deepStrictEqual(out.delta.get("p1/x.md"), { mode: "100644", blob: "cccc" });
  });
  test("classify in reset mode runs without an lDiff and brings the remote path back to W", () => {
    const { out } = F.lib("classify").classify({
      mode: "reset", dir: F.TMP, host: "h", now: NOW, R: "r", lMap: new Map(), w: new Map(),
      rMap: new Map([["p1/x.md", { mode: "100644", blob: "dddd" }]]), stats: F.lib("state").newStats(),
    });
    assert.strictEqual(out.delta.size, 0);
    assert.deepStrictEqual(out.ops.map((op) => [op.rel, op.kind, op.blob]), [["p1/x.md", "blob", "dddd"]]);
  });
  test("an excluded or special path deleted on L is not put back by a push", () => {
    const w = F.world({ seed: { "p1/a.tmp": "t\n", ".gitignore": "custom\n" } });
    deleteOnL(F, w.a, "p1/a.tmp");
    deleteOnL(F, w.a, ".gitignore");
    F.write(inW(w.a, "p1/other.md"), "another change\n");
    okRun(F.engine(w.a, "push"), "A push");
    assert.strictEqual(F.show(w.remote, "main", "p1/a.tmp"), null);
    assert.strictEqual(F.show(w.remote, "main", ".gitignore"), null);
  });
}

function resetWithLDeleted(F) {
  test("reset brings back a path deleted on L and moves main onto the remote", () => {
    const { rel, text } = FILE_KINDS[0];
    const w = F.world({ seed: { [rel]: text } });
    deleteOnL(F, w.a, rel);
    const r = F.engine(w.a, "reset");
    okRun(r, "A reset");
    assert.strictEqual(r.stdout.trim(), "Reset to remote state.");
    assert.strictEqual(fs.readFileSync(inW(w.a, rel), "utf8"), text, "W takes the remote version");
    assert.strictEqual(F.git(w.a.projects, ["rev-parse", "main"]), F.git(w.remote, ["rev-parse", "main"]));
    assert.strictEqual(F.show(w.remote, "main", rel), text);
  });
  test("reset keeps a conflict copy while L has a deleted path", () => {
    const w = F.world({ seed: { "p1/note.md": "base\n", "p1/gone.md": "gone\n" } });
    deleteOnL(F, w.a, "p1/gone.md");
    F.write(inW(w.a, "p1/note.md"), "from A\n");
    F.write(inW(w.b, "p1/note.md"), "from B\n");
    okRun(F.engine(w.b, "push"), "B push");
    okRun(F.engine(w.a, "reset"), "A reset");
    assert.strictEqual(fs.readFileSync(inW(w.a, "p1/note.md"), "utf8"), "from B\n");
    const copies = fs.readdirSync(inW(w.a, "p1")).filter((n) => n.startsWith("note.sync-conflict-"));
    assert.deepStrictEqual(copies.map((n) => fs.readFileSync(inW(w.a, `p1/${n}`), "utf8")), ["from A\n"]);
    assert.strictEqual(fs.readFileSync(inW(w.a, "p1/gone.md"), "utf8"), "gone\n");
  });
}

module.exports = { commitOnL, keptInRemote, recreatedInW, remoteChanged, siblingAvoidsLDeleted, classifierVerdicts, resetWithLDeleted };
