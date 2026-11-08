"use strict";
// Tests: bin/lib/session-sync/classify.js
// Tags: TL2, session-sync, session-sync-engine, path-shape, real-git, two-clone, scope:issue-specific
// #2658: a file replaced by a directory on one machine, run through the real engine in each order.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");
const { pathShapeMatrix } = require("./feature-2658-session-sync-path-shape/matrix");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-path-shape-matrix-a-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

caseBegin("e2e-file-replaced-by-directory-matrix", "bin/lib/session-sync/classify.js");
pathShapeMatrix(F, "a");
caseEnd();

// Copy-slot reuse in resolvePathCollisions: file `a` collides with directory a/b. Blob ids are made up,
// so only classify branches that never call git run here.
const assert = require("node:assert");
const { test } = require("node:test");

const BLOB = "0123456789abcdef".repeat(2) + "01234567";
const OTHER = "fedcba9876543210".repeat(2) + "76543210";
const THIRD = "3".repeat(40);
const NESTED_BLOB = "2".repeat(40);
const HASH = BLOB.slice(0, 12);
const COPY = `a.sync-conflict-${HASH}`;
const COPY2 = `${COPY}-2`;
const COPY3 = `${COPY}-3`;
const entry = (blob, mode = "100644") => ({ mode, blob });
const mod = (blob) => ({ kind: "mod", blob, mode: "100644", sig: null });
const removed = (blob) => ({ status: "D", mode: "000000", oldMode: "100644", oldBlob: blob, newBlob: null });

function runClassify({ onDisk = [], lMap = {}, w = {}, rDiff = {} }) {
  const dir = fs.mkdtempSync(path.join(TMP, "slot-"));
  for (const rel of onDisk) F.write(path.join(dir, ...rel.split("/")), "on disk\n");
  const stats = F.lib("state").newStats();
  const base = {
    mode: "sync", dir, host: "h", now: new Date(), R: null, stats,
    lMap: new Map(Object.entries(lMap)), w: new Map(Object.entries(w)),
    rDiff: new Map(Object.entries(rDiff)), lDiff: new Map(),
  };
  const { out } = F.lib("classify").classify(base);
  return {
    delta: Object.fromEntries(out.delta),
    ops: out.ops.map((op) => op.rel).sort(),
    conflicts: stats.conflicts.map((c) => ({ path: c.path, copy: c.copy })),
  };
}

function slotCase(name, why, input, want) {
  caseBegin(name, "bin/lib/session-sync/classify.js");
  test(`resolvePathCollisions: ${why}`, () => {
    const got = runClassify(input);
    assert.deepStrictEqual(got.delta, want.delta);
    assert.deepStrictEqual(got.ops, [...want.ops].sort());
    assert.deepStrictEqual(got.conflicts, want.conflicts);
  });
  caseEnd();
}

slotCase("collision-copy-slot-same-blob-in-delta-reused",
  "a copy name the delta holds with the same blob is reused, with no suffixed name and no record",
  { lMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB), [COPY]: mod(BLOB) }, onDisk: [COPY] },
  { delta: { a: null, [COPY]: entry(BLOB) }, ops: [], conflicts: [] });

slotCase("collision-copy-slot-deleted-this-round-takes-suffix-2",
  "a copy name deleted this round keeps its null, and the file's blob goes to the -2 name",
  { lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(BLOB) }, w: { a: mod(BLOB) }, rDiff: { [COPY]: removed(BLOB) } },
  { delta: { a: null, [COPY]: null, [COPY2]: entry(BLOB) }, ops: [COPY2], conflicts: [{ path: "a", copy: COPY2 }] });

slotCase("collision-copy-slot-deleted-keeps-extension-last",
  "the -2 suffix goes before the extension",
  {
    lMap: { "n.md/b": entry(NESTED_BLOB), [`n.sync-conflict-${HASH}.md`]: entry(BLOB) },
    w: { "n.md": mod(BLOB) }, rDiff: { [`n.sync-conflict-${HASH}.md`]: removed(BLOB) },
  },
  {
    delta: { "n.md": null, [`n.sync-conflict-${HASH}.md`]: null, [`n.sync-conflict-${HASH}-2.md`]: entry(BLOB) },
    ops: [`n.sync-conflict-${HASH}-2.md`], conflicts: [{ path: "n.md", copy: `n.sync-conflict-${HASH}-2.md` }],
  });

slotCase("collision-copy-slot-edited-copy-takes-suffix-2",
  "an edited copy in the delta stays as is, and the file's blob goes to the -2 name",
  { onDisk: [COPY], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(BLOB) }, w: { a: mod(BLOB), [COPY]: mod(OTHER) } },
  { delta: { a: null, [COPY]: entry(OTHER), [COPY2]: entry(BLOB) }, ops: [COPY2], conflicts: [{ path: "a", copy: COPY2 }] });

