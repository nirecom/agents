"use strict";
// Tests: hooks/lib/test-gates/git-blobs.js
// Tags: TL2, hooks, test-gates, git-blobs, cat-file, real-git, fail-closed, table-driven, scope:issue-specific
// blobs(cwd, env, names) cases of tests/hooks/feature-2507-git-blobs-fail-closed.js (#2507). Holds no
// case markers. Sanctioned replies (missing, tree, newline names) stay quiet; every reply that
// leaves a gap must throw, so a gate never reads "blob absent" where git failed.
const assert = require("node:assert");
const { test } = require("node:test");
const { withCatFile, parseBatch, buildBatch, spawnError, str } = require("./fixture");

const NUL = Buffer.from([0x6e, 0x0a, 0x00, 0x0a, 0x31]);

function readsBlobs(F) {
  test("staged and HEAD blobs, an empty and a NUL-bearing blob, a duplicate name", () => {
    const dir = F.repo("gb-normal", { "a.txt": "head a\n" }, { "a.txt": "staged a\n", "empty.txt": "", "zero.dat": NUL });
    const names = [":a.txt", "HEAD:a.txt", ":empty.txt", ":zero.dat", ":a.txt"];
    const { value: got, calls } = withCatFile((r) => r, () => F.blobs(dir, names));
    assert.deepStrictEqual([...got.keys()].sort(), [":a.txt", ":empty.txt", ":zero.dat", "HEAD:a.txt"]);
    assert.strictEqual(str(got.get(":a.txt")), "staged a\n");
    assert.strictEqual(str(got.get("HEAD:a.txt")), "head a\n");
    assert.strictEqual(got.get(":empty.txt").length, 0, "an empty blob is present, not absent");
    assert.ok(Buffer.from(got.get(":zero.dat")).equals(NUL), "NUL and LF bytes survive");
    assert.strictEqual(calls.length, 1, "one cat-file --batch for every name");
    assert.strictEqual(calls[0].input, ":a.txt\nHEAD:a.txt\n:empty.txt\n:zero.dat\n", "a duplicate name is asked once");
  });
  test("a name holding a newline is never asked and is left out", () => {
    const dir = F.repo("gb-newline", { "a.txt": "head a\n" });
    const names = [":a.txt", ":x\nHEAD:a.txt"];
    const { value: got, calls } = withCatFile((r) => r, () => F.blobs(dir, names));
    assert.deepStrictEqual([...got.keys()], [":a.txt"]);
    assert.strictEqual(calls[0].input, ":a.txt\n", "the newline name must not reach cat-file as two names");
    const none = withCatFile((r) => r, () => F.blobs(dir, ["HEAD:y\n:a.txt"]));
    assert.strictEqual(none.value.size, 0);
    assert.strictEqual(none.calls.length, 0, "only newline names: git is not started");
  });
  test("no names: an empty Map and no git", () => {
    const dir = F.repo("gb-empty");
    const { value: got, calls } = withCatFile((r) => r, () => F.blobs(dir, []));
    assert.strictEqual(got.size, 0);
    assert.strictEqual(calls.length, 0);
  });
}

function missingAndTree(F) {
  test("a missing name (a new file HEAD lacks) is left out without throwing; later names still read", () => {
    const dir = F.repo("gb-missing", { "a.txt": "head a\n" }, { "new.txt": "new\n", "sp ace.txt": "space\n" });
    const names = ["HEAD:new.txt", ":new.txt", ":nope.txt", "HEAD:sp ace.txt", ":sp ace.txt", "HEAD:a.txt"];
    const got = F.blobs(dir, names);
    assert.deepStrictEqual([...got.keys()].sort(), [":new.txt", ":sp ace.txt", "HEAD:a.txt"]);
    assert.strictEqual(str(got.get(":new.txt")), "new\n");
    assert.strictEqual(str(got.get(":sp ace.txt")), "space\n", "a missing name holding a space is still a missing reply");
    assert.strictEqual(str(got.get("HEAD:a.txt")), "head a\n");
  });
  test("a tree reply is skipped and the names after it still read", () => {
    const dir = F.repo("gb-tree", { "dir/in.txt": "in\n", "a.txt": "head a\n" }, { "a.txt": "staged a\n" });
    const names = ["HEAD:", "HEAD:dir", ":a.txt", "HEAD:dir/in.txt", "HEAD:a.txt"];
    const got = F.blobs(dir, names);
    assert.deepStrictEqual([...got.keys()].sort(), [":a.txt", "HEAD:a.txt", "HEAD:dir/in.txt"]);
    assert.strictEqual(str(got.get(":a.txt")), "staged a\n");
    assert.strictEqual(str(got.get("HEAD:dir/in.txt")), "in\n");
    assert.strictEqual(str(got.get("HEAD:a.txt")), "head a\n");
  });
}

