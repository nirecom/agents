"use strict";
// In-process parts of tests/bin/feature-2658-session-sync-path-shape.js (#2658). Blob ids are made up,
// so only classify branches that never call git may run here. Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const BLOB = "0123456789abcdef".repeat(2) + "01234567";
const OTHER = "fedcba9876543210".repeat(2) + "76543210";
const HASH = BLOB.slice(0, 12);

const NAME_ROWS = [
  { why: "no extension", rel: "a", want: `a.sync-conflict-${HASH}` },
  { why: "plain extension", rel: "note.md", want: `note.sync-conflict-${HASH}.md` },
  { why: ".jsonl", rel: "p1/t.jsonl", want: `p1/t.sync-conflict-${HASH}.jsonl` },
  { why: "dotfile at the root", rel: ".env", want: `.env.sync-conflict-${HASH}` },
  { why: "nested dotfile", rel: "p1/.env", want: `p1/.env.sync-conflict-${HASH}` },
  { why: "dotfile with an extension", rel: ".config.json", want: `.config.sync-conflict-${HASH}.json` },
  { why: "nested path without extension", rel: "p1/p2/a", want: `p1/p2/a.sync-conflict-${HASH}` },
  { why: "dotted directory, no extension", rel: "p.d/a", want: `p.d/a.sync-conflict-${HASH}` },
  { why: "multi-dot name", rel: "a.tar.gz", want: `a.tar.sync-conflict-${HASH}.gz` },
];

function collisionCopyNameTable(F) {
  const { collisionCopyName } = F.lib("conflict");
  for (const row of NAME_ROWS) {
    test(`collisionCopyName: ${row.why}`, () => {
      assert.strictEqual(collisionCopyName(row.rel, BLOB), row.want);
      assert.strictEqual(collisionCopyName(row.rel, BLOB), row.want, "same input, same output");
      assert.notStrictEqual(collisionCopyName(row.rel, OTHER), row.want, "another blob, another name");
    });
  }
  test("collisionCopyName depends on neither the host nor the clock", (t) => {
    const before = collisionCopyName("p1/a.md", BLOB);
    t.mock.method(os, "hostname", () => "another-host");
    t.mock.method(Date, "now", () => 0);
    t.mock.method(Date.prototype, "toISOString", () => "1970-01-01T00:00:00.000Z");
    assert.strictEqual(collisionCopyName("p1/a.md", BLOB), before);
  });
}

// A tree of file f, directory d (holding file d/f) under a fresh temp directory.
function shapeDir(F) {
  const dir = fs.mkdtempSync(path.join(F.TMP, "shape-"));
  F.write(path.join(dir, "f"), "file\n");
  F.write(path.join(dir, "d", "f"), "file\n");
  return dir;
}

const BLOCK_ROWS = [
  { why: "free path", rel: "free", want: false },
  { why: "existing regular file target, which a write replaces", rel: "f", want: false },
  { why: "missing parents", rel: "no/such/parent/x", want: false },
  { why: "existing parent, missing leaf", rel: "d/new", want: false },
  { why: "ancestor is a file at depth 1", rel: "f/x", want: true },
  { why: "ancestor is a file at depth 2", rel: "d/f/x", want: true },
  { why: "a file ancestor with more levels below it", rel: "f/x/y/z", want: true },
  { why: "target is a directory", rel: "d", want: true },
];

function pathBlockedTable(F) {
  const { pathBlocked } = F.lib("apply");
  for (const row of BLOCK_ROWS) {
    test(`pathBlocked: ${row.why} -> ${row.want}`, () => {
      assert.strictEqual(pathBlocked(shapeDir(F), row.rel), row.want);
    });
  }
  test("pathBlocked: a root that does not exist blocks nothing", () => {
    assert.strictEqual(pathBlocked(path.join(F.TMP, "no-such-root"), "a/b"), false);
  });
  test("pathBlocked: a symlink ancestor blocks, since a write would leave the tree", (t) => {
    const dir = shapeDir(F);
    try {
      fs.symlinkSync(path.join(dir, "d"), path.join(dir, "link"), "dir");
    } catch {
      t.skip("this platform refused to create the symlink");
      return;
    }
    assert.strictEqual(pathBlocked(dir, "link/x"), true);
  });
}

