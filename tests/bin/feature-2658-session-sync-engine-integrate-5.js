"use strict";
// Tests: bin/session-sync-engine, bin/lib/session-sync/cli.js, bin/lib/session-sync/git.js, bin/lib/session-sync/proc.js, bin/lib/session-sync/lock.js, bin/lib/session-sync/selfheal.js, bin/lib/session-sync/classify.js, bin/lib/session-sync/jsonl.js, bin/lib/session-sync/history.js, bin/lib/session-sync/conflict.js, bin/lib/session-sync/exclude.js, bin/lib/session-sync/mtime.js, bin/lib/session-sync/apply.js, bin/lib/session-sync/state.js, bin/lib/session-sync/integrate.js
// Tags: TL1, TL2, session-sync, session-sync-engine, real-git, two-clone, scope:issue-specific, write-deferred, push-retry
// #2658: sixth part of the session-sync engine suite (split from feature-2658-session-sync-engine-integrate-4.js
// so each entrypoint stays well under the per-file runner timeout). Covers the integrate-basic pull
// cases: pull with no deletion propagation, the write deferred when its target changed after
// classification. What a rejected or failed push leaves in the reported conflict stats moved to
// feature-2658-session-sync-engine-integrate-9.js by runtime.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { makeFixtures, jline } = require("./feature-2658-session-sync-engine/fixtures");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2658-session-sync-engine-integrate-5-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
});
const F = makeFixtures(TMP);

const basic = require("./feature-2658-session-sync-engine/integrate-basic");

const lines = (...ls) => ls.join("\n") + "\n";
const A1 = jline("a1");
const B1 = jline("b1");
const C1 = jline("c1");
const HALF = C1.slice(0, 10);
const REST = C1.slice(10) + "\n";
const newStats = () => ({ writeDeferred: { count: 0, path: null }, mtimeRejected: { count: 0, path: null } });
const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);

// target(text) -> {dir, abs, rel, pre}: a real file whose statSig is taken as classification would.
function target(text) {
  const dir = fs.mkdtempSync(path.join(F.TMP, "apply-"));
  const rel = "p1/t.jsonl";
  const abs = path.join(dir, "p1", "t.jsonl");
  F.write(abs, text);
  return { dir, abs, rel, pre: F.lib("apply").statSig(abs) };
}

caseBegin("integrate-pull-and-no-deletion-propagation", "bin/lib/session-sync/classify.js");
basic.pull(F);
caseEnd();

caseBegin("apply-append-deferred-when-target-changed", "bin/lib/session-sync/apply.js");
test("an append op whose target changed after classification writes nothing and is recorded", () => {
  const t = target(lines(A1));
  fs.appendFileSync(t.abs, HALF);
  const stats = newStats();
  const n = F.lib("apply").applyOps(t.dir, [{ rel: t.rel, kind: "append", text: lines(B1), pre: t.pre }], null, stats);
  assert.strictEqual(n, 0);
  assert.strictEqual(fs.readFileSync(t.abs, "utf8"), lines(A1) + HALF, "the line being written must not join the remote line");
  assert.deepStrictEqual(stats.writeDeferred, { count: 1, path: t.rel });
});
test("whole-file ops whose target changed after classification are deferred the same way", () => {
  for (const op of [{ kind: "text", text: "new\n" }, { kind: "blob", blob: "id" }]) {
    const t = target(lines(A1));
    fs.appendFileSync(t.abs, lines(C1));
    const stats = newStats();
    const n = F.lib("apply").applyOps(t.dir, [Object.assign({ rel: t.rel, pre: t.pre }, op)], () => Buffer.from("new\n"), stats);
    assert.strictEqual(n, 0, op.kind);
    assert.strictEqual(fs.readFileSync(t.abs, "utf8"), lines(A1, C1), op.kind);
    assert.deepStrictEqual(stats.writeDeferred, { count: 1, path: t.rel }, op.kind);
  }
});
caseEnd();

caseBegin("apply-append-writes-when-target-unchanged", "bin/lib/session-sync/apply.js");
test("an append op whose target is unchanged appends as usual", () => {
  const t = target(lines(A1));
  const stats = newStats();
  const n = F.lib("apply").applyOps(t.dir, [{ rel: t.rel, kind: "append", text: lines(B1), pre: t.pre }], null, stats);
  assert.strictEqual(n, 1);
  assert.strictEqual(fs.readFileSync(t.abs, "utf8"), lines(A1, B1));
  assert.deepStrictEqual(stats.writeDeferred, { count: 0, path: null });
});
caseEnd();

