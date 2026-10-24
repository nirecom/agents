"use strict";
// Tests: bin/worker-dispatch/workers/commit-push/commit-timeout.js, bin/worker-dispatch/workers/commit-push/gate.js, bin/worker-dispatch/workers/commit-push/procedure.js
// Tags: TL1, TL2, worker-dispatch, commit-push, commit-timeout, pre-commit-section-marker, fake-spawn, real-git, scope:issue-specific, empty-stage-resume, local-env
// #2762: the commit-push worker gives `git commit` a time limit derived from the staged-file count
// (5 s per file, at least 300 s, at most 3600 s), which a valid COMMIT_TIMEOUT_SECS in the script
// checkout .env replaces as-is. A commit that hits the limit ends as `commit_timeout`, with a summary
// naming the last pre-commit section marker and what HEAD / index.lock look like afterwards.
// spawn.js is replaced through require.cache BEFORE gate.js loads (gate.js destructures `run` at
// load time); the stub forwards to a per-test handler, and the real-git cases forward git to the
// real spawn.run. Every module under test is loaded inside each test, so a missing module or a
// missing export fails each case with its own message.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { offsetClocks } = require("./feature-2762-commit-timeout/fake-clock");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const CP_DIR = path.join(REPO, "bin", "worker-dispatch", "workers", "commit-push");
const TIMEOUT_MODULE = path.join(CP_DIR, "commit-timeout.js");
const GATE_MODULE = path.join(CP_DIR, "gate.js");
const PROCEDURE_MODULE = path.join(CP_DIR, "procedure.js");
const SPAWN_PATH = require.resolve(path.join(REPO, "bin", "worker-dispatch", "spawn.js"));

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2762-commit-timeout-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

const realSpawn = require(SPAWN_PATH);
let handler = () => { throw new Error("no spawn handler installed for this test"); };
require.cache[SPAWN_PATH] = {
  id: SPAWN_PATH,
  filename: SPAWN_PATH,
  loaded: true,
  exports: { ...realSpawn, run: (entry, opts) => handler(entry, opts) },
};

const tm = () => require(TIMEOUT_MODULE);
const gate = () => require(GATE_MODULE);
const procedure = () => require(PROCEDURE_MODULE);

const ok = (stdout) => ({ status: 0, signal: null, timedOut: false, spawnError: null, stdout: stdout || "", stderr: "" });
const err = (status, stderr) => ({ status, signal: null, timedOut: false, spawnError: null, stdout: "", stderr: stderr || "" });
const timedOut = (stderr) => ({ status: null, signal: "SIGTERM", timedOut: true, spawnError: null, stdout: "", stderr });
const fakeGit = (res) => () => res;

let seq = 0;
function fixtureDir(name, envBody) {
  seq += 1;
  const dir = path.join(TMP, `${name}-${seq}`);
  fs.mkdirSync(path.join(dir, "checkout"), { recursive: true });
  fs.mkdirSync(path.join(dir, "worktree", ".git"), { recursive: true });
  fs.mkdirSync(path.join(dir, "logs"), { recursive: true });
  fs.mkdirSync(path.join(dir, "state"), { recursive: true });
  const state = path.join(dir, "state").replace(/\\/g, "/");
  if (envBody !== null) fs.writeFileSync(path.join(dir, "checkout", ".env"), `WORKFLOW_STATE_DIR=${state}\n${envBody || ""}`);
  return dir;
}

const MARKERS = "pre-commit-section: enforce-worktree\npre-commit-section: tests-frontmatter\nsome hook chatter\npre-commit-section: outbound-scan\n";