const OP_KINDS = [
  { kind: "blob", extra: { blob: BLOB } },
  { kind: "text", extra: { text: "op text\n" } },
  { kind: "append", extra: { text: "op text\n" } },
];

function applyOpsGuard(F) {
  const { applyOps, statSig } = F.lib("apply");
  const newStats = () => F.lib("state").newStats();
  const readBlob = () => Buffer.from("blob content\n");
  const later = { rel: "d/later", kind: "text", text: "later\n", pre: null };

  for (const { kind, extra } of OP_KINDS) {
    test(`applyOps: a blocked ${kind} op is skipped and recorded, and the later op still runs`, () => {
      const dir = shapeDir(F);
      const stats = newStats();
      const n = applyOps(dir, [Object.assign({ rel: "f/x", kind }, extra), later], readBlob, stats);
      assert.strictEqual(n, 1, "only the later op counts as written");
      assert.strictEqual(fs.readFileSync(path.join(dir, "f"), "utf8"), "file\n", "the blocking file is untouched");
      assert.strictEqual(fs.readFileSync(path.join(dir, "d", "later"), "utf8"), "later\n");
      assert.deepStrictEqual(stats.writeBlocked, { count: 1, path: "f/x" });
      assert.deepStrictEqual(stats.writeDeferred, { count: 0, path: null });
    });
    test(`applyOps: a ${kind} op on a directory target with pre: null is blocked, not overwritten`, () => {
      const dir = shapeDir(F);
      const stats = newStats();
      const n = applyOps(dir, [Object.assign({ rel: "d", kind, pre: null }, extra)], readBlob, stats);
      assert.strictEqual(n, 0);
      assert.strictEqual(fs.readFileSync(path.join(dir, "d", "f"), "utf8"), "file\n", "the directory is intact");
      assert.deepStrictEqual(stats.writeBlocked, { count: 1, path: "d" });
      assert.deepStrictEqual(stats.writeDeferred, { count: 0, path: null });
    });
  }
  test("applyOps: the shape check runs before the pre comparison, so a stale pre on a blocked path is not deferred", () => {
    const dir = shapeDir(F);
    const stats = newStats();
    const stale = statSig(path.join(dir, "f"));
    assert.strictEqual(applyOps(dir, [{ rel: "f/x", kind: "blob", blob: BLOB, pre: stale }], readBlob, stats), 0);
    assert.deepStrictEqual(stats.writeBlocked, { count: 1, path: "f/x" });
    assert.deepStrictEqual(stats.writeDeferred, { count: 0, path: null });
  });
  test("applyOps: a stale pre on a free path stays deferred, not blocked", () => {
    const dir = shapeDir(F);
    const stats = newStats();
    assert.strictEqual(applyOps(dir, [{ rel: "f", kind: "text", text: "new\n", pre: null }], readBlob, stats), 0);
    assert.strictEqual(fs.readFileSync(path.join(dir, "f"), "utf8"), "file\n");
    assert.deepStrictEqual(stats.writeDeferred, { count: 1, path: "f" });
    assert.deepStrictEqual(stats.writeBlocked, { count: 0, path: null });
  });
  test("applyOps: several blocked ops add up and report the last path", () => {
    const dir = shapeDir(F);
    const stats = newStats();
    const ops = [{ rel: "f/x", kind: "text", text: "1\n" }, { rel: "d", kind: "text", text: "2\n" }];
    assert.strictEqual(applyOps(dir, ops, readBlob, stats), 0);
    assert.deepStrictEqual(stats.writeBlocked, { count: 2, path: "d" });
  });
  test("applyOps: an empty append on a blocked path is a no-op and not counted", () => {
    const stats = newStats();
    assert.strictEqual(applyOps(shapeDir(F), [{ rel: "f/x", kind: "append", text: "" }], readBlob, stats), 0);
    assert.deepStrictEqual(stats.writeBlocked, { count: 0, path: null });
  });
}

