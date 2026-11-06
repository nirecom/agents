"use strict";
// Two-clone integration parts of tests/bin/feature-2658-session-sync-engine.js (#2658): fast-forward
// pushes, non-fast-forward retry, remote-only pull, no deletion propagation. Holds no case markers;
// every case drives the real engine CLI against a bare remote and two fixture machines.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
const fwd = (p) => p.replace(/\\/g, "/");

function pushes(F) {
  test("alternating pushes from two machines always fast-forward the remote (no merge, no rebase)", () => {
    const w = F.world();
    F.write(path.join(w.a.projects, "p1", "s1.jsonl"), jline("a1") + "\n");
    const ra = F.engine(w.a, "push");
    okRun(ra, "A push");
    assert.strictEqual(ra.stdout.trim(), "Pushed session data.");
    const tipA = F.git(w.remote, ["rev-parse", "main"]);

    F.write(path.join(w.b.projects, "p2", "s2.jsonl"), jline("b1") + "\n");
    const rb = F.engine(w.b, "push");
    okRun(rb, "B push");
    const tipB = F.git(w.remote, ["rev-parse", "main"]);
    assert.notStrictEqual(tipB, tipA);
    assert.strictEqual(F.git(w.remote, ["rev-list", "--parents", "-n", "1", tipB]).split(" ").slice(1).join(" "), tipA,
      "B's commit must have exactly A's tip as its parent");
    assert.strictEqual(F.git(w.remote, ["rev-list", "--merges", "main"]), "", "no merge commits");
    assert.ok(F.show(w.remote, "main", "p1/s1.jsonl") !== null && F.show(w.remote, "main", "p2/s2.jsonl") !== null);
    assert.ok(!fs.existsSync(path.join(w.b.projects, ".git", "rebase-merge")), "no rebase state is left behind");
    assert.strictEqual(F.git(w.b.projects, ["rev-parse", "main"]), tipB, "B's main is what it pushed");
    assert.match(F.git(w.remote, ["log", "-1", "--format=%s", tipB]), /^sync: [^.\s]+ \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/);
  });
  test("push retries after a non-fast-forward rejection and never forces", () => {
    const w = F.world();
    const hooks = path.join(w.root, "remote-hooks");
    const counter = path.join(w.root, "pre-receive-count");
    F.write(path.join(hooks, "pre-receive"), `#!/bin/sh\nn=$(cat '${fwd(counter)}' 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > '${fwd(counter)}'\n[ "$n" -ge 2 ] && exit 0\necho "rejected: non-fast-forward (simulated race)" >&2\nexit 1\n`);
    fs.chmodSync(path.join(hooks, "pre-receive"), 0o755);
    F.git(w.remote, ["config", "core.hooksPath", fwd(hooks)]);
    const before = F.git(w.remote, ["rev-parse", "main"]);
    F.write(path.join(w.a.projects, "p1", "retry.jsonl"), jline("r1") + "\n");
    const r = F.engine(w.a, "push");
    okRun(r, "A push with one rejection");
    assert.strictEqual(fs.readFileSync(counter, "utf8").trim(), "2", "the push must be attempted exactly twice");
    assert.ok(F.show(w.remote, "main", "p1/retry.jsonl") !== null, "the retried push must land");
    assert.strictEqual(F.git(w.remote, ["merge-base", "--is-ancestor", before, "main"], { allowFail: true }).status, 0, "no force push");
    assert.strictEqual(F.readState(w.a).last.attempts, 2);
  });
  // The race: B's commit is already in the remote's object store (refs/heads/staged); A's first
  // push makes pre-receive move main to it, so A's ref update loses a real compare-and-swap.
  test("a push that loses the race to another clone re-fetches, rebuilds on the new tip, and lands", () => {
    const w = F.world();
    F.write(path.join(w.b.projects, "p9", "race.jsonl"), jline("race-b") + "\n");
    F.git(w.b.projects, ["add", "-A"]);
    F.git(w.b.projects, ["commit", "-q", "-m", "B wins the race"]);
    F.git(w.b.projects, ["push", "-q", "origin", "HEAD:refs/heads/staged"]);
    const raced = F.git(w.remote, ["rev-parse", "refs/heads/staged"]);
    const hooks = path.join(w.root, "remote-hooks");
    const counter = path.join(w.root, "pre-receive-count");
    F.write(path.join(hooks, "pre-receive"), [
      "#!/bin/sh",
      `n=$(cat '${fwd(counter)}' 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > '${fwd(counter)}'`,
      '[ "$n" -ge 2 ] && exit 0',
      "unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES",
      `git update-ref refs/heads/main ${raced}`,
      "exit 0", ""].join("\n"));
    fs.chmodSync(path.join(hooks, "pre-receive"), 0o755);
    F.git(w.remote, ["config", "core.hooksPath", fwd(hooks)]);
    F.write(path.join(w.a.projects, "p1", "mine.jsonl"), jline("mine-a") + "\n");
    const r = F.engine(w.a, "push");
    okRun(r, "A push racing B");
    assert.strictEqual(fs.readFileSync(counter, "utf8").trim(), "2", "one lost race, one landed retry");
    assert.ok(F.show(w.remote, "main", "p9/race.jsonl") !== null, "B's commit must survive A's retry");
    assert.ok(F.show(w.remote, "main", "p1/mine.jsonl") !== null, "A's change must land on the new tip");
    assert.strictEqual(F.git(w.remote, ["rev-list", "--parents", "-n", "1", "main"]).split(" ").slice(1).join(" "), raced,
      "the retry must be rebuilt with the raced tip as its parent");
    assert.strictEqual(fs.readFileSync(path.join(w.a.projects, "p9", "race.jsonl"), "utf8"), jline("race-b") + "\n",
      "the rebuilt integration also writes the raced file into A's working tree");
    assert.strictEqual(F.readState(w.a).last.attempts, 2);
  });
  test("a push that loses every race gives up after three attempts without forcing", () => {
    const w = F.world();
    const hooks = path.join(w.root, "remote-hooks");
    const counter = path.join(w.root, "pre-receive-count");
    F.write(path.join(hooks, "pre-receive"), `#!/bin/sh\nn=$(cat '${fwd(counter)}' 2>/dev/null || echo 0)\nn=$((n+1))\necho "$n" > '${fwd(counter)}'\necho "rejected: non-fast-forward (simulated race)" >&2\nexit 1\n`);
    fs.chmodSync(path.join(hooks, "pre-receive"), 0o755);
    F.git(w.remote, ["config", "core.hooksPath", fwd(hooks)]);
    const before = F.git(w.remote, ["rev-parse", "main"]);
    F.write(path.join(w.a.projects, "p1", "never.jsonl"), jline("n1") + "\n");
    const r = F.engine(w.a, "push");
    assert.strictEqual(r.code, 1, `exhausted retries must fail: ${r.stdout}${r.stderr}`);
    assert.strictEqual(fs.readFileSync(counter, "utf8").trim(), "3", "at most three attempts");
    assert.strictEqual(F.git(w.remote, ["rev-parse", "main"]), before, "the remote is untouched");
    assert.strictEqual(F.readState(w.a).last.result, "failed");
  });
}