// Scenario-driven fake of every child the commit step reaches. `sc` fields: names (stdout of
// `diff --cached --name-only -z`, or a result object), headBefore / headAfter / lockPath (result
// objects), commit (result object), stat (stdout of `diff --cached --stat`; "" is an empty
// stage), revList (result of the resume's unpushed count), dir (reuse a fixture: a re-run),
// localEnv (a .env.local planted beside the checkout .env and in the worktree), commitElapsedMs
// (how far performance.now jumps during the commit; a timed-out commit defaults to its limit + 1 s),
// commitWallJumpMs (how far Date.now jumps, default 0). Records every call with its timeout.
function runProcedure(sc) {
  const dir = sc.dir || fixtureDir("proc", sc.env === undefined ? "" : sc.env);
  if (sc.localEnv !== undefined) {
    fs.writeFileSync(path.join(dir, "checkout", ".env.local"), sc.localEnv);
    fs.writeFileSync(path.join(dir, "worktree", ".env.local"), sc.localEnv);
  }
  const worktree = path.join(dir, "worktree");
  if (sc.plantLock) {
    const lock = sc.plantLock === "abs" ? path.join(dir, "abs-index.lock") : path.join(worktree, ".git", "index.lock");
    fs.writeFileSync(lock, "");
  }
  const calls = [];
  let headProbes = 0;
  handler = (_entry, opts) => {
    const args = opts.args || [];
    const a = args.join(" ");
    calls.push({ command: opts.command, script: opts.script || "", args, timeoutMs: opts.timeoutMs });
    if (opts.command === "node" && opts.script === "workflowGate") return ok(JSON.stringify({ decision: "approve" }));
    if (opts.command === "bash") return err(1, "");
    if (opts.command !== "git") return ok("");
    if (a === "rev-parse --abbrev-ref HEAD") return ok("feature/2762\n");
    if (a === "diff --cached --stat") return ok(sc.stat === undefined ? " a.txt | 1 +\n" : sc.stat);
    if (args[0] === "rev-list" && sc.revList) return sc.revList;
    if (a === "diff --cached --name-only -z") return typeof sc.names === "object" ? sc.names : ok(sc.names);
    if (a === "rev-parse --verify --quiet HEAD") {
      headProbes += 1;
      return headProbes === 1 ? sc.headBefore : sc.headAfter;
    }
    if (a === "rev-parse --git-path index.lock") {
      if (sc.lockPath === "abs") return ok(`${path.join(dir, "abs-index.lock").replace(/\\/g, "/")}\n`);
      return sc.lockPath || ok(".git/index.lock\n");
    }
    if (args.includes("commit")) {
      if (sc.onCommit) sc.onCommit();
      clk.mono += typeof sc.commitElapsedMs === "number" ? sc.commitElapsedMs : (sc.commit && sc.commit.timedOut ? opts.timeoutMs + 1000 : 0);
      clk.wall += sc.commitWallJumpMs || 0;
      return sc.commit;
    }
    if (a.includes("@{upstream}")) return err(128, "no upstream");
    return ok("");
  };
  let logBody = "";
  const ctx = {
    entry: { name: "commit-push", binaries: { external: [], scripts: {} } },
    anchors: { scriptCheckoutRoot: path.join(dir, "checkout"), plansDir: dir },
    logDir: path.join(dir, "logs"),
    path,
    fsguard: { writeFile: (p, body) => { logBody = body; return p; } },
  };
  const payload = {
    branch: "feature/2762",
    worktree_path: worktree,
    session_id: "00000000-0000-4000-8000-000000002762",
    commit_message: "feat: a thing",
    wip_mode: true,
    enforce_worktree: "off",
    closes_issues: [],
  };
  const clk = offsetClocks();
  let res;
  try { res = procedure().run(payload, ctx); } finally { clk.restore(); }
  const commitCall = calls.find((c) => c.command === "git" && c.args.includes("commit"));
  const pushCalls = calls.filter((c) => c.command === "git" && c.args[0] === "push");
  return { res, calls, commitCall, pushCalls, logBody, dir, worktree };
}

const NAMES_208 = Array.from({ length: 208 }, (_, i) => `f${i}.txt\0`).join("");
const SAME = ok("1111111111111111111111111111111111111111\n");
const OTHER = ok("2222222222222222222222222222222222222222\n");