caseBegin("apply-empty-append-is-noop", "bin/lib/session-sync/apply.js");
test("an append op with empty text does nothing and defers nothing, even on a changed target", () => {
  const t = target(lines(A1));
  fs.appendFileSync(t.abs, HALF);
  const stats = newStats();
  const n = F.lib("apply").applyOps(t.dir, [{ rel: t.rel, kind: "append", text: "", pre: t.pre }], null, stats);
  assert.strictEqual(n, 0);
  assert.strictEqual(fs.readFileSync(t.abs, "utf8"), lines(A1) + HALF);
  assert.deepStrictEqual(stats.writeDeferred, { count: 0, path: null });
});
caseEnd();

caseBegin("classify-sets-pre-on-append-op", "bin/lib/session-sync/classify.js");
test("classify gives an append op the target's sig, so a later change defers it", () => {
  const G = F.lib("git");
  const { statSig, applyOps } = F.lib("apply");
  for (const clean of [false, true]) {
    const work = lines(A1, C1);
    const t = target(work);
    F.git(t.dir, ["init", "-q"]);
    const blob = (text) => G.hashText(t.dir, text);
    const sig = statSig(t.abs);
    const w = clean ? [] : [[t.rel, { kind: "mod", blob: blob(work), mode: "100644", sig }]];
    const { out } = F.lib("classify").classify({
      mode: "sync", dir: t.dir, host: "h", now: new Date(), R: null,
      lMap: new Map([[t.rel, { mode: "100644", blob: blob(clean ? work : lines(A1)) }]]),
      w: new Map(w), rDiff: new Map([[t.rel, { mode: "100644", newBlob: blob(lines(A1, B1)) }]]),
      lDiff: new Map(), rMap: new Map(), stats: { uuidMismatch: 0, droppedMarkerLines: 0, conflicts: [] },
    });
    const op = out.ops.find((o) => o.rel === t.rel);
    assert.strictEqual(op.kind, "append", JSON.stringify(op));
    assert.deepStrictEqual(op.pre, sig, `clean=${clean}`);
    fs.appendFileSync(t.abs, HALF);
    const stats = newStats();
    assert.strictEqual(applyOps(t.dir, out.ops, null, stats), 0, `clean=${clean}`);
    assert.strictEqual(fs.readFileSync(t.abs, "utf8"), work + HALF);
    assert.deepStrictEqual(stats.writeDeferred, { count: 1, path: t.rel });
  }
});
caseEnd();

// raceEnv(file) -> engine env whose applyOps first appends HALF to file: the transcript's owner
// writing between classification and the working-tree write, a window no CLI input can reach.
function raceEnv(file) {
  const preload = path.join(F.TMP, "append-race-preload.js");
  fs.writeFileSync(preload, [
    `const a = require(${JSON.stringify(path.join(F.LIB, "apply.js"))});`,
    "const orig = a.applyOps;",
    `a.applyOps = (...args) => { require("node:fs").appendFileSync(${JSON.stringify(file)}, ${JSON.stringify(HALF)}); return orig(...args); };`,
    "",
  ].join("\n"));
  return { NODE_OPTIONS: `--require "${preload.replace(/\\/g, "/")}"` };
}

caseBegin("integrate-deferred-append-merges-next-run", "bin/lib/session-sync/integrate.js");
test("the deferred remote lines reach the transcript on a later run without joining the half-written line", () => {
  const rel = "p1/k.jsonl";
  const w = F.world({ seed: { [rel]: lines(A1) } });
  const fileOf = (m) => path.join(m.projects, "p1", "k.jsonl");
  fs.appendFileSync(fileOf(w.a), B1 + "\n");
  okRun(F.engine(w.a, "push"), "A push");

  okRun(F.engine(w.b, "pull", [], { env: raceEnv(fileOf(w.b)) }), "B pull racing the writer");
  assert.strictEqual(fs.readFileSync(fileOf(w.b), "utf8"), lines(A1) + HALF, "the remote line is held back");
  assert.deepStrictEqual(F.readState(w.b).writeDeferred, { count: 1, path: rel });

  okRun(F.engine(w.b, "pull"), "B pull while the line is still half-written");
  assert.strictEqual(fs.readFileSync(fileOf(w.b), "utf8"), lines(A1) + HALF, "a half-written line defers the union");

  fs.appendFileSync(fileOf(w.b), REST);
  okRun(F.engine(w.b, "pull"), "B pull after the line completed");
  const text = fs.readFileSync(fileOf(w.b), "utf8");
  const uuids = text.trimEnd().split("\n").map((l) => JSON.parse(l).uuid).sort();
  assert.deepStrictEqual(uuids, ["a1", "b1", "c1"], `every line stays one valid entry:\n${text}`);
  assert.strictEqual(F.show(w.b.projects, "main", rel), text, "M and W hold the same transcript");
  assert.deepStrictEqual(F.readState(w.b).writeDeferred, { count: 1, path: rel }, "the later runs defer nothing");

  okRun(F.engine(w.b, "push"), "B push");
  okRun(F.engine(w.a, "pull"), "A pull");
  assert.strictEqual(fs.readFileSync(fileOf(w.a), "utf8"), text, "both clones converge");
});
caseEnd();
