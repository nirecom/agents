"use strict";
// Push-retry parts of the #2658 session-sync engine suite: what a non-fast-forward retry, a push
// that runs out of retries, and a push that fails for another reason leave in the reported conflict
// stats. Moved out of feature-2658-session-sync-engine-integrate-5.js to keep each entrypoint under
// the runner timeout. Holds no case markers; each export registers the tests of one case.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const lines = (...ls) => ls.join("\n") + "\n";
const A1 = jline("a1");
const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
const fwd = (p) => p.replace(/\\/g, "/");
const TAG = ".sync-conflict-";
const copiesOnDisk = (m) => fs.readdirSync(path.join(m.projects, "p1")).filter((n) => n.includes(TAG));

// rejectFirst(F, w, n) -> counter file: the remote refuses the first n pushes as a non-fast-forward
// and accepts the rest. Every refusal counts as one engine attempt.
function rejectFirst(F, w, n) {
  const hooks = path.join(w.root, "remote-hooks");
  const counter = path.join(w.root, "pre-receive-count");
  F.write(path.join(hooks, "pre-receive"), `#!/bin/sh\nn=$(cat '${fwd(counter)}' 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > '${fwd(counter)}'\n[ "$n" -gt ${n} ] && exit 0\necho "rejected: non-fast-forward (simulated race)" >&2\nexit 1\n`);
  fs.chmodSync(path.join(hooks, "pre-receive"), 0o755);
  F.git(w.remote, ["config", "core.hooksPath", fwd(hooks)]);
  return counter;
}

// conflictWorld(F) — B has pushed one version of a uuid and A's working tree holds another, plus one
// stray merge marker, so every classification of A's push counts one conflict and one dropped marker.
function conflictWorld(F) {
  const rel = "p1/k.jsonl";
  const w = F.world({ seed: { [rel]: lines(A1) } });
  const local = jline("k-conflict", { message: "from A" });
  const remote = jline("k-conflict", { message: "from B" });
  fs.appendFileSync(path.join(w.b.projects, "p1", "k.jsonl"), remote + "\n");
  okRun(F.engine(w.b, "push"), "B push");
  fs.appendFileSync(path.join(w.a.projects, "p1", "k.jsonl"), `<<<<<<< HEAD\n${local}\n`);
  const u = F.lib("jsonl").union(lines(A1, local), lines(A1, remote));
  const losers = [...u.lostLocal, ...u.lostRemote];
  assert.strictEqual(losers.length, 1, "the fixture must hold exactly one losing line");
  return { w, rel, loser: losers[0], tip: F.git(w.remote, ["rev-parse", "main"]) };
}

function assertNothingReported(F, w, stage) {
  const st = F.readState(w.a);
  assert.deepStrictEqual(st.conflicts, [], `${stage}: no copy was written, so none may be reported`);
  assert.strictEqual(st.uuidMismatch, 0, stage);
  assert.strictEqual(st.droppedMarkerLines, 0, stage);
  assert.deepStrictEqual(copiesOnDisk(w.a), [], stage);
}

// A's copy is reported once, exists in W and on the remote, and holds the losing line.
function assertReportedOnce(F, w, rel, loser) {
  const st = F.readState(w.a);
  assert.strictEqual(st.conflicts.length, 1, JSON.stringify(st.conflicts));
  const { path: reported, copy } = st.conflicts[0];
  assert.strictEqual(reported, rel);
  assert.deepStrictEqual(copiesOnDisk(w.a), [path.posix.basename(copy)], "the reported copy is the only one on disk");
  assert.strictEqual(fs.readFileSync(path.join(w.a.projects, ...copy.split("/")), "utf8"), lines(loser));
  assert.strictEqual(F.show(w.remote, "main", copy), lines(loser));
  const remoteCopies = F.git(w.remote, ["ls-tree", "--name-only", "main", "p1/"]).split("\n").filter((n) => n.includes(TAG));
  assert.deepStrictEqual(remoteCopies, [copy], "no earlier attempt's copy reached the remote");
  assert.strictEqual(st.uuidMismatch, 1, "one conflict, not one per attempt");
  assert.strictEqual(st.droppedMarkerLines, 1, "one marker line, not one per attempt");
}