const entry = (blob, mode = "100644") => ({ mode, blob });
const mod = (blob, mode = "100644") => ({ kind: "mod", blob, mode, sig: null });
const added = (blob, mode = "100644") => ({ status: "A", mode, oldMode: "000000", oldBlob: null, newBlob: blob });
const removed = (blob) => ({ status: "D", mode: "000000", oldMode: "100644", oldBlob: blob, newBlob: null });
const A_COPY = `a.sync-conflict-${HASH}`;
const NESTED_BLOB = "2".repeat(40);

function runClassify(F, { mode = "sync", onDisk = [], lMap = {}, w = {}, rDiff = {}, rMap = {} }) {
  const dir = fs.mkdtempSync(path.join(F.TMP, "classify-"));
  for (const rel of onDisk) F.write(path.join(dir, ...rel.split("/")), "on disk\n");
  const stats = F.lib("state").newStats();
  const base = {
    mode, dir, host: "h", now: new Date(), R: null, stats,
    lMap: new Map(Object.entries(lMap)), w: new Map(Object.entries(w)),
  };
  if (mode === "reset") base.rMap = new Map(Object.entries(rMap));
  else Object.assign(base, { rDiff: new Map(Object.entries(rDiff)), lDiff: new Map() });
  return { out: F.lib("classify").classify(base).out, stats };
}

const COLLISION_ROWS = [
  {
    why: "a new copy is queued and reported",
    input: { lMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB) } },
    delta: { a: null, [A_COPY]: entry(BLOB) }, ops: [A_COPY], conflicts: ["a"],
  },
  {
    why: "a copy already in the base with the same blob and present in W yields no op and no record",
    input: { onDisk: [A_COPY], lMap: { "a/b": entry(NESTED_BLOB), [A_COPY]: entry(BLOB) }, w: { a: mod(BLOB) } },
    delta: { a: null, [A_COPY]: entry(BLOB) }, ops: [], conflicts: [],
  },
  {
    why: "a copy in the base with the same blob but gone from W is written back without a record",
    input: { lMap: { "a/b": entry(NESTED_BLOB), [A_COPY]: entry(BLOB) }, w: { a: mod(BLOB) } },
    delta: { a: null, [A_COPY]: entry(BLOB) }, ops: [A_COPY], conflicts: [],
  },
  {
    why: "a copy path the delta already holds with another blob: the edited copy is kept and the original blob moves to the -2 name",
    input: {
      onDisk: [A_COPY],
      lMap: { "a/b": entry(NESTED_BLOB), [A_COPY]: entry(BLOB) },
      w: { a: mod(BLOB), [A_COPY]: mod(OTHER) },
    },
    delta: { a: null, [A_COPY]: entry(OTHER), [`${A_COPY}-2`]: entry(BLOB) }, ops: [`${A_COPY}-2`], conflicts: ["a"],
    copies: [`${A_COPY}-2`],
  },
  {
    why: "a non-regular 120000 entry moves in M with no W op",
    input: { lMap: { "a/b": entry(NESTED_BLOB) }, rDiff: { a: added(BLOB, "120000") } },
    delta: { a: null, [A_COPY]: entry(BLOB, "120000") }, ops: [], conflicts: ["a"],
  },
  {
    why: "an executable file keeps its mode in the copy",
    input: { lMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB, "100755") } },
    delta: { a: null, [A_COPY]: entry(BLOB, "100755") }, ops: [A_COPY], conflicts: ["a"],
  },
  {
    why: "the W op of the moved file is replaced by the copy's, on a nested .jsonl",
    input: { lMap: { "p1/t.jsonl/y": entry(NESTED_BLOB) }, rDiff: { "p1/t.jsonl": added(BLOB) } },
    delta: { "p1/t.jsonl": null, [`p1/t.sync-conflict-${HASH}.jsonl`]: entry(BLOB) },
    ops: [`p1/t.sync-conflict-${HASH}.jsonl`], conflicts: ["p1/t.jsonl"],
  },
  {
    why: "a reset moves a local file away from the remote's directory",
    input: { mode: "reset", rMap: { "a/b": entry(NESTED_BLOB) }, w: { a: mod(BLOB) } },
    delta: { a: null, [A_COPY]: entry(BLOB) }, ops: ["a/b", A_COPY], conflicts: ["a"],
  },
  {
    why: "no collision: a path that only shares a name prefix stays",
    input: { lMap: { "ab/c": entry(NESTED_BLOB) }, rDiff: { a: added(BLOB) } },
    delta: { a: entry(BLOB) }, ops: ["a"], conflicts: [],
  },
  {
    why: "no collision: the remote swapped a/b for a, so the directory is gone",
    input: { lMap: { "a/b": entry(NESTED_BLOB) }, rDiff: { "a/b": removed(NESTED_BLOB), a: added(BLOB) } },
    delta: { "a/b": null, a: entry(BLOB) }, ops: ["a"], conflicts: [],
  },
];