// Each row edits the reply of [":a.txt", ":b.txt"] (bodies without a trailing LF, so a size off by
// one lands on a body byte or the next header, never on a terminator).
const reply = (fn) => (r) => ({ ...r, stdout: fn(parseBatch(r.stdout), r.stdout) });
const hdr = (o, fn) => ({ ...o, header: fn(o.header.split(" ")) });
const ROWS = [
  ["spawn error ENOENT (no stdout)", () => spawnError("ENOENT")],
  ["spawn error ETIMEDOUT with the whole reply", (r) => spawnError("ETIMEDOUT", r.stdout)],
  ["spawn error ENOBUFS with status 0 and the whole reply", (r) => ({ ...r, error: spawnError("ENOBUFS").error })],
  ["spawn error ENOBUFS with a partial reply", (r) => spawnError("ENOBUFS", r.stdout.subarray(0, 20))],
  ["non-zero exit with the whole reply", (r) => ({ ...r, status: 128 })],
  ["killed by a signal (status null, no error)", (r) => ({ ...r, status: null, signal: "SIGKILL" })],
  ["empty stdout, exit 0", (r) => ({ ...r, stdout: Buffer.alloc(0) })],
  ["cut after the first reply", reply((o) => buildBatch(o.slice(0, 1)))],
  ["cut inside the second header", reply((o) => Buffer.concat([buildBatch(o.slice(0, 1)), Buffer.from(o[1].header.slice(0, 10))]))],
  ["4-field header", reply((o) => buildBatch([hdr(o[0], (h) => `${h.join(" ")} extra`), o[1]]))],
  ["2-field header that is not missing", reply((o) => buildBatch([hdr(o[0], (h) => `${h[0]} ${h[1]}`), o[1]]))],
  ["1-field header", reply((o) => buildBatch([hdr(o[0], (h) => h[0]), o[1]]))],
  ["negative size", reply((o) => buildBatch([hdr(o[0], (h) => `${h[0]} ${h[1]} -1`), o[1]]))],
  ["non-numeric size", reply((o) => buildBatch([hdr(o[0], (h) => `${h[0]} ${h[1]} five`), o[1]]))],
  ["size one too large", reply((o) => buildBatch([hdr(o[0], (h) => `${h[0]} ${h[1]} ${Number(h[2]) + 1}`), o[1]]))],
  ["size one too small", reply((o) => buildBatch([hdr(o[0], (h) => `${h[0]} ${h[1]} ${Number(h[2]) - 1}`), o[1]]))],
  ["last body shorter than its size", reply((o) => buildBatch([o[0], hdr(o[1], (h) => `${h[0]} ${h[1]} ${Number(h[2]) + 10}`)]).subarray(0, -1))],
  ["no LF after the last body", reply((o) => buildBatch([o[0], { ...o[1], end: "" }]))],
  ["no LF after the first body", reply((o) => buildBatch([{ ...o[0], end: "" }, o[1]]))],
];

function failsClosed(F) {
  const dir = F.repo("gb-closed", {}, { "a.txt": "alpha", "b.txt": "bravo" });
  const names = [":a.txt", ":b.txt"];
  test("control: the parsed-and-rebuilt reply reads both blobs, so a throwing row is the row", () => {
    const { value: got } = withCatFile(reply((o) => buildBatch(o)), () => F.blobs(dir, names));
    assert.strictEqual(str(got.get(":a.txt")), "alpha");
    assert.strictEqual(str(got.get(":b.txt")), "bravo");
  });
  for (const [label, edit] of ROWS) {
    test(`blobs() throws: ${label}`, () => {
      let got;
      try {
        got = withCatFile(edit, () => F.blobs(dir, names)).value;
      } catch (e) {
        if (e && e.fromEdit) throw e;
        return;
      }
      assert.fail(`${label}: blobs() returned ${JSON.stringify([...got.keys()])} instead of throwing`);
    });
  }
}

module.exports = { readsBlobs, missingAndTree, failsClosed, ROWS };
