"use strict";
// Re-run and .env.local parts of tests/bin/feature-2762-commit-timeout.js (#2762). Hold no case
// markers; the entrypoint wraps each run function in one and hands over its fake-spawn fixtures as F.
const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const PUSHED_FAMILY = ["pushed", "pr_created", "pr_reused"];

// Run 1 times out after its commit landed; run 2 is the caller's re-run with a fresh payload on
// the same worktree. The fake repo carries HEAD between the runs, and run 2's unpushed count is
// derived from it, so the re-run pushes only because run 1 really advanced HEAD.
function rerun(F, landed) {
  const repo = { head: F.SAME, remote: F.SAME };
  const first = F.runProcedure({ names: "a\0", headBefore: F.SAME, headAfter: landed ? F.OTHER : F.SAME,
    commit: F.timedOut(F.MARKERS), onCommit: () => { if (landed) repo.head = F.OTHER; } });
  const unpushed = repo.head === repo.remote ? "0\n" : "1\n";
  const second = F.runProcedure({ dir: first.dir, stat: "", revList: F.ok(unpushed),
    headBefore: repo.head, headAfter: repo.head, commit: F.err(99, "a re-run must not commit") });
  return { first, second };
}

function runRerun(F) {
  test("re-run: commit_timeout with HEAD advanced, then a re-run on an empty stage pushes the landed commit", () => {
    const { first, second } = rerun(F, true);
    assert.strictEqual(first.res.status, "commit_timeout", `run 1: ${first.res.summary}`);
    assert.ok(first.res.summary.includes("HEAD advanced"), `run 1: ${first.res.summary}`);
    assert.deepStrictEqual(first.pushCalls, [], "run 1: no push after a commit timeout");
    assert.strictEqual(second.commitCall, undefined, "run 2: no git commit is spawned on an empty stage");
    assert.ok(second.calls.some((c) => c.command === "git" && c.args[0] === "rev-list"), "run 2: the unpushed commits are counted");
    assert.deepStrictEqual(second.pushCalls.map((c) => c.args), [["push", "-u", "origin", "feature/2762"]], "run 2: the existing commit is pushed once");
    assert.ok(PUSHED_FAMILY.includes(second.res.status), `run 2: ${second.res.status}: ${second.res.summary}`);
    assert.ok(second.res.summary.startsWith("resumed: push"), `run 2: ${second.res.summary}`);
  });
  test("re-run: commit_timeout with HEAD unchanged, then a re-run on an empty stage has nothing to push", () => {
    const { first, second } = rerun(F, false);
    assert.strictEqual(first.res.status, "commit_timeout", `run 1: ${first.res.summary}`);
    assert.ok(first.res.summary.includes("HEAD unchanged"), `run 1: ${first.res.summary}`);
    assert.strictEqual(second.commitCall, undefined, "run 2: no git commit is spawned on an empty stage");
    assert.deepStrictEqual(second.pushCalls, [], "run 2: nothing was committed, so nothing is pushed");
    assert.strictEqual(second.res.status, "up_to_date", `run 2: ${second.res.summary}`);
  });
}

// .env.local carries the key in three spellings; the commit-push worker reads the checkout .env only.
const LOCAL_ENV = "COMMIT_TIMEOUT_SECS=5\ncommit_timeout_secs=5\nCommit_Timeout_Secs=5\n";
const SPELLINGS = ["COMMIT_TIMEOUT_SECS", "commit_timeout_secs", "Commit_Timeout_Secs"];

function runLocalEnv(F) {
  test(".env.local: a COMMIT_TIMEOUT_SECS there, in any case, never overrides the checkout .env value", () => {
    const r = F.runProcedure({ env: "COMMIT_TIMEOUT_SECS=600\n", localEnv: LOCAL_ENV, names: F.NAMES_208,
      headBefore: F.SAME, headAfter: F.OTHER, commit: F.ok("") });
    assert.strictEqual(r.commitCall.timeoutMs, 600000);
    assert.ok(r.logBody.includes("commit timeout limit: 600s (env)"), r.logBody);
  });
  test(".env.local: a COMMIT_TIMEOUT_SECS there does not stand in for a checkout .env without the key", () => {
    const r = F.runProcedure({ env: "", localEnv: LOCAL_ENV, names: F.NAMES_208, headBefore: F.SAME, headAfter: F.OTHER, commit: F.ok("") });
    assert.strictEqual(r.commitCall.timeoutMs, 1040000);
    assert.ok(r.logBody.includes("commit timeout limit: 1040s (computed, 208 staged files)"), r.logBody);
  });
  test(".env.local: local-env.js blocklists COMMIT_TIMEOUT_SECS in every spelling and overlay keeps the global value", () => {
    const le = require(path.join(F.REPO, "hooks", "lib", "local-env.js"));
    assert.ok(le.ENV_ENTRY_BLOCKLIST_EXACT.has("COMMIT_TIMEOUT_SECS"), "exact blocklist entry");
    SPELLINGS.forEach((key) => assert.strictEqual(le.isBlocklisted(key), true, `isBlocklisted(${key})`));
    assert.strictEqual(le.isBlocklisted("COMMIT_TIMEOUT_SECSX"), false, "the look-alike one character past the entry is allowed");
    const local = Object.fromEntries(SPELLINGS.map((k) => [k, "5"]));
    const got = le.overlay({ COMMIT_TIMEOUT_SECS: "600" }, local);
    assert.deepStrictEqual(got.map, { COMMIT_TIMEOUT_SECS: "600" });
    assert.deepStrictEqual(got.applied, []);
    assert.deepStrictEqual(got.ignored, SPELLINGS);
  });
}

module.exports = { runRerun, runLocalEnv };