function pull(F) {
  test("a pull where only the remote advanced makes no commit and fast-forwards main to origin/main", () => {
    const w = F.world();
    F.write(path.join(w.a.projects, "p1", "s1.jsonl"), jline("a1") + "\n");
    okRun(F.engine(w.a, "push"), "A push");
    const r = F.engine(w.b, "pull");
    okRun(r, "B pull");
    assert.strictEqual(r.stdout.trim(), "Pulled session data.");
    assert.strictEqual(F.git(w.b.projects, ["rev-parse", "main"]), F.git(w.remote, ["rev-parse", "main"]));
    assert.strictEqual(fs.readFileSync(path.join(w.b.projects, "p1", "s1.jsonl"), "utf8"), jline("a1") + "\n");
    assert.strictEqual(F.git(w.b.projects, ["symbolic-ref", "HEAD"]), "refs/heads/main");
    const again = F.engine(w.b, "pull");
    okRun(again, "B second pull");
    assert.strictEqual(F.git(w.b.projects, ["rev-parse", "main"]), F.git(w.remote, ["rev-parse", "main"]), "pull is idempotent");
  });
  // Outline accepted tradeoff: a locally deleted file may come back on a later sync, so this
  // case pins only that the deletion never reaches the remote or another machine.
  test("a local deletion is not pushed to the remote", () => {
    const w = F.world({ seed: { "p1/gone.jsonl": jline("g1") + "\n" } });
    fs.rmSync(path.join(w.a.projects, "p1", "gone.jsonl"));
    F.write(path.join(w.a.projects, "p1", "new.jsonl"), jline("n1") + "\n");
    okRun(F.engine(w.a, "push"), "A push");
    assert.ok(F.show(w.remote, "main", "p1/gone.jsonl") !== null, "the deletion must not reach the remote");
    assert.ok(F.show(w.remote, "main", "p1/new.jsonl") !== null);
    okRun(F.engine(w.b, "pull"), "B pull");
    assert.ok(fs.existsSync(path.join(w.b.projects, "p1", "gone.jsonl")), "another machine keeps its copy");
  });
  // Detail classification row "W deleted, R same as L": while the remote leaves the file
  // unchanged, the integration writes nothing back for it.
  test("a locally deleted file is not written back while the remote has not changed it", () => {
    const w = F.world({ seed: { "p1/gone.jsonl": jline("g1") + "\n" } });
    fs.rmSync(path.join(w.a.projects, "p1", "gone.jsonl"));
    F.write(path.join(w.b.projects, "p2", "other.jsonl"), jline("o1") + "\n");
    okRun(F.engine(w.b, "push"), "B push (does not touch p1/gone.jsonl)");
    okRun(F.engine(w.a, "pull"), "A pull");
    assert.ok(fs.existsSync(path.join(w.a.projects, "p2", "other.jsonl")), "the unrelated remote change is pulled");
    assert.ok(!fs.existsSync(path.join(w.a.projects, "p1", "gone.jsonl")), "an unchanged remote blob is not written back");
  });
  // Detail: R's side is diffed against B = merge-base(L, R), not L, so a commit only on local
  // main (a pull integrates local edits without pushing) is never read as "the remote deleted it".
  test("an unpushed local commit stays in main when the remote advances elsewhere", () => {
    const w = F.world();
    F.write(path.join(w.a.projects, "p1", "kept.jsonl"), jline("k1") + "\n");
    okRun(F.engine(w.a, "pull"), "A pull (commits the local edit, pushes nothing)");
    assert.ok(F.show(w.a.projects, "main", "p1/kept.jsonl") !== null, "precondition: the edit is committed to A's main");
    assert.strictEqual(F.show(w.remote, "main", "p1/kept.jsonl"), null, "precondition: the edit is not on the remote");
    F.write(path.join(w.b.projects, "p2", "other.jsonl"), jline("o1") + "\n");
    okRun(F.engine(w.b, "push"), "B push (does not touch p1/kept.jsonl)");
    okRun(F.engine(w.a, "pull"), "A second pull");
    assert.strictEqual(F.show(w.a.projects, "main", "p1/kept.jsonl"), jline("k1") + "\n", "L's unpushed blob must stay in M");
    assert.ok(F.show(w.a.projects, "main", "p2/other.jsonl") !== null, "the remote change is integrated");
    assert.ok(fs.existsSync(path.join(w.a.projects, "p1", "kept.jsonl")), "the working-tree file is untouched");
    okRun(F.engine(w.a, "push"), "A push");
    assert.ok(F.show(w.remote, "main", "p1/kept.jsonl") !== null && F.show(w.remote, "main", "p2/other.jsonl") !== null);
  });
  test("a file deleted on the remote stays on disk locally", () => {
    const w = F.world({ seed: { "p1/shared.md": "shared\n" } });
    F.git(w.seed, ["pull", "-q"]);
    F.git(w.seed, ["rm", "-q", "p1/shared.md"]);
    F.git(w.seed, ["commit", "-q", "-m", "remote delete"]);
    F.git(w.seed, ["push", "-q"]);
    okRun(F.engine(w.a, "pull"), "A pull");
    assert.strictEqual(fs.readFileSync(path.join(w.a.projects, "p1", "shared.md"), "utf8"), "shared\n");
  });
}

module.exports = { pushes, pull };
