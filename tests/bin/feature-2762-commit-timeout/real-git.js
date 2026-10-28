"use strict";
// real-git-commit-timeout part of tests/bin/feature-2762-commit-timeout.js (#2762). Holds no case
// markers; the entrypoint wraps run() in one and hands over its fixtures and spawn stub as F.
// TL2: a real `git commit` whose planted pre-commit hook prints two markers and sleeps 3 s.
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

function git(cwd, args) {
  const done = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
  assert.strictEqual(done.status, 0, `git ${args.join(" ")}: ${done.stderr}`);
  return done.stdout.trim();
}

// secs null leaves COMMIT_TIMEOUT_SECS out of the checkout .env; extra stages that many more files.
function realGitRun(F, secs, { extra = 0, sleepSecs = 3 } = {}) {
  const dir = F.fixtureDir("real", secs === null ? "" : `COMMIT_TIMEOUT_SECS=${secs}\n`);
  const repo = path.join(dir, "repo");
  F.gitInit(repo);
  git(repo, ["config", "user.name", "f2762"]);
  git(repo, ["config", "user.email", "f2762@example.invalid"]);
  git(repo, ["config", "commit.gpgsign", "false"]);
  git(repo, ["checkout", "-q", "-b", "feature/2762"]);
  fs.writeFileSync(path.join(repo, "seed.txt"), "seed\n");
  git(repo, ["add", "seed.txt"]);
  git(repo, ["commit", "-q", "-m", "seed"]);
  const hooks = path.join(dir, "hooks");
  fs.mkdirSync(hooks);
  fs.writeFileSync(path.join(hooks, "pre-commit"), `#!/bin/sh\nprintf 'pre-commit-section: first-section\\n' >&2\nprintf 'pre-commit-section: second-section\\n' >&2\nsleep ${sleepSecs}\nexit 0\n`, { mode: 0o755 });
  fs.chmodSync(path.join(hooks, "pre-commit"), 0o755);
  git(repo, ["config", "core.hooksPath", hooks.replace(/\\/g, "/")]);
  fs.writeFileSync(path.join(repo, "app.txt"), "x\n");
  for (let i = 0; i < extra; i += 1) fs.writeFileSync(path.join(repo, `extra-${i}.txt`), `${i}\n`);
  git(repo, ["add", "."]);
  const headBefore = git(repo, ["rev-parse", "HEAD"]);
  const realRepo = fs.realpathSync.native(repo);
  let commitTimeoutMs;
  let logBody = "";
  F.setHandler((entry, opts) => {
    if (opts.command === "node" && opts.script === "workflowGate") return F.ok(JSON.stringify({ decision: "approve" }));
    if (opts.command === "bash") return F.err(1, "");
    if (opts.command === "git" && (opts.args || [])[0] === "push") return F.ok("");
    if (opts.command === "git" && (opts.args || []).includes("commit")) commitTimeoutMs = opts.timeoutMs;
    return F.realSpawn.run(entry, opts);
  });
  const ctx = {
    entry: require(path.join(F.REPO, "hooks", "lib", "worker-dispatch-registry.js")).workers["commit-push"],
    anchors: { scriptCheckoutRoot: path.join(dir, "checkout"), plansDir: dir, targetMainRoot: realRepo, family: [realRepo] },
    logDir: path.join(dir, "logs"),
    path,
    fsguard: { writeFile: (p, body) => { logBody = body; return p; } },
  };
  const payload = { branch: "feature/2762", worktree_path: realRepo, session_id: "00000000-0000-4000-8000-000000002762",
    commit_message: "feat: real", wip_mode: true, enforce_worktree: "off", closes_issues: [] };
  const res = F.procedure().run(payload, ctx);
  return { res, headBefore, headAfter: git(repo, ["rev-parse", "HEAD"]), commitTimeoutMs, logBody };
}

function run(F) {
  test("COMMIT_TIMEOUT_SECS=1 stops the 3 s hook: commit_timeout, second marker, HEAD unchanged", { timeout: 60000 }, () => {
    const r = realGitRun(F, 1);
    assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
    assert.ok(r.res.summary.includes("last pre-commit section: second-section"), r.res.summary);
    assert.ok(r.res.summary.includes("HEAD unchanged"), r.res.summary);
    assert.ok(/index\.lock left|no index\.lock/.test(r.res.summary), r.res.summary);
    assert.strictEqual(r.headAfter, r.headBefore);
  });
  test("COMMIT_TIMEOUT_SECS=10 lets the same hook finish: the commit lands", { timeout: 60000 }, () => {
    const r = realGitRun(F, 10);
    assert.strictEqual(r.res.status, "pushed", r.res.summary);
    assert.notStrictEqual(r.headAfter, r.headBefore);
  });
  // 73 > 60 staged files lift the limit off the 300 s floor, so only the real count yields 365000.
  test("no COMMIT_TIMEOUT_SECS: the limit computed from the real staged count reaches git commit", { timeout: 60000 }, () => {
    const r = realGitRun(F, null, { extra: 72, sleepSecs: 0 });
    assert.strictEqual(r.res.status, "pushed", r.res.summary);
    assert.strictEqual(r.commitTimeoutMs, 365000);
    assert.ok(r.logBody.includes("commit timeout limit: 365s (computed, 73 staged files)"), r.logBody);
    assert.notStrictEqual(r.headAfter, r.headBefore);
  });
}

module.exports = { run };