slotCase("collision-copy-slot-base-other-blob-takes-suffix-2",
  "a base copy name holding another blob is not overwritten, and the file's blob goes to the -2 name",
  { onDisk: [COPY], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY2]: entry(BLOB) }, ops: [COPY2], conflicts: [{ path: "a", copy: COPY2 }] });

slotCase("collision-copy-slot-suffix-2-in-base-takes-suffix-3",
  "when the base holds the -2 name too, the -3 name is used",
  { onDisk: [COPY, COPY2], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER), [COPY2]: entry(THIRD) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY3]: entry(BLOB) }, ops: [COPY3], conflicts: [{ path: "a", copy: COPY3 }] });

slotCase("collision-copy-slot-suffix-2-on-disk-takes-suffix-3",
  "when only the working tree holds the -2 name, the -3 name is used",
  { onDisk: [COPY, COPY2], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY3]: entry(BLOB) }, ops: [COPY3], conflicts: [{ path: "a", copy: COPY3 }] });

slotCase("collision-copy-slot-free-plain-name",
  "with no clash the plain copy name is used, queued, and recorded",
  { lMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY]: entry(BLOB) }, ops: [COPY], conflicts: [{ path: "a", copy: COPY }] });

slotCase("collision-copy-slot-free-plain-name-present-in-w",
  "with no clash and the copy already in the working tree, no op is queued but the record is kept",
  { onDisk: [COPY], lMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY]: entry(BLOB) }, ops: [], conflicts: [{ path: "a", copy: COPY }] });

// The same copy-slot clash through the real engine: the plain copy name of `a` already holds other content.
const P = require("./feature-2658-session-sync-path-shape/tools");

function slotE2eCase(name, why, arrange, steps) {
  caseBegin(name, "bin/lib/session-sync/classify.js");
  test(`resolvePathCollisions e2e: ${why}`, () => {
    const T = P.makeTools(F);
    const plain = T.copyPath("a", P.FILE);
    const w = F.world({ seed: { a: P.FILE, [plain]: P.EDITED } });
    const keepsPlain = arrange(T, w, plain);
    for (const step of steps) T.runStep(w, step);
    const files = () => T.filesAt(w.remote).sort();
    const end = files();
    assert.deepStrictEqual(T.copiesAt(w.remote).filter((n) => n !== plain), [`${plain}-2`], "only the -2 numbered copy");
    if (keepsPlain) assert.strictEqual(F.show(w.remote, "main", plain), P.EDITED, "the plain copy keeps its edit");
    assert.ok(!end.includes("a"), `a leaves the remote tree: ${end}`);
    assert.strictEqual(F.show(w.remote, "main", "a/b"), P.NESTED, "the directory side stays");
    assert.strictEqual(F.show(w.remote, "main", `${plain}-2`), P.FILE, "the moved file survives under -2");
    T.assertBothMatchRemote(w);
    for (const m of [w.a, w.b]) {
      assert.strictEqual(P.readW(m, `${plain}-2`), P.FILE, `${m.name}'s W holds the -2 copy`);
      if (keepsPlain) assert.strictEqual(P.readW(m, plain), P.EDITED, `${m.name}'s W keeps the edited plain copy`);
    }
    assert.strictEqual(P.readW(w.a, "a/b"), P.NESTED, "A's W keeps a/b");
    const contents = () => end.map((rel) => F.show(w.remote, "main", rel));
    const before = contents();
    T.assertRepeatsChangeNothing(w, ["A push", "B push", "A pull", "B pull"]);
    assert.deepStrictEqual(files(), end, "no -3 copy or other path appears");
    assert.deepStrictEqual(contents(), before);
    assert.strictEqual(P.readW(w.b, `${plain}-2`), P.FILE);
  });
  caseEnd();
}

function aReplacesA(T, w) {
  fs.rmSync(P.inW(w.a, "a"));
  F.write(P.inW(w.a, "a/b"), P.NESTED);
  T.commitAllOnL(w.a, "L replaces a with a/b");
}

slotE2eCase("e2e-collision-copy-slot-occupied-takes-suffix-2",
  "a plain copy name holding edited content keeps it, and a's content lands in the -2 copy on both clones",
  (T, w) => { aReplacesA(T, w); return true; },
  ["A push", "B pull", "B push", "A pull"]);

// The additive engine never pushes a W deletion, so the same-round deletion arrives as a remote commit.
function remoteDeletes(w, rel) {
  F.git(w.seed, ["pull", "-q"]);
  F.git(w.seed, ["rm", "-q", rel]);
  F.git(w.seed, ["commit", "-q", "-m", "remote deletes the plain copy"]);
  F.git(w.seed, ["push", "-q"]);
}

slotE2eCase("e2e-collision-copy-slot-deleted-same-round-takes-suffix-2",
  "with the plain copy name deleted on the remote in the same round, a's content lands in the -2 copy",
  (T, w, plain) => { aReplacesA(T, w); remoteDeletes(w, plain); return false; },
  ["A push", "B pull", "B push", "A pull"]);
