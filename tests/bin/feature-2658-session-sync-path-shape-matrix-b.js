"use strict";
// Tests: bin/lib/session-sync/classify.js
// Tags: TL2, session-sync, session-sync-engine, path-shape, real-git, two-clone, scope:issue-specific
// #2658: the remote adds a file where local main has a directory, in both run orders and pull-only.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures } = require("./feature-2658-session-sync-engine/fixtures");
const { pathShapeMatrix } = require("./feature-2658-session-sync-path-shape/matrix");
const { pullOnly } = require("./feature-2658-session-sync-path-shape/scenarios");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-path-shape-matrix-b-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

caseBegin("e2e-remote-file-over-local-directory-matrix", "bin/lib/session-sync/classify.js");
pathShapeMatrix(F, "b");
caseEnd();

caseBegin("e2e-pull-only-collision", "bin/lib/session-sync/classify.js");
pullOnly(F);
caseEnd();

// Copy slots that are directories in the final tree, and numbered slots reused when they hold the
// same blob: file `a` collides with directory a/b. Blob ids are made up, so no case reaches git.
const assert = require("node:assert");
const { test } = require("node:test");

const BLOB = "0123456789abcdef".repeat(2) + "01234567";
const OTHER = "fedcba9876543210".repeat(2) + "76543210";
const THIRD = "3".repeat(40);
const NESTED_BLOB = "2".repeat(40);
const COPY = `a.sync-conflict-${BLOB.slice(0, 12)}`;
const COPY2 = `${COPY}-2`;
const COPY3 = `${COPY}-3`;
const entry = (blob) => ({ mode: "100644", blob });
const mod = (blob) => ({ kind: "mod", blob, mode: "100644", sig: null });
const added = (blob) => ({ status: "A", mode: "100644", oldMode: "000000", oldBlob: null, newBlob: blob });

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
    blobOps: out.ops.filter((op) => op.kind === "blob").map((op) => [op.rel, op.blob]).sort(),
    conflicts: stats.conflicts.map((c) => ({ path: c.path, copy: c.copy })),
  };
}

function slotCase(name, why, input, want) {
  caseBegin(name, "bin/lib/session-sync/classify.js");
  test(`resolvePathCollisions: ${why}`, () => {
    const got = runClassify(input);
    assert.deepStrictEqual(got.delta, want.delta);
    assert.deepStrictEqual(got.ops, [...want.ops].sort());
    assert.deepStrictEqual(got.blobOps, want.ops.map((rel) => [rel, want.delta[rel].blob]).sort());
    assert.deepStrictEqual(got.conflicts, want.conflicts);
  });
  caseEnd();
}

slotCase("collision-copy-slot-dir-at-plain-slot-in-base-takes-suffix-2",
  "a plain copy name that is a directory in the base is never used, and the file's blob goes to the -2 name",
  { onDisk: [`${COPY}/x`], lMap: { "a/b": entry(NESTED_BLOB), [`${COPY}/x`]: entry(THIRD) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY2]: entry(BLOB) }, ops: [COPY2], conflicts: [{ path: "a", copy: COPY2 }] });

slotCase("collision-copy-slot-dir-at-plain-slot-in-delta-takes-suffix-2",
  "a plain copy name that becomes a directory this round is never used, and its nested file stays as is",
  { onDisk: [`${COPY}/x`], lMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB), [`${COPY}/x`]: mod(THIRD) } },
  { delta: { a: null, [`${COPY}/x`]: entry(THIRD), [COPY2]: entry(BLOB) }, ops: [COPY2], conflicts: [{ path: "a", copy: COPY2 }] });

slotCase("collision-copy-slot-dir-at-suffix-2-takes-suffix-3",
  "with the plain name holding another blob and the -2 name a directory, the -3 name is used",
  {
    onDisk: [COPY, `${COPY2}/x`],
    lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER), [`${COPY2}/x`]: entry(THIRD) }, w: { a: mod(BLOB) },
  },
  { delta: { a: null, [COPY3]: entry(BLOB) }, ops: [COPY3], conflicts: [{ path: "a", copy: COPY3 }] });

slotCase("collision-copy-slot-converge-base-same-blob-reuses-suffix-2",
  "a -2 name the base already holds with the same blob is reused, with no -3 name, no op and no record",
  { onDisk: [COPY, COPY2], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER), [COPY2]: entry(BLOB) }, w: { a: mod(BLOB) } },
  { delta: { a: null, [COPY2]: entry(BLOB) }, ops: [], conflicts: [] });

slotCase("collision-copy-slot-converge-pulled-same-blob-adds-nothing",
  "a -2 name pulled this round with the same blob adds no -3 name, no second op and no record",
  { onDisk: [COPY], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER) }, w: { a: mod(BLOB) }, rDiff: { [COPY2]: added(BLOB) } },
  { delta: { a: null, [COPY2]: entry(BLOB) }, ops: [COPY2], conflicts: [] });

slotCase("collision-copy-slot-converge-local-same-blob-adds-nothing",
  "a -2 name added locally this round with the same blob adds no -3 name, no op and no record",
  { onDisk: [COPY, COPY2], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER) }, w: { a: mod(BLOB), [COPY2]: mod(BLOB) } },
  { delta: { a: null, [COPY2]: entry(BLOB) }, ops: [], conflicts: [] });

slotCase("collision-copy-slot-suffix-2-edited-this-round-takes-suffix-3",
  "a -2 name the base holds with the same blob but edited this round keeps the edit, and the file goes to -3",
  {
    onDisk: [COPY, COPY2], lMap: { "a/b": entry(NESTED_BLOB), [COPY]: entry(OTHER), [COPY2]: entry(BLOB) },
    w: { a: mod(BLOB), [COPY2]: mod(THIRD) },
  },
  { delta: { a: null, [COPY2]: entry(THIRD), [COPY3]: entry(BLOB) }, ops: [COPY3], conflicts: [{ path: "a", copy: COPY3 }] });
