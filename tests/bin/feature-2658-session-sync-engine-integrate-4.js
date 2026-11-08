"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, scope:issue-specific, jsonl-union, conflict-sibling
// #2658: fifth part of the session-sync engine suite (split from feature-2658-session-sync-engine.js
// so each entrypoint stays well under the per-file runner timeout). Covers the integrate-basic push
// cases: fast-forward pushes with retry (pull cases live in feature-2658-session-sync-engine-integrate-5.js),
// and the conflict sibling keeping the lines a both-changed transcript union drops from either side.
// The two-clone conflict-sibling cases moved to feature-2658-session-sync-engine-integrate-8.js by runtime.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures, jline } = require("./feature-2658-session-sync-engine/fixtures");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-4-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const basic = require("./feature-2658-session-sync-engine/integrate-basic");

const lines = (...ls) => ls.join("\n") + "\n";
const U = (...args) => F.lib("jsonl").union(...args);
const A1 = jline("a1");
const B1 = jline("b1");
const C1 = jline("c1");
const S1 = '{"type":"summary","summary":"one"}';
const S2 = '{"type":"summary","summary":"two"}';
const NOW = new Date("2026-01-02T03:04:05.678Z");
const STAMP = "20260102T030405Z";
const TAG = ".sync-conflict-";

// top / mid / low: three lines of one uuid ordered by the winner union itself picks, so no case
// pins the exact winner rule.
const [top, mid, low] = ["alpha", "middle", "omega"]
  .map((message) => jline("k-conflict", { message }))
  .sort((a, b) => (U(lines(a), lines(b)).text === lines(a) ? -1 : 1));

// classifyRun(paths, opts) runs classify on a real object store. Each path: {rel, work, head, remote}:
// work = W text, head = the text L records (default [A1]), remote = R text (null: unchanged on R),
// clean = W is unchanged since L. opts.reset takes the reset rule; opts.before(dir) seeds the tree.
function classifyRun(paths, { reset = false, before, lExtra = [], remoteOnly = null } = {}) {
  const G = F.lib("git");
  const dir = fs.mkdtempSync(path.join(F.TMP, "sibling-"));
  F.git(dir, ["init", "-q"]);
  if (before) before(dir);
  const blob = (t) => G.hashText(dir, t);
  const base = {
    mode: reset ? "reset" : "sync", dir, host: "h", now: NOW, R: null,
    lMap: new Map(lExtra.map((r) => [r, { mode: "100644", blob: blob("") }])),
    w: new Map(), rDiff: new Map(), lDiff: new Map(), rMap: new Map(),
    stats: { uuidMismatch: 0, droppedMarkerLines: 0, conflicts: [] },
  };
  for (const { rel, work, head = lines(A1), remote = null, clean = false } of paths) {
    const abs = path.join(dir, ...rel.split("/"));
    F.write(abs, work);
    base.lMap.set(rel, { mode: "100644", blob: blob(head) });
    if (!clean) base.w.set(rel, { kind: "mod", blob: blob(work), mode: "100644", sig: F.lib("apply").statSig(abs) });
    if (remote !== null) {
      base.rDiff.set(rel, { mode: "100644", newBlob: blob(remote) });
      base.rMap.set(rel, { mode: "100644", blob: blob(remote) });
    }
  }
  if (remoteOnly && reset) base.rMap.set(remoteOnly.rel, { mode: "100644", blob: blob(remoteOnly.text) });
  else if (remoteOnly) base.rDiff.set(remoteOnly.rel, { mode: "100644", newBlob: blob(remoteOnly.text) });
  const { out } = F.lib("classify").classify(base);
  const blobText = (id) => G.catBlob(dir, id).toString("utf8");
  const siblings = [...out.delta.keys()].filter((r) => r.includes(TAG));
  return { out, stats: base.stats, blobText, siblings, deltaText: (rel) => blobText(out.delta.get(rel).blob) };
}