function classifyPostPass(F) {
  for (const row of COLLISION_ROWS) {
    test(`classify: ${row.why}`, () => {
      const { out, stats } = runClassify(F, row.input);
      assert.deepStrictEqual(Object.fromEntries(out.delta), row.delta);
      assert.deepStrictEqual(out.ops.map((op) => op.rel).sort(), [...row.ops].sort());
      assert.deepStrictEqual(stats.conflicts.map((c) => c.path), row.conflicts);
      if (row.copies) assert.deepStrictEqual(stats.conflicts.map((c) => c.copy), row.copies);
    });
  }
  for (const special of [".gitignore", ".gitattributes", ".history.jsonl"]) {
    test(`classify: the special path ${special} is not moved`, () => {
      const nested = `${special}/x`;
      const { out, stats } = runClassify(F, { lMap: { [special]: entry(BLOB) }, w: { [nested]: mod(OTHER) } });
      assert.deepStrictEqual(Object.fromEntries(out.delta), { [nested]: entry(OTHER) });
      assert.deepStrictEqual(out.ops, []);
      assert.deepStrictEqual(stats.conflicts, []);
    });
  }
  test("classify: a multi-level chain resolves in one pass to a/b/c and two copies", () => {
    const one = "1".repeat(40);
    const two = "2".repeat(40);
    const three = "3".repeat(40);
    const { out, stats } = runClassify(F, {
      mode: "reset", lMap: { a: entry(one), "a/b": entry(two) }, rMap: { "a/b/c": entry(three) },
    });
    const left = new Set(["a/b/c"]);
    for (const [rel, e] of out.delta) {
      if (e) left.add(rel);
      else left.delete(rel);
    }
    const copies = [`a.sync-conflict-${one.slice(0, 12)}`, `a/b.sync-conflict-${two.slice(0, 12)}`];
    assert.deepStrictEqual([...left].sort(), [...copies, "a/b/c"].sort());
    assert.strictEqual(out.delta.get(copies[0]).blob, one);
    assert.strictEqual(out.delta.get(copies[1]).blob, two);
    assert.deepStrictEqual(stats.conflicts.map((c) => c.copy).sort(), [...copies].sort());
    const ancestors = new Set([...left].flatMap((rel) => rel.split("/").slice(0, -1).map((_, i, all) => all.slice(0, i + 1).join("/"))));
    assert.deepStrictEqual([...left].filter((rel) => ancestors.has(rel)), [], "no path is both a file and an ancestor");
  });
}

module.exports = { collisionCopyNameTable, pathBlockedTable, applyOpsGuard, classifyPostPass };