function reportsOnce(F) {
  test("a same-uuid conflict across non-fast-forward retries is reported once and its copy exists", () => {
    const { w, rel, loser } = conflictWorld(F);
    const counter = rejectFirst(F, w, 2);
    okRun(F.engine(w.a, "push"), "A push with two rejections");
    assert.strictEqual(fs.readFileSync(counter, "utf8").trim(), "3", "the retries must really run");
    assert.strictEqual(F.readState(w.a).last.attempts, 3);
    assertReportedOnce(F, w, rel, loser);
  });
}

function failedPush(F) {
  test("a push that runs out of retries reports no conflict, and the run that lands reports it once", () => {
    const { w, rel, loser, tip } = conflictWorld(F);
    const counter = rejectFirst(F, w, 3);
    const r = F.engine(w.a, "push");
    assert.strictEqual(r.code, 1, `exhausted retries must fail: ${r.stdout}${r.stderr}`);
    assert.strictEqual(fs.readFileSync(counter, "utf8").trim(), "3");
    const { last } = F.readState(w.a);
    assert.strictEqual(last.result, "failed");
    assert.strictEqual(last.attempts, 3);
    assert.strictEqual(F.git(w.remote, ["rev-parse", "main"]), tip, "the remote is untouched");
    assertNothingReported(F, w, "after the failed run");

    okRun(F.engine(w.a, "push"), "A push once the remote accepts");
    assertReportedOnce(F, w, rel, loser);
  });
  // A pre-receive refusal always prints "[remote rejected]", which isNonFastForward matches, so only
  // a push that never reaches the remote can take the no-retry path. Fetch keeps using the real url.
  test("a push that fails for another reason is not retried and reports no conflict", () => {
    const { w, tip } = conflictWorld(F);
    F.git(w.a.projects, ["config", "remote.origin.pushurl", fwd(path.join(w.root, "no-such-remote"))]);
    F.engine(w.a, "push");
    const { last } = F.readState(w.a);
    assert.strictEqual(last.result, "offline", last.error);
    assert.strictEqual(last.attempts, 1, "only a non-fast-forward is retried");
    assert.strictEqual(F.git(w.remote, ["rev-parse", "main"]), tip, "the remote is untouched");
    assertNothingReported(F, w, "after the failed run");
  });
  test("a failed push keeps the conflict self-heal reported before the loop, whose copy is on disk", () => {
    const seed = { "p1/note.md": "base\n" };
    const w = F.world({ seed });
    const A = w.a.projects;
    F.write(path.join(w.b.projects, "p1", "note.md"), "from B\n");
    okRun(F.engine(w.b, "push"), "B push");
    F.write(path.join(A, "p1", "note.md"), "from A\n");
    F.git(A, ["commit", "-q", "-am", "A local"]);
    F.git(A, ["fetch", "-q", "origin"]);
    assert.notStrictEqual(F.git(A, ["rebase", "origin/main"], { allowFail: true }).status, 0, "the rebase must stop");
    rejectFirst(F, w, 3);
    assert.strictEqual(F.engine(w.a, "push").code, 1, "the push must fail");
    const st = F.readState(w.a);
    assert.strictEqual(st.conflicts.length, 1, JSON.stringify(st.conflicts));
    assert.strictEqual(st.conflicts[0].path, "p1/note.md");
    const copy = path.join(A, ...st.conflicts[0].copy.split("/"));
    assert.ok(fs.existsSync(copy), `${copy} must exist`);
    assert.ok(fs.readFileSync(copy, "utf8").includes("from A"), "the copy keeps A's side");
  });
}

module.exports = { reportsOnce, failedPush };