// finalW(r, rel, work) -> the W text after the queued ops of rel run in order.
function finalW(r, rel, work) {
  let text = work;
  for (const op of r.out.ops.filter((o) => o.rel === rel)) {
    if (op.kind === "append") text += op.text;
    else text = op.kind === "text" ? op.text : r.blobText(op.blob);
  }
  return text;
}

function assertNoSibling(r) {
  assert.deepStrictEqual(r.siblings, [], "no conflict copy in M");
  assert.deepStrictEqual(r.out.ops.filter((o) => o.rel.includes(TAG)), [], "no conflict copy in W");
  assert.deepStrictEqual(r.stats.conflicts, [], "no conflict recorded");
}

const REL = "p1/t.jsonl";
const COPY = `p1/t.sync-conflict-h-${STAMP}.jsonl`;

caseBegin("integrate-fast-forward-push-and-retry", "bin/lib/session-sync/integrate.js");
basic.pushes(F);
caseEnd();

caseBegin("union-lost-local-losing-line", "bin/lib/session-sync/jsonl.js");
test("lostLocal holds the local line a remote line beat on the same uuid", () => {
  const r = U(lines(A1, low), lines(A1, top, B1));
  assert.deepStrictEqual(r.lostLocal, [low]);
  assert.ok(!r.text.split("\n").includes(low), r.text);
});
caseEnd();

caseBegin("union-lost-local-empty", "bin/lib/session-sync/jsonl.js");
test("lostLocal is empty when the local line wins, without a conflict, and for dropped marker lines", () => {
  assert.deepStrictEqual(U(lines(A1, top), lines(A1, low, B1)).lostLocal, [], "local line wins");
  assert.deepStrictEqual(U(lines(A1, B1), lines(A1, C1)).lostLocal, [], "no conflict");
  assert.deepStrictEqual(U(lines(A1, low), lines(A1, top), { prefer: "local" }).lostLocal, [], "prefer local");
  assert.deepStrictEqual(U("", lines(A1)).lostLocal, [], "empty local");
  const marked = U(lines(A1, "<<<<<<< HEAD"), lines(A1, B1));
  assert.strictEqual(marked.droppedMarkerLines, 1, marked.text);
  assert.deepStrictEqual(marked.lostLocal, [], "a merge marker is no transcript line");
});
caseEnd();

caseBegin("union-lost-local-later-duplicates", "bin/lib/session-sync/jsonl.js");
test("lostLocal holds the later local duplicates of a uuid in local order", () => {
  assert.deepStrictEqual(U(lines(A1, top, low, mid), lines(A1)).lostLocal, [low, mid]);
  assert.deepStrictEqual(U(lines(A1, top, mid, low), lines(A1)).lostLocal, [mid, low]);
  assert.deepStrictEqual(U(lines(A1, low, mid), lines(A1), { prefer: "local" }).lostLocal, [mid], "prefer local keeps the first");
});
caseEnd();

caseBegin("union-lost-local-remote-superset-counts", "bin/lib/session-sync/jsonl.js");
test("a remote superset loses a non-uuid local line beyond its remote count only", () => {
  const over = U(lines(A1, S1, S1, S2), lines(A1, S1, S2, B1));
  assert.strictEqual(over.remoteSuperset, true);
  assert.deepStrictEqual(over.lostLocal, [S1], "the second S1 is beyond the remote count; S2 is within it");
  const within = U(lines(S1, S1), lines(S1, S1, B1));
  assert.strictEqual(within.remoteSuperset, true);
  assert.deepStrictEqual(within.lostLocal, []);
});
test("the same non-uuid duplicate stays in the text, so it is not lost, outside a remote superset", () => {
  const r = U(lines(S1, S1, C1), lines(S1));
  assert.strictEqual(r.remoteSuperset, false);
  assert.strictEqual(r.text, lines(S1, S1, C1));
  assert.deepStrictEqual(r.lostLocal, []);
});
caseEnd();

caseBegin("union-lost-local-deferred", "bin/lib/session-sync/jsonl.js");
test("a deferred union loses nothing", () => {
  const r = U(lines(A1) + low, lines(A1, top));
  assert.strictEqual(r.deferred, true);
  assert.deepStrictEqual(r.lostLocal, []);
});
caseEnd();