caseBegin("parse-commit-timeout-setting", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
const UNSET = { kind: "unset", ms: null };
const INVALID = { kind: "invalid", ms: null };
const PARSE_CASES = [
  { name: "unset-undefined", input: undefined, want: UNSET },
  { name: "unset-null", input: null, want: UNSET },
  { name: "unset-empty", input: "", want: UNSET },
  { name: "unset-whitespace-only", input: "   ", want: UNSET },
  { name: "valid-one-second", input: "1", want: { kind: "valid", ms: 1000 } },
  { name: "valid-600", input: "600", want: { kind: "valid", ms: 600000 } },
  { name: "valid-trimmed", input: " 1800 ", want: { kind: "valid", ms: 1800000 } },
  { name: "valid-max-86400", input: "86400", want: { kind: "valid", ms: 86400000 } },
  { name: "invalid-zero", input: "0", want: INVALID },
  { name: "invalid-negative", input: "-1", want: INVALID },
  { name: "invalid-plus-sign", input: "+600", want: INVALID },
  { name: "invalid-fraction", input: "600.5", want: INVALID },
  { name: "invalid-unit-s", input: "600s", want: INVALID },
  { name: "invalid-unit-m", input: "10m", want: INVALID },
  { name: "invalid-exponent", input: "6e2", want: INVALID },
  { name: "invalid-word", input: "abc", want: INVALID },
  { name: "invalid-leading-zero", input: "0600", want: INVALID },
  { name: "invalid-max-plus-one", input: "86401", want: INVALID },
  { name: "invalid-six-digits", input: "100000", want: INVALID },
  { name: "invalid-overlong", input: "99999999999999999999", want: INVALID },
  { name: "invalid-shell-text", input: "$(id)", want: INVALID },
  { name: "invalid-two-numbers", input: "1 2", want: INVALID },
];
test("parseCommitTimeoutSetting: unset, valid (ms, trimmed, up to 86400) and invalid inputs", () => {
  PARSE_CASES.forEach(({ name, input, want }) => {
    const got = tm().parseCommitTimeoutSetting(input);
    assert.strictEqual(got.kind, want.kind, `${name}: kind for raw=${JSON.stringify(input)}`);
    assert.strictEqual(got.ms, want.ms, `${name}: ms for raw=${JSON.stringify(input)}`);
  });
});
test("the raw value is kept on the result", () => {
  assert.strictEqual(tm().parseCommitTimeoutSetting("abc").raw, "abc");
});
caseEnd();

caseBegin("compute-commit-timeout-from-staged-count", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
test("5 s per staged file, floor 300 s, cap 3600 s", () => {
  const table = [[0, 300000], [60, 300000], [61, 305000], [208, 1040000], [719, 3595000], [720, 3600000], [10000, 3600000]];
  for (const [n, ms] of table) assert.strictEqual(tm().computeCommitTimeoutMs(n), ms, `n=${n}`);
});
test("a count that is not a non-negative integer gives the floor", () => {
  for (const n of [1.5, -1, null, undefined, NaN, "208", Infinity]) assert.strictEqual(tm().computeCommitTimeoutMs(n), 300000, `n=${String(n)}`);
});
caseEnd();

caseBegin("resolve-commit-timeout-limit", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
test("a valid setting is used as-is, with neither floor nor cap", () => {
  const one = tm().resolveCommitTimeoutLimit({ COMMIT_TIMEOUT_SECS: "1" }, 208);
  assert.strictEqual(one.ms, 1000);
  assert.strictEqual(one.source, "env");
  const max = tm().resolveCommitTimeoutLimit({ COMMIT_TIMEOUT_SECS: "86400" }, 0);
  assert.strictEqual(max.ms, 86400000);
  assert.strictEqual(max.source, "env");
});
test("no setting: the computed value, with the staged count and no invalidRaw", () => {
  const got = tm().resolveCommitTimeoutLimit({}, 208);
  assert.strictEqual(got.ms, 1040000);
  assert.strictEqual(got.source, "computed");
  assert.strictEqual(got.stagedCount, 208);
  assert.ok(got.invalidRaw === null || got.invalidRaw === undefined, "invalidRaw is empty");
});
test("an invalid setting falls back to the computed value and keeps the raw text", () => {
  const got = tm().resolveCommitTimeoutLimit({ COMMIT_TIMEOUT_SECS: "abc" }, 208);
  assert.strictEqual(got.ms, 1040000);
  assert.strictEqual(got.source, "computed");
  assert.strictEqual(got.invalidRaw, "abc");
});
test("an unknown staged count gives the floor", () => {
  assert.strictEqual(tm().resolveCommitTimeoutLimit({}, null).ms, 300000);
});
caseEnd();

caseBegin("last-section-marker", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
const NEAR_MISSES = ["error: something", "  pre-commit-section: indented", "pre-commit-section: UPPER",
  "pre-commit-section: -lead", "pre-commit-section: a b", "xpre-commit-section: prefixed", "pre-commit-section:nospace"];
const MARKER_CASES = [
  { name: "last-wins-lf", input: "pre-commit-section: a\npre-commit-section: b\n", want: "b" },
  { name: "last-wins-crlf", input: "pre-commit-section: a\r\npre-commit-section: b-2\r\n", want: "b-2" },
  { name: "trailing-spaces", input: "pre-commit-section: ok   \n", want: "ok" },
  { name: "near-misses-after-real", input: ["pre-commit-section: real", ...NEAR_MISSES].join("\n"), want: "real" },
  ...NEAR_MISSES.map((line, i) => ({ name: `near-miss-alone-${i}`, input: `${line}\n`, want: "unknown" })),
  { name: "empty", input: "", want: "unknown" },
  { name: "no-marker", input: "fatal: nothing here\n", want: "unknown" },
];
test("lastSectionMarker: the last valid marker line wins, near misses are ignored, none gives unknown", () => {
  MARKER_CASES.forEach(({ name, input, want }) => {
    assert.strictEqual(tm().lastSectionMarker(input), want, `${name}: input=${JSON.stringify(input)}`);
  });
});
caseEnd();

caseBegin("describe-after-state", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
test("same sha, different sha, unborn to sha, unknown side", () => {
  const d = (headBefore, headAfter) => tm().describeAfterState({ headBefore, headAfter });
  assert.strictEqual(d({ known: true, sha: "aaa" }, { known: true, sha: "aaa" }), "unchanged");
  assert.strictEqual(d({ known: true, sha: "aaa" }, { known: true, sha: "bbb" }), "advanced");
  assert.strictEqual(d({ known: true, sha: null }, { known: true, sha: "bbb" }), "advanced");
  assert.strictEqual(d({ known: true, sha: null }, { known: true, sha: null }), "unchanged");
  assert.strictEqual(d({ known: false }, { known: true, sha: "aaa" }), "unknown");
  assert.strictEqual(d({ known: true, sha: "aaa" }, { known: false }), "unknown");
});
caseEnd();

caseBegin("format-commit-timeout-summary", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
const COMPUTED_1040 = { ms: 1040000, source: "computed", stagedCount: 208, invalidRaw: null };
test("the computed-limit summary reads exactly as specified", () => {
  const got = tm().formatCommitTimeoutSummary({ elapsedMs: 1041000, limit: COMPUTED_1040, marker: "outbound-scan", after: { head: "unchanged", indexLock: "left" } });
  assert.strictEqual(got, "git commit timed out after 1041s (limit 1040s from 208 staged files); last pre-commit section: outbound-scan; after stop: HEAD unchanged, index.lock left. Raise COMMIT_TIMEOUT_SECS in .env to allow longer.");
});
test("an env limit names COMMIT_TIMEOUT_SECS in the parenthetical", () => {
  const got = tm().formatCommitTimeoutSummary({ elapsedMs: 1800400, limit: { ms: 1800000, source: "env", stagedCount: 3, invalidRaw: null }, marker: "code-lang", after: { head: "unchanged", indexLock: "none" } });
  assert.ok(got.includes("(limit 1800s set by COMMIT_TIMEOUT_SECS)"), got);
});
test("every after-stop combination is worded", () => {
  const heads = { unchanged: "HEAD unchanged", advanced: "HEAD advanced", unknown: "HEAD unknown" };
  const locks = { left: "index.lock left", none: "no index.lock", unknown: "index.lock unknown" };
  for (const [head, hw] of Object.entries(heads)) {
    for (const [indexLock, lw] of Object.entries(locks)) {
      const got = tm().formatCommitTimeoutSummary({ elapsedMs: 301000, limit: COMPUTED_1040, marker: "outbound-scan", after: { head, indexLock } });
      assert.ok(got.includes(`after stop: ${hw}, ${lw}.`), `${head}/${indexLock}: ${got}`);
    }
  }
});
test("the longest combination still fits the 300-character summary limit", () => {
  const marker = "a".repeat(200);
  for (const limit of [{ ms: 86400000, source: "env", stagedCount: 99999999, invalidRaw: null }, { ms: 3600000, source: "computed", stagedCount: 99999999, invalidRaw: "99999" }]) {
    const got = tm().formatCommitTimeoutSummary({ elapsedMs: 86400999, limit, marker, after: { head: "unknown", indexLock: "unknown" } });
    assert.ok(got.length <= 300, `length ${got.length}: ${got}`);
    assert.ok(got.includes("a".repeat(20)), "the marker name is still shown");
  }
});
caseEnd();

caseBegin("count-staged-files-and-probe-head", "bin/worker-dispatch/workers/commit-push/commit-timeout.js");
test("countStagedFiles counts NUL-separated names from git diff --cached --name-only -z", () => {
  let seen = null;
  const runGit = (_ctx, _payload, args) => { seen = args; return ok("a\0b c\0d\0"); };
  assert.strictEqual(tm().countStagedFiles(runGit, {}, {}, []), 3);
  assert.deepStrictEqual(seen, ["diff", "--cached", "--name-only", "-z"]);
  assert.strictEqual(tm().countStagedFiles(fakeGit(ok("")), {}, {}, []), 0);
});
test("countStagedFiles answers null when git cannot answer", () => {
  for (const r of [null, err(128, "fatal"), timedOut(""), { ...err(null), spawnError: "ENOENT" }]) {
    assert.strictEqual(tm().countStagedFiles(fakeGit(r), {}, {}, []), null, JSON.stringify(r));
  }
});
test("probeHead: a sha, an unborn branch, and an unknown answer", () => {
  const known = tm().probeHead(fakeGit(ok("abc123\n")), {}, {}, []);
  assert.strictEqual(known.known, true);
  assert.strictEqual(known.sha, "abc123");
  const unborn = tm().probeHead(fakeGit(err(1, "")), {}, {}, []);
  assert.strictEqual(unborn.known, true);
  assert.strictEqual(unborn.sha, null);
  for (const r of [null, err(128, "fatal: not a git repository"), timedOut(""), { ...err(null), spawnError: "ENOENT" }]) {
    assert.strictEqual(tm().probeHead(fakeGit(r), {}, {}, []).known, false, JSON.stringify(r));
  }
});
test("inspectAfterCommitTimeout reports a left index.lock and never deletes it", () => {
  const dir = fixtureDir("inspect", "");
  const lock = path.join(dir, "worktree", ".git", "index.lock");
  fs.writeFileSync(lock, "");
  const runGit = (_c, _p, args) => (args[0] === "rev-parse" && args.includes("--git-path") ? ok(".git/index.lock\n") : SAME);
  const got = tm().inspectAfterCommitTimeout(runGit, {}, { worktree_path: path.join(dir, "worktree") }, [], { known: true, sha: SAME.stdout.trim() });
  assert.strictEqual(got.head, "unchanged");
  assert.strictEqual(got.indexLock, "left");
  assert.ok(fs.existsSync(lock), "the worker must not delete index.lock");
});
caseEnd();

caseBegin("gate-read-checkout-env", "bin/worker-dispatch/workers/commit-push/gate.js");
test("readCheckoutEnv reads the script checkout .env, and {} when there is none", () => {
  const dir = fixtureDir("env", "COMMIT_TIMEOUT_SECS=1800\n");
  assert.strictEqual(gate().readCheckoutEnv({ anchors: { scriptCheckoutRoot: path.join(dir, "checkout") } }).COMMIT_TIMEOUT_SECS, "1800");
  const none = fixtureDir("noenv", null);
  assert.deepStrictEqual(gate().readCheckoutEnv({ anchors: { scriptCheckoutRoot: path.join(none, "checkout") } }), {});
});
caseEnd();

caseBegin("gate-run-git-timeout-and-elapsed", "bin/worker-dispatch/workers/commit-push/gate.js");
function runGitWith(timeoutMs) {
  let seen;
  handler = (_e, opts) => { seen = opts.timeoutMs; return ok(""); };
  const res = gate().runGit({ entry: {}, anchors: {} }, { worktree_path: TMP }, ["status"], [], undefined, undefined, timeoutMs);
  return { seen, res };
}
test("runGit passes a positive timeoutMs and falls back to 300000 otherwise", () => {
  assert.strictEqual(runGitWith(1040000).seen, 1040000);
  for (const t of [0, -5, undefined, NaN]) assert.strictEqual(runGitWith(t).seen, 300000, `timeoutMs=${String(t)}`);
});
test("runGit reports the elapsed milliseconds", () => {
  const { res } = runGitWith(undefined);
  assert.strictEqual(typeof res.elapsedMs, "number");
  assert.ok(res.elapsedMs >= 0);
});
caseEnd();

caseBegin("procedure-commit-timeout-status", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("(i) a timed-out commit ends as commit_timeout with elapsed, limit, marker and HEAD unchanged", () => {
  const r = runProcedure({ names: NAMES_208, headBefore: SAME, headAfter: SAME, commit: timedOut(MARKERS) });
  assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
  assert.match(r.res.summary, /^git commit timed out after \d+s \(limit 1040s from 208 staged files\); last pre-commit section: outbound-scan; after stop: HEAD unchanged, no index\.lock\./);
  assert.deepStrictEqual(r.pushCalls, [], "no push after a commit timeout");
});
test("(ii) HEAD that moved during the stop reads advanced, and still no push", () => {
  const r = runProcedure({ names: NAMES_208, headBefore: SAME, headAfter: OTHER, commit: timedOut(MARKERS) });
  assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
  assert.ok(r.res.summary.includes("HEAD advanced"), r.res.summary);
  assert.deepStrictEqual(r.pushCalls, []);
});
test("(ii-b) an unborn branch that gained a commit reads advanced", () => {
  const r = runProcedure({ names: "a\0", headBefore: err(1, ""), headAfter: SAME, commit: timedOut(MARKERS) });
  assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
  assert.ok(r.res.summary.includes("HEAD advanced"), r.res.summary);
});
test("(iii) an index.lock left behind is reported, relative or absolute, and kept", () => {
  for (const [plantLock, lockPath] of [["rel", undefined], ["abs", "abs"]]) {
    const r = runProcedure({ names: "a\0", headBefore: SAME, headAfter: SAME, commit: timedOut(MARKERS), plantLock, lockPath });
    assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
    assert.ok(r.res.summary.includes("index.lock left"), `${plantLock}: ${r.res.summary}`);
    const lock = plantLock === "abs" ? path.join(r.dir, "abs-index.lock") : path.join(r.worktree, ".git", "index.lock");
    assert.ok(fs.existsSync(lock), "the worker must not delete index.lock");
  }
});
test("(iii-b) probes that fail after the stop read HEAD unknown and index.lock unknown", () => {
  const r = runProcedure({ names: "a\0", headBefore: SAME, headAfter: err(128, "fatal"), lockPath: err(128, "fatal"), commit: timedOut("") });
  assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
  assert.ok(r.res.summary.includes("HEAD unknown, index.lock unknown"), r.res.summary);
  assert.ok(r.res.summary.includes("last pre-commit section: unknown"), r.res.summary);
});
caseEnd();

caseBegin("procedure-commit-timeout-limit", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("(iv) 208 staged files give the commit 1040000 ms; every other git call keeps 300000", () => {
  const r = runProcedure({ names: NAMES_208, headBefore: SAME, headAfter: OTHER, commit: ok("") });
  assert.strictEqual(r.res.status, "pushed", r.res.summary);
  assert.strictEqual(r.commitCall.timeoutMs, 1040000);
  for (const c of r.calls.filter((x) => x.command === "git" && x !== r.commitCall)) assert.strictEqual(c.timeoutMs, 300000, c.args.join(" "));
  assert.ok(r.logBody.includes("commit timeout limit: 1040s (computed, 208 staged files)"), r.logBody);
});
test("a valid COMMIT_TIMEOUT_SECS sets the commit limit and names it", () => {
  const r = runProcedure({ env: "COMMIT_TIMEOUT_SECS=1800\n", names: NAMES_208, headBefore: SAME, headAfter: SAME, commit: timedOut(MARKERS) });
  assert.strictEqual(r.commitCall.timeoutMs, 1800000);
  assert.ok(r.logBody.includes("commit timeout limit: 1800s (env)"), r.logBody);
  assert.strictEqual(r.res.status, "commit_timeout", r.res.summary);
  assert.ok(r.res.summary.includes("(limit 1800s set by COMMIT_TIMEOUT_SECS)"), r.res.summary);
});
test("(v) an invalid COMMIT_TIMEOUT_SECS is logged with its raw text and ignored", () => {
  const r = runProcedure({ env: "COMMIT_TIMEOUT_SECS=abc\n", names: NAMES_208, headBefore: SAME, headAfter: OTHER, commit: ok("") });
  assert.strictEqual(r.commitCall.timeoutMs, 1040000);
  assert.ok(r.logBody.includes("COMMIT_TIMEOUT_SECS='abc' is not a valid value (an integer 1-86400 without a leading zero); ignored, using the computed commit timeout limit"), r.logBody);
});
// The commit runs past the old fixed 300 s but inside its 1040 s limit: the monotonic fake clock
// jumps 400 s while the commit child "runs", so the elapsed time runGit measures exceeds 300000.
test("C1: a commit that takes 400 s of a 1040 s limit succeeds and goes on to push", () => {
  const clk = offsetClocks();
  try {
    const r = runProcedure({ names: NAMES_208, headBefore: SAME, headAfter: OTHER, commit: ok(""), onCommit: () => { clk.mono += 400000; } });
    assert.strictEqual(r.commitCall.timeoutMs, 1040000);
    assert.notStrictEqual(r.res.status, "commit_timeout", r.res.summary);
    assert.strictEqual(r.res.status, "pushed", r.res.summary);
    assert.ok(r.pushCalls.length > 0, "the commit proceeds to push");
    // runGit itself must measure the 400 s around the spawn and hand it back as elapsedMs.
    handler = () => { clk.mono += 400000; return ok(""); };
    const res = gate().runGit({ entry: {}, anchors: {} }, { worktree_path: TMP }, ["commit", "-m", "x"], [], undefined, undefined, 1040000);
    assert.notStrictEqual(res.timedOut, true, "a 400 s commit inside 1040 s is not a timeout");
    assert.strictEqual(typeof res.elapsedMs, "number", "runGit returns elapsedMs");
    assert.ok(res.elapsedMs >= 400000 && res.elapsedMs < 1040000, `elapsedMs=${res.elapsedMs} must cover the 400 s commit`);
  } finally {
    clk.restore();
  }
});
// The limit is read from the script checkout .env only; a COMMIT_TIMEOUT_SECS in the worker's own
// process environment never reaches it.
function withProcessEnv(value, fn) {
  const had = Object.prototype.hasOwnProperty.call(process.env, "COMMIT_TIMEOUT_SECS");
  const prev = process.env.COMMIT_TIMEOUT_SECS;
  process.env.COMMIT_TIMEOUT_SECS = value;
  try { return fn(); } finally {
    if (had) process.env.COMMIT_TIMEOUT_SECS = prev;
    else delete process.env.COMMIT_TIMEOUT_SECS;
  }
}
test("C2: process.env COMMIT_TIMEOUT_SECS is ignored; the checkout .env value wins", () => {
  withProcessEnv("5", () => {
    const r = runProcedure({ env: "COMMIT_TIMEOUT_SECS=1800\n", names: NAMES_208, headBefore: SAME, headAfter: OTHER, commit: ok("") });
    assert.strictEqual(r.commitCall.timeoutMs, 1800000);
    assert.ok(r.logBody.includes("commit timeout limit: 1800s (env)"), r.logBody);
  });
});
test("C2: process.env COMMIT_TIMEOUT_SECS does not stand in for a .env without the key or with an invalid value", () => {
  withProcessEnv("5", () => {
    for (const env of ["", "COMMIT_TIMEOUT_SECS=abc\n"]) {
      const r = runProcedure({ env, names: NAMES_208, headBefore: SAME, headAfter: OTHER, commit: ok("") });
      assert.strictEqual(r.commitCall.timeoutMs, 1040000, `.env=${JSON.stringify(env)}`);
      assert.ok(r.logBody.includes("commit timeout limit: 1040s (computed, 208 staged files)"), r.logBody);
    }
  });
});
test("a staged count that cannot be read falls back to the 300 s floor", () => {
  const r = runProcedure({ names: err(128, "fatal"), headBefore: SAME, headAfter: OTHER, commit: ok("") });
  assert.strictEqual(r.commitCall.timeoutMs, 300000);
  assert.ok(r.logBody.includes("commit timeout limit: 300s"), r.logBody);
});
caseEnd();

caseBegin("procedure-commit-failure-unchanged", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("(vi) a commit that exits 1 stays staging_check_failed, with no push", () => {
  const r = runProcedure({ names: "a\0", headBefore: SAME, headAfter: SAME, commit: err(1, "pre-commit-section: outbound-scan\nblocked by hook") });
  assert.strictEqual(r.res.status, "staging_check_failed", r.res.summary);
  assert.deepStrictEqual(r.pushCalls, []);
});
test("C5: a commit killed by a signal without timing out (status null, timedOut false) is not a timeout", () => {
  const killed = { status: null, signal: "SIGKILL", timedOut: false, spawnError: null, stdout: "", stderr: "pre-commit-section: outbound-scan\n" };
  const r = runProcedure({ names: "a\0", headBefore: SAME, headAfter: SAME, commit: killed });
  assert.strictEqual(r.res.status, "staging_check_failed", r.res.summary);
  assert.deepStrictEqual(r.pushCalls, []);
});
test("a commit that cannot spawn is not a timeout", () => {
  const r = runProcedure({ names: "a\0", headBefore: SAME, headAfter: SAME, commit: { ...err(null), spawnError: "ENOENT" } });
  assert.strictEqual(r.res.status, "staging_check_failed", r.res.summary);
});
caseEnd();

// The parts below live in feature-2762-commit-timeout/ (file-split.md); F is their fixture surface.
const F = { ok, err, timedOut, SAME, OTHER, NAMES_208, MARKERS, REPO, realSpawn, fixtureDir, runProcedure, procedure, gitInit,
  setHandler: (h) => { handler = h; } };
const parts = require("./feature-2762-commit-timeout/rerun-and-local-env");

caseBegin("procedure-commit-timeout-rerun", "bin/worker-dispatch/workers/commit-push/procedure.js");
parts.runRerun(F);
caseEnd();

caseBegin("commit-timeout-ignores-env-local", "bin/worker-dispatch/workers/commit-push/gate.js");
parts.runLocalEnv(F);
caseEnd();

caseBegin("real-git-commit-timeout", "bin/worker-dispatch/workers/commit-push/procedure.js");
require("./feature-2762-commit-timeout/real-git").run(F);
caseEnd();

const sk = require("./feature-2762-commit-timeout/signal-kill-and-env-count");

caseBegin("procedure-commit-timeout-only-at-limit", "bin/worker-dispatch/workers/commit-push/procedure.js");
sk.runSignalKill(F);
caseEnd();

caseBegin("procedure-env-limit-skips-staged-count", "bin/worker-dispatch/workers/commit-push/procedure.js");
sk.runStagedCount(F);
caseEnd();
