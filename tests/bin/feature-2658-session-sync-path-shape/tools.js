"use strict";
// Shared helpers for the real-engine path-shape cases (#2658). Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const TAG = ".sync-conflict-";
const FILE = "file a\n";
const FROM_B = "file a from B\n";
const EDITED = "file a edited on B\n";
const NESTED = "nested\n";

const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
const inW = (m, rel) => path.join(m.projects, ...rel.split("/"));
const readW = (m, rel) => fs.readFileSync(inW(m, rel), "utf8");
const isFileInW = (m, rel) => {
  const st = fs.lstatSync(inW(m, rel), { throwIfNoEntry: false });
  return Boolean(st && st.isFile());
};

function makeTools(F) {
  const head = (dir) => F.git(dir, ["rev-parse", "main"]);
  const tree = (dir) => F.git(dir, ["rev-parse", "main^{tree}"]);
  const filesAt = (dir) => F.git(dir, ["ls-tree", "-r", "--name-only", "main"]).split("\n").filter(Boolean);
  const copiesAt = (dir) => filesAt(dir).filter((n) => n.includes(TAG)).sort();
  const conflictCount = (m) => (F.readState(m) || { conflicts: [] }).conflicts.length;

  // Spelled out here rather than through collisionCopyName, so the name itself is under test.
  function copyPath(rel, text) {
    const { dir, name, ext } = path.posix.parse(rel);
    const hash = F.lib("git").blobIdOf(Buffer.from(text, "utf8")).slice(0, 12);
    return `${dir ? `${dir}/` : ""}${name}${TAG}${hash}${ext}`;
  }

  function commitAllOnL(m, message) {
    F.git(m.projects, ["config", "core.hooksPath", "/dev/null"]);
    F.git(m.projects, ["add", "-A"]);
    F.git(m.projects, ["commit", "-q", "-m", message]);
  }

  function runStep(w, step) {
    const [who, action] = step.split(" ");
    const m = who === "A" ? w.a : w.b;
    okRun(F.engine(m, action), step);
    return m;
  }

  function assertNothingLost(w, texts) {
    const held = new Set(filesAt(w.remote).map((rel) => F.show(w.remote, "main", rel)));
    for (const text of texts) assert.ok(held.has(text), `lost from the remote tree: ${JSON.stringify(text)}`);
  }

  function assertBothMatchRemote(w) {
    const expected = tree(w.remote);
    assert.strictEqual(tree(w.a.projects), expected, "A's main tree equals the remote's");
    assert.strictEqual(tree(w.b.projects), expected, "B's main tree equals the remote's");
  }

  // Further runs change nothing: remote head, the copies, and the conflict records stay as they are.
  function assertRepeatsChangeNothing(w, steps) {
    const snapshot = () => ({ head: head(w.remote), copies: copiesAt(w.remote), a: conflictCount(w.a), b: conflictCount(w.b) });
    const before = snapshot();
    for (const step of steps) runStep(w, step);
    assert.deepStrictEqual(snapshot(), before);
  }

  return { head, tree, filesAt, copiesAt, conflictCount, copyPath, commitAllOnL, runStep, assertNothingLost, assertBothMatchRemote, assertRepeatsChangeNothing };
}

module.exports = { TAG, FILE, FROM_B, EDITED, NESTED, okRun, inW, readW, isFileInW, makeTools };