caseBegin("union-lost-remote", "bin/lib/session-sync/jsonl.js");
test("lostRemote holds the remote line a local line beat on the same uuid, in remote order", () => {
  const r = U(lines(A1, top), lines(A1, low, B1));
  assert.deepStrictEqual(r.lostRemote, [low]);
  assert.deepStrictEqual(r.lostLocal, []);
  assert.deepStrictEqual(U(lines(A1, top), lines(A1, low, mid)).lostRemote, [low, mid]);
  assert.deepStrictEqual(U(lines(A1, top), lines(A1, mid, low)).lostRemote, [mid, low]);
});
test("lostRemote is empty when the remote line wins and without a conflict", () => {
  assert.deepStrictEqual(U(lines(A1, low), lines(A1, top)).lostRemote, [], "remote line wins");
  assert.deepStrictEqual(U(lines(A1, top), lines(A1, low), { prefer: "remote" }).lostRemote, [], "prefer remote");
  assert.deepStrictEqual(U(lines(A1, B1), lines(A1, C1)).lostRemote, [], "no conflict");
});
test("prefer local puts the remote line in lostRemote even when it would win a plain union", () => {
  assert.deepStrictEqual(U(lines(A1, low), lines(A1, top), { prefer: "local" }).lostRemote, [top]);
});
test("a deferred union reports no lostRemote", () => {
  const r = U(lines(A1) + low, lines(A1, top));
  assert.strictEqual(r.deferred, true);
  assert.deepStrictEqual(r.lostRemote, []);
});
caseEnd();

caseBegin("classify-sibling-holds-lost-lines", "bin/lib/session-sync/classify.js");
test("both-changed with a lost line adds the conflict copy to M and W and records it", () => {
  const r = classifyRun([{ rel: REL, work: lines(A1, low), remote: lines(A1, top, B1) }]);
  assert.deepStrictEqual(r.siblings, [COPY]);
  const entry = r.out.delta.get(COPY);
  const ops = r.out.ops.filter((o) => o.rel === COPY);
  assert.strictEqual(ops.length, 1, JSON.stringify(ops));
  assert.strictEqual(ops[0].kind, "blob");
  assert.strictEqual(ops[0].blob, entry.blob, "M and W hold the same blob");
  assert.strictEqual(entry.mode, "100644");
  assert.strictEqual(r.blobText(entry.blob), lines(low), "exactly the lost lines with a trailing newline");
  assert.deepStrictEqual(r.stats.conflicts, [{ path: REL, copy: COPY, localMtime: null, remoteTime: null, lostLines: 1 }]);
});
test("several lost lines all reach one conflict copy in local order", () => {
  const r = classifyRun([{ rel: REL, work: lines(A1, top, mid, low), remote: lines(A1, B1) }]);
  assert.deepStrictEqual(r.siblings, [COPY]);
  assert.strictEqual(r.blobText(r.out.delta.get(COPY).blob), lines(mid, low));
  assert.strictEqual(r.stats.conflicts[0].lostLines, 2);
});
test("the reset rule keeps the lost line in a conflict copy too", () => {
  const r = classifyRun([{ rel: REL, work: lines(A1, low), remote: lines(A1, top) }], { reset: true });
  assert.deepStrictEqual(r.siblings, [COPY]);
  assert.strictEqual(r.blobText(r.out.delta.get(COPY).blob), lines(low));
});
caseEnd();

caseBegin("classify-subset-adopts-remote-order", "bin/lib/session-sync/classify.js");
test("the remote superset adopts the remote line order by a full rewrite and M equals W", () => {
  const work = lines(B1, A1);
  const remote = lines(A1, B1, C1);
  const r = classifyRun([{ rel: REL, work, remote }]);
  const ops = r.out.ops.filter((o) => o.rel === REL);
  assert.deepStrictEqual(ops.map((o) => [o.kind, o.text]), [["text", remote]]);
  assert.strictEqual(r.deltaText(REL), remote);
  assert.strictEqual(finalW(r, REL, work), r.deltaText(REL));
  assertNoSibling(r);
});
caseEnd();

