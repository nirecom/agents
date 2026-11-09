"use strict";
// CLI-contract parts of tests/bin/feature-2658-session-sync-engine.js (#2658): exit codes, the
// state file's result values, startup (silent, deadline, background pull, busy), and reset.
// Holds no case markers; every case drives the real engine CLI.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { jline, sleep } = require("./fixtures");

const okRun = (r, what) => assert.strictEqual(r.code, 0, `${what}: exit ${r.code}\nstdout: ${r.stdout}\nstderr: ${r.stderr}`);
const RESULTS = ["ok", "no-change", "failed", "timeout", "offline", "busy"];

function exitCodes(F) {
  test("usage errors exit 2 and a missing projects/.git exits 3", () => {
    const w = F.world();
    assert.strictEqual(F.engine(w.a, "frobnicate").code, 2, "unknown action");
    assert.strictEqual(F.engine(w.a, "push", ["--no-such-option"]).code, 2, "unknown option");
    assert.strictEqual(F.engine(w.a, "").code, 2, "missing action");
    fs.rmSync(path.join(w.a.projects, ".git"), { recursive: true, force: true });
    assert.strictEqual(F.engine(w.a, "status").code, 3);
    assert.strictEqual(F.engine(w.a, "push").code, 3);
  });
}

function stateResults(F) {
  test("the state file records ok, no-change and a failure with its counter", () => {
    const w = F.world();
    F.write(path.join(w.a.projects, "p1", "s.jsonl"), jline("s1") + "\n");
    okRun(F.engine(w.a, "push"), "A push");
    let st = F.readState(w.a);
    assert.strictEqual(st.schema, 1);
    assert.deepStrictEqual([st.last.action, st.last.result], ["push", "ok"]);
    assert.ok(st.lastSuccess.push, "lastSuccess.push is set");
    assert.strictEqual(st.consecutiveFailures, 0);
    const nc = F.engine(w.a, "push");
    okRun(nc, "A push without changes");
    assert.strictEqual(nc.stdout.trim(), "No changes to push.");
    assert.strictEqual(F.readState(w.a).last.result, "no-change");
    F.git(w.a.projects, ["remote", "set-url", "origin", path.join(w.root, "missing.git")]);
    F.write(path.join(w.a.projects, "p1", "t.jsonl"), jline("t1") + "\n");
    const bad = F.engine(w.a, "push");
    assert.strictEqual(bad.code, 1, `failed push must exit 1: ${bad.stderr}`);
    assert.notStrictEqual(bad.stderr, "", "a non-quiet failure explains itself on stderr");
    st = F.readState(w.a);
    assert.ok(["failed", "offline"].includes(st.last.result), st.last.result);
    assert.strictEqual(st.consecutiveFailures, 1);
    const quiet = F.engine(w.a, "push", ["--quiet"]);
    assert.deepStrictEqual([quiet.stdout, quiet.stderr], ["", ""], "quiet keeps both streams empty");
    assert.strictEqual(F.readState(w.a).consecutiveFailures, 2);
    assert.ok(RESULTS.includes(st.last.result));
  });
  test("status summarizes the last result and lists conflict siblings", () => {
    const w = F.world();
    F.write(path.join(w.a.projects, "p1", "n.sync-conflict-hostX-20260102T030405Z.md"), "x\n");
    okRun(F.engine(w.a, "push"), "A push");
    const r = F.engine(w.a, "status");
    okRun(r, "status");
    assert.match(r.stdout, /ok/);
    assert.match(r.stdout, /n\.sync-conflict-hostX-20260102T030405Z\.md/);
    assert.match(r.stdout, /mtimeRejected/);
  });
}

