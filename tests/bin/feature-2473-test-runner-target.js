"use strict";
// Tests: bin/worker-dispatch/workers/test-runner.js, hooks/lib/worker-dispatch-registry.js, hooks/lib/same-repo.js, hooks/pre-commit.d/context.js
// Tags: TL2, bin, worker-dispatch, run-tests, repo-settings, migrate, scope:issue-specific
// #2473 — the test-runner worker reads the tests section of payload.cwd's .agents.json before it
// spawns anything: missing or malformed is a runner-error whose summary points at /migrate. The
// registry splits the runner into runAllSelf (family-worktree: only when the target IS the agents
// repo, same git common dir) and runAllShared (`SCRIPT_CHECKOUT_ROOT`), and passes `RUN_ALL_TARGET_ROOT`.
// The same-repo judgement moves out of hooks/pre-commit.d/context.js into hooks/lib/same-repo.js.
// TL3 gap: a real /run-tests dispatch against a non-agents repo; here spawn is replaced by a spy.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
after(() => restore());

const CHECKOUT = path.resolve(__dirname, "..", "..");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "trt2473-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const VALID = { tests: { dir: "tests", categorization: "flat", testHarness: "off", caseMarker: "off" } };

function git(dir, ...args) {
  const r = spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout;
}

// repo(name, settings) — a committed repo; settings null = no .agents.json, a string = raw text.
function repo(name, settings) {
  const d = path.join(TMP, name);
  fs.mkdirSync(path.join(d, "tests"), { recursive: true });
  gitInit(d);
  fs.writeFileSync(path.join(d, "tests", "t.sh"), "#!/usr/bin/env bash\nexit 0\n");
  if (settings !== null) {
    const body = typeof settings === "string" ? settings : `${JSON.stringify(settings, null, 2)}\n`;
    fs.writeFileSync(path.join(d, ".agents.json"), body);
  }
  git(d, "add", "-A");
  git(d, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--no-verify", "-m", "fixture");
  return d;
}

const AGENTS_LIKE = repo("agents-like", VALID);
const AGENTS_WT = path.join(TMP, "agents-like-wt");
git(AGENTS_LIKE, "worktree", "add", "-q", "-b", "wt", AGENTS_WT);
const OTHER = repo("other", VALID);
const NONE = repo("none", null);
const BAD = repo("bad", "{ not json\n");
// Valid JSON whose only section is migrate: the file exists, the tests section does not.
const NO_TESTS = repo("no-tests-section", { migrate: { tracker: "done", issues: "done" } });

// The worker destructures spawn's exports when it loads, so the spy goes in before it is required.
// With spy.real set, script lookup, script path and child env go through the real spawn code;
// only the child process itself is never started.
const SPAWN = path.join(CHECKOUT, "bin", "worker-dispatch", "spawn.js");
const spawnMod = require(SPAWN);
const real = { scriptExists: spawnMod.scriptExists, resolveScript: spawnMod.resolveScript, buildEnv: spawnMod.buildEnv };
const spy = { real: false };
const calls = [];
spawnMod.scriptExists = (entry, key, anchors, cwd) => {
  if (spy.real) return real.scriptExists(entry, key, anchors, cwd);
  return entry.binaries.scripts[key] ? path.join(TMP, "spy-run-all.sh") : null;
};
spawnMod.run = (entry, opts) => {
  const call = { script: opts.script, cwd: opts.cwd, env: opts.env, extraEnv: opts.extraEnv };
  if (spy.real) {
    call.resolved = real.resolveScript(entry, opts.script, opts.anchors, opts.cwd);
    call.childEnv = real.buildEnv(entry, opts.anchors, opts.extraEnv, opts.envScope);
  }
  calls.push(call);
  return { status: 0, stdout: "Results: 1 passed, 0 failed, 0 skipped\n", stderr: "", timedOut: false, spawnError: null };
};
const worker = require(path.join(CHECKOUT, "bin", "worker-dispatch", "workers", "test-runner.js"));
const REG = require(path.join(CHECKOUT, "hooks", "lib", "worker-dispatch-registry.js"));
const ENTRY = REG.workers["test-runner"];

function runWorker(cwd) {
  calls.length = 0;
  const anchors = { scriptCheckoutRoot: AGENTS_LIKE, targetMainRoot: AGENTS_LIKE, family: [AGENTS_LIKE, AGENTS_WT] };
  const out = worker.run({ cwd, test_args: [], timeout_seconds: 60 }, { anchors, entry: ENTRY });
  return { out, calls: calls.slice() };
}

caseBegin("TRT-registry-script-keys", "hooks/lib/worker-dispatch-registry.js");
test("TRT-registry-script-keys: runAllSelf is family-worktree, runAllShared is script-checkout-root, both tests/run-all.sh", () => {
  const s = ENTRY.binaries.scripts;
  assert.deepEqual(s.runAllSelf, { anchor: "family-worktree", rel: "tests/run-all.sh" }, "runAllSelf");
  assert.deepEqual(s.runAllShared, { anchor: "script-checkout-root", rel: "tests/run-all.sh" }, "runAllShared");
  assert.ok(ENTRY.envPassthrough.includes("RUN_ALL_TARGET_ROOT"), `envPassthrough: ${JSON.stringify(ENTRY.envPassthrough)}`);
});
caseEnd();

caseBegin("TRT-same-repo-module", "hooks/lib/same-repo.js");
test("TRT-same-repo-module: a linked worktree is the same repo, an unrelated repo and a non-repo are not", () => {
  const mod = require(path.join(CHECKOUT, "hooks", "lib", "same-repo.js"));
  const sameRepo = typeof mod === "function" ? mod : mod.sameRepo;
  assert.equal(typeof sameRepo, "function", "hooks/lib/same-repo.js exports sameRepo");
  assert.equal(sameRepo(AGENTS_LIKE, AGENTS_WT, process.env), true, "main + its linked worktree");
  assert.equal(sameRepo(AGENTS_LIKE, OTHER, process.env), false, "two unrelated repos");
  assert.equal(sameRepo(AGENTS_LIKE, path.join(TMP), process.env), false, "a directory that is no repo");
  // An inherited GIT_DIR must not make every directory look like the repo it names.
  assert.equal(sameRepo(AGENTS_LIKE, OTHER, { ...process.env, GIT_DIR: path.join(AGENTS_LIKE, ".git") }), false, "GIT_DIR is dropped");
});
caseEnd();

caseBegin("TRT-context-uses-shared", "hooks/pre-commit.d/context.js");
test("TRT-context-uses-shared: context.js takes the judgement from ../lib/same-repo and keeps its export", () => {
  const src = fs.readFileSync(path.join(CHECKOUT, "hooks", "pre-commit.d", "context.js"), "utf8");
  assert.match(src, /require\(["']\.\.\/lib\/same-repo["']\)/, "context.js requires ../lib/same-repo");
  const ctx = require(path.join(CHECKOUT, "hooks", "pre-commit.d", "context.js"));
  assert.equal(ctx.sameRepo(AGENTS_LIKE, AGENTS_WT, process.env), true, "context.sameRepo still answers");
});
caseEnd();

caseBegin("TRT-uninitialized-runner-error", "bin/worker-dispatch/workers/test-runner.js");
test("TRT-uninitialized-runner-error: missing or malformed tests section is a runner-error naming /migrate, nothing spawned", () => {
  for (const [label, dir] of [["missing", NONE], ["malformed", BAD], ["valid JSON without a tests section", NO_TESTS]]) {
    const { out, calls: c } = runWorker(dir);
    assert.equal(out.status, "runner-error", `${label}: status`);
    assert.match(String(out.summary), /\/migrate/, `${label}: summary names /migrate: ${out.summary}`);
    assert.equal(c.length, 0, `${label}: the suite was spawned ${c.length} time(s)`);
  }
});
caseEnd();

caseBegin("TRT-script-key-choice", "bin/worker-dispatch/workers/test-runner.js");
test("TRT-script-key-choice: runAllSelf only for the agents repo itself (a linked worktree counts), runAllShared otherwise", () => {
  const self = runWorker(AGENTS_WT);
  assert.deepEqual(self.calls.map((c) => c.script), ["runAllSelf"], `agents linked worktree: ${JSON.stringify(self.out)}`);
  const other = runWorker(OTHER);
  assert.deepEqual(other.calls.map((c) => c.script), ["runAllShared"], `unrelated repo: ${JSON.stringify(other.out)}`);
  assert.notEqual(other.out.status, "runner-error", "an initialized repo is not a runner-error");
});
caseEnd();

// TL3 gap: bin/worker-dispatch.js itself (payload file in a session control dir, the
// .dispatched marker, emit) and a real bash child running the shared runner against the target
// need a live session; here the anchors come from the dispatcher's own resolveAnchors and the
// script path and child env from the real spawn code, with only the child process withheld.
const TARGET = repo("target-no-runner", VALID);
caseBegin("TRT-shared-runner-for-target", "bin/worker-dispatch/workers/test-runner.js");
test("TRT-shared-runner-for-target: a repo with no runner copy gets the agents checkout's tests/run-all.sh and RUN_ALL_TARGET_ROOT=<target>", () => {
  assert.equal(fs.existsSync(path.join(TARGET, "tests", "run-all.sh")), false, "fixture precondition: the target has no runner copy");
  const anchors = require(path.join(CHECKOUT, "bin", "worker-dispatch", "anchor.js")).resolveAnchors(TARGET);
  assert.equal(anchors.error, null, `resolveAnchors: ${anchors.error}`);
  const realPath = (p) => {
    const r = fs.realpathSync.native(p);
    return process.platform === "win32" ? r.toLowerCase() : r;
  };
  assert.equal(realPath(anchors.scriptCheckoutRoot), realPath(CHECKOUT), "the script checkout root is this agents checkout");
  calls.length = 0;
  spy.real = true;
  let out;
  try {
    out = worker.run({ cwd: TARGET, test_args: [], timeout_seconds: 60 }, { anchors, entry: ENTRY });
  } finally {
    spy.real = false;
  }
  assert.deepEqual(calls.map((c) => c.script), ["runAllShared"], `script keys: ${JSON.stringify(out)}`);
  const [call] = calls;
  assert.equal(realPath(call.resolved), realPath(path.join(CHECKOUT, "tests", "run-all.sh")), "the runner is the agents checkout's tests/run-all.sh");
  const passed = call.childEnv && call.childEnv.RUN_ALL_TARGET_ROOT;
  assert.ok(typeof passed === "string" && passed !== "", `child env carries RUN_ALL_TARGET_ROOT: ${JSON.stringify(call.extraEnv)}`);
  assert.equal(realPath(passed), realPath(TARGET), "RUN_ALL_TARGET_ROOT names the target repo");
  assert.notEqual(out.status, "runner-error", `an initialized target is not a runner-error: ${out.summary}`);
});
caseEnd();