caseBegin("classify-local-unchanged-w-equals-m", "bin/lib/session-sync/classify.js");
test("W equals M on the local-unchanged branch, by a rewrite and by an append", () => {
  const rewrite = lines(A1, top);
  const r = classifyRun([{ rel: REL, work: rewrite, head: rewrite, clean: true, remote: lines(A1, low, B1) }]);
  const op = r.out.ops.find((o) => o.rel === REL);
  assert.strictEqual(op.kind, "text");
  assert.strictEqual(op.text, r.deltaText(REL), "the op text is the blob M records");
  const append = lines(A1, C1);
  const a = classifyRun([{ rel: REL, work: append, head: append, clean: true, remote: lines(A1, B1) }]);
  assert.strictEqual(a.out.ops.find((o) => o.rel === REL).kind, "append");
  assert.strictEqual(finalW(a, REL, append), a.deltaText(REL));
});
caseEnd();

caseBegin("classify-deferred-no-sibling", "bin/lib/session-sync/classify.js");
test("a local transcript without a trailing newline defers the union and makes no conflict copy", () => {
  const remote = lines(A1, top);
  const r = classifyRun([{ rel: REL, work: lines(A1) + low, remote }]);
  assertNoSibling(r);
  assert.deepStrictEqual(r.out.ops, [], "W stays untouched while deferred");
  assert.strictEqual(r.deltaText(REL), remote, "M takes the remote transcript");
});
caseEnd();

caseBegin("classify-sibling-name-collision", "bin/lib/session-sync/classify.js");
const COPY2 = `p1/t.sync-conflict-h-${STAMP}-2.jsonl`;
const conflict = [{ rel: REL, work: lines(A1, low), remote: lines(A1, top) }];
test("a conflict copy name already on disk moves the copy to -2", () => {
  const seedCopy = (dir) => F.write(path.join(dir, ...COPY.split("/")), "taken\n");
  assert.deepStrictEqual(classifyRun(conflict, { before: seedCopy }).siblings, [COPY2]);
});
test("a conflict copy name already in L moves the copy to -2", () => {
  const r = classifyRun(conflict, { lExtra: [COPY] });
  assert.deepStrictEqual(r.siblings, [COPY2]);
  assert.strictEqual(r.blobText(r.out.delta.get(COPY2).blob), lines(low));
});
test("a conflict copy name only the remote holds moves the copy to -2 and M keeps the remote sibling (sync)", () => {
  const r = classifyRun(conflict, { remoteOnly: { rel: COPY, text: "remote sibling\n" } });
  assert.deepStrictEqual(r.siblings.sort(), [COPY2, COPY].sort());
  assert.strictEqual(r.blobText(r.out.delta.get(COPY).blob), "remote sibling\n", "M keeps the remote entry");
  assert.strictEqual(r.blobText(r.out.delta.get(COPY2).blob), lines(low));
  assert.strictEqual(r.blobText(r.out.ops.find((o) => o.rel === COPY).blob), "remote sibling\n", "W takes the remote sibling");
});
test("a conflict copy name only the remote tree holds moves the copy to -2 and M keeps the remote sibling (reset)", () => {
  const r = classifyRun(conflict, { reset: true, remoteOnly: { rel: COPY, text: "remote sibling\n" } });
  assert.deepStrictEqual(r.siblings, [COPY2]);
  assert.strictEqual(r.out.delta.has(COPY), false, "M starts from the remote tree, so its sibling stays untouched");
  assert.strictEqual(r.blobText(r.out.delta.get(COPY2).blob), lines(low));
  assert.strictEqual(r.blobText(r.out.ops.find((o) => o.rel === COPY).blob), "remote sibling\n", "W takes the remote sibling");
});
caseEnd();