function startup(F) {
  test("startup is silent, returns at once, and finishes the pull in the background", async () => {
    const w = F.world();
    F.write(path.join(w.a.projects, "p1", "s.jsonl"), jline("s1") + "\n");
    okRun(F.engine(w.a, "push"), "A push");
    const r = F.engine(w.b, "startup", ["--quiet", "--deadline-ms", "3000"]);
    okRun(r, "B startup");
    assert.deepStrictEqual([r.stdout, r.stderr], ["", ""]);
    const want = F.git(w.remote, ["rev-parse", "main"]);
    let main = "";
    for (let i = 0; i < 100 && main !== want; i += 1) {
      await sleep(200);
      main = F.git(w.b.projects, ["rev-parse", "main"]);
    }
    assert.strictEqual(main, want, "the background pull fast-forwards main");
    for (let i = 0; i < 50 && fs.existsSync(path.join(w.b.projects, ".git", "agents-session-sync.lock")); i += 1) await sleep(200);
    assert.ok(fs.existsSync(path.join(w.b.projects, "p1", "s.jsonl")));
  });
  test("startup kills a hung fetch at the deadline and records timeout", () => {
    const w = F.world();
    const hang = path.join(w.root, "hang-upload-pack.sh");
    fs.writeFileSync(hang, "#!/bin/sh\nsleep 20\n");
    F.git(w.b.projects, ["config", "remote.origin.uploadpack", `sh '${hang.replace(/\\/g, "/")}'`]);
    const t0 = Date.now();
    const r = F.engine(w.b, "startup", ["--quiet", "--deadline-ms", "1500"], { timeout: 30000 });
    const elapsed = Date.now() - t0;
    assert.ok(elapsed < 10000, `startup took ${elapsed} ms against a 20 s hang`);
    assert.deepStrictEqual([r.stdout, r.stderr], ["", ""]);
    assert.strictEqual(F.readState(w.b).last.result, "timeout");
  });
  test("startup does not wait for a held lock and records busy", async () => {
    const w = F.world();
    const held = await F.lib("lock").acquire(path.join(w.b.projects, ".git"), { waitMs: 0 });
    try {
      const t0 = Date.now();
      const r = F.engine(w.b, "startup", ["--quiet", "--deadline-ms", "3000"]);
      assert.ok(Date.now() - t0 < 10000, "startup must not wait for the lock");
      assert.deepStrictEqual([r.stdout, r.stderr], ["", ""]);
      assert.strictEqual(F.readState(w.b).last.result, "busy");
    } finally {
      await held.release();
    }
  });
  test("startup warns once on stderr after three consecutive failures", () => {
    const w = F.world();
    F.git(w.b.projects, ["remote", "set-url", "origin", path.join(w.root, "missing.git")]);
    for (let i = 0; i < 3; i += 1) F.engine(w.b, "push", ["--quiet"]);
    assert.ok(F.readState(w.b).consecutiveFailures >= 3);
    const r = F.engine(w.b, "startup", ["--quiet", "--deadline-ms", "3000"]);
    assert.strictEqual(r.stdout, "");
    assert.strictEqual(r.stderr.trim().split(/\r?\n/).length, 1, `stderr: ${r.stderr}`);
  });
}

function reset(F) {
  test("reset keeps local-only files, restores remote files deleted locally, and does not push", () => {
    const w = F.world({ seed: { "p1/remote.jsonl": jline("r1") + "\n", "p1/note.md": "remote\n" } });
    fs.rmSync(path.join(w.a.projects, "p1", "remote.jsonl"));
    F.write(path.join(w.a.projects, "p1", "local-only.jsonl"), jline("l1") + "\n");
    F.write(path.join(w.a.projects, "p1", "note.md"), "local\n");
    const before = F.git(w.remote, ["rev-parse", "main"]);
    const r = F.engine(w.a, "reset");
    okRun(r, "A reset");
    assert.strictEqual(r.stdout.trim(), "Reset to remote state.");
    assert.strictEqual(fs.readFileSync(path.join(w.a.projects, "p1", "local-only.jsonl"), "utf8"), jline("l1") + "\n");
    assert.ok(fs.existsSync(path.join(w.a.projects, "p1", "remote.jsonl")), "reset restores a locally deleted remote file");
    assert.strictEqual(F.git(w.remote, ["rev-parse", "main"]), before, "reset does not push");
    const p1 = fs.readdirSync(path.join(w.a.projects, "p1"));
    const sib = p1.filter((n) => /^note\.sync-conflict-.+\.md$/.test(n));
    assert.strictEqual(fs.readFileSync(path.join(w.a.projects, "p1", "note.md"), "utf8"), "remote\n", "R stays at the path");
    assert.strictEqual(sib.length, 1, `siblings: ${p1}`);
    assert.strictEqual(fs.readFileSync(path.join(w.a.projects, "p1", sib[0]), "utf8"), "local\n", "local goes to the sibling");
  });
}

module.exports = { exitCodes, stateResults, startup, reset };