caseBegin("classify-two-paths-own-siblings", "bin/lib/session-sync/classify.js");
test("two lost-line paths in one run each get their own conflict copy", () => {
  const other = "p2/u.jsonl";
  const otherCopy = `p2/u.sync-conflict-h-${STAMP}.jsonl`;
  const r = classifyRun([
    { rel: REL, work: lines(A1, low), remote: lines(A1, top) },
    { rel: other, work: lines(A1, mid), remote: lines(A1, top) },
  ]);
  assert.deepStrictEqual(r.siblings.sort(), [COPY, otherCopy]);
  assert.strictEqual(r.blobText(r.out.delta.get(COPY).blob), lines(low));
  assert.strictEqual(r.blobText(r.out.delta.get(otherCopy).blob), lines(mid));
  assert.deepStrictEqual(r.stats.conflicts.map((c) => [c.path, c.copy]).sort(), [[REL, COPY], [other, otherCopy]]);
});
caseEnd();

caseBegin("classify-one-side-changed-no-sibling", "bin/lib/session-sync/classify.js");
test("remote unchanged (prefer local): a same-uuid difference makes no conflict copy", () => {
  const work = lines(A1, low);
  const r = classifyRun([{ rel: REL, work, head: lines(A1, top) }]);
  assertNoSibling(r);
  assert.strictEqual(r.deltaText(REL), work, "the local line is the newer edit");
});
test("local unchanged (prefer remote): the replaced local line makes no conflict copy", () => {
  const work = lines(A1, top);
  const remote = lines(A1, low);
  const r = classifyRun([{ rel: REL, work, head: work, clean: true, remote }]);
  assertNoSibling(r);
  assert.strictEqual(finalW(r, REL, work), remote, "the local line is replaced even though it would win a both-changed union");
});
caseEnd();

caseBegin("classify-sibling-holds-remote-loser", "bin/lib/session-sync/classify.js");
test("both changed with the local line the winner: the remote losing line goes to a conflict copy in M and W", () => {
  const r = classifyRun([{ rel: REL, work: lines(A1, top), remote: lines(A1, low, B1) }]);
  assert.strictEqual(r.deltaText(REL), lines(A1, top, B1));
  assert.deepStrictEqual(r.siblings, [COPY]);
  const entry = r.out.delta.get(COPY);
  assert.strictEqual(r.blobText(entry.blob), lines(low));
  const ops = r.out.ops.filter((o) => o.rel === COPY);
  assert.deepStrictEqual(ops.map((o) => [o.kind, o.blob]), [["blob", entry.blob]], "M and W hold the same blob");
  assert.deepStrictEqual(r.stats.conflicts, [{ path: REL, copy: COPY, localMtime: null, remoteTime: null, lostLines: 1 }]);
});
test("a losing line both sides hold enters the conflict copy once", () => {
  const r = classifyRun([{ rel: REL, work: lines(A1, top, low), remote: lines(A1, low, B1) }]);
  assert.deepStrictEqual(r.siblings, [COPY]);
  assert.strictEqual(r.blobText(r.out.delta.get(COPY).blob), lines(low));
  assert.strictEqual(r.stats.conflicts[0].lostLines, 1);
});
test("different losing lines of the two sides all enter one conflict copy, the local one first", () => {
  const r = classifyRun([{ rel: REL, work: lines(A1, top, mid), remote: lines(A1, low) }]);
  assert.deepStrictEqual(r.siblings, [COPY]);
  assert.strictEqual(r.blobText(r.out.delta.get(COPY).blob), lines(mid, low));
  assert.strictEqual(r.stats.conflicts[0].lostLines, 2);
});
caseEnd();

caseBegin("union-lost-local-excludes-kept-line", "bin/lib/session-sync/jsonl.js");
test("lostLocal never lists a line the output text holds: a later duplicate that is the kept line", () => {
  const r = U(lines(A1, low, top), lines(A1));
  assert.ok(r.text.split("\n").includes(top), r.text);
  assert.deepStrictEqual(r.lostLocal, [low], "top is in the text, so only low is lost");
});
caseEnd();
