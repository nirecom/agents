"use strict";
// tests/bin/feat-pm-forge-failure.js
// Tests: bin/lib/forge-issue-links.js, bin/lib/pm-state/ancestry.js, bin/lib/forge-failure.js
// Tags: TL2, scope:common, issue-2942, issue-3168, pm-session, forge, graphql, retry
// #2942 S3: gh api graphql exits 1 when one issue of a batch does not exist but still prints data
// plus errors[].type NOT_FOUND. runChunk reads data on exit 1, marks only that slot issue_not_found
// and resolves the rest (classifyGraphqlResult); RETRYABLE holds only network and auth failures.
// A fake gh (generated into a tmp bin on PATH; the code spawns `bash -c 'exec gh'`) prints the response.
// TL3 gap: the exact stdout / stderr / exit code of a real gh against GitHub (NOT_FOUND batch, expired
// token, offline) is mirrored by hand here, not recorded live; a gh format change is caught only live.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-forge-fail-"));
const bin = path.join(tmp, "bin");
fs.mkdirSync(bin);
const OUT = path.join(tmp, "stdout.json");
const LOG = path.join(tmp, "calls.log");
fs.writeFileSync(path.join(bin, "gh"), [
  "#!/bin/bash",
  "cat >/dev/null",
  "echo call >>\"$FAKE_GH_LOG\"",
  "cat \"$FAKE_GH_OUT\"",
  "[ -n \"$FAKE_GH_ERR\" ] && printf '%s\\n' \"$FAKE_GH_ERR\" >&2",
  "exit \"${FAKE_GH_EXIT:-0}\"",
  "",
].join("\n"), { mode: 0o755 });
const PATH_KEY = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") || "PATH";
const savedEnv = { path: process.env[PATH_KEY] };
process.env[PATH_KEY] = `${bin}${path.delimiter}${process.env[PATH_KEY]}`;
process.env.FAKE_GH_OUT = fwdSafe(OUT);
process.env.FAKE_GH_LOG = fwdSafe(LOG);
after(() => {
  process.env[PATH_KEY] = savedEnv.path;
  for (const k of ["FAKE_GH_OUT", "FAKE_GH_LOG", "FAKE_GH_ERR", "FAKE_GH_EXIT"]) delete process.env[k];
  fs.rmSync(tmp, { recursive: true, force: true });
  restore();
});
function fwdSafe(p) { return String(p).replace(/\\/g, "/"); }

const links = () => P.load("bin/lib/forge-issue-links.js");
const anc = () => P.load("bin/lib/pm-state/ancestry.js");
const REPO = "acme/widgets";
const ref = (n) => ({ repo: REPO, number: n });
const key = (n) => `${REPO}#${n}`;
const node = (n, parent = null, labels = []) => ({ number: n, repository: { nameWithOwner: REPO }, labels: { nodes: labels.map((name) => ({ name })), pageInfo: { hasNextPage: false } }, parent });

// gh(stdout, exit, stderr) -> fetchAncestorChains([#1, #2, #3]) against that canned response.
function fetchWith(body, exit, stderr = "") {
  fs.writeFileSync(OUT, body === null ? "" : JSON.stringify(body));
  process.env.FAKE_GH_EXIT = String(exit);
  process.env.FAKE_GH_ERR = stderr;
  return links().fetchAncestorChains([ref(1), ref(2), ref(3)], { timeoutMs: 30000 });
}
const PARTIAL = (errType) => ({
  data: { r0: { i0: node(1), i1: null, i2: node(3, node(10, null, ["meta"])) } },
  errors: [{ type: errType, path: ["r0", "i1"], locations: [{ line: 1, column: 1 }], message: "Could not resolve to an Issue with the number of 2." }],
});

caseBegin("forge-chunk-not-found-slot", "bin/lib/forge-issue-links.js");
test("exit 1 with data + NOT_FOUND on one slot -> only that slot is issue_not_found", () => {
  const r = fetchWith(PARTIAL("NOT_FOUND"), 1, "gh: Could not resolve to an Issue with the number of 2.");
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.deepStrictEqual(r.results[key(2)], { ok: false, reason: "issue_not_found" });
  assert.deepStrictEqual(r.results[key(1)], { ok: true, chain: [] });
  assert.deepStrictEqual(r.results[key(3)], { ok: true, chain: [{ number: 10, repo: REPO, meta: true }] });
});
test("the same response read twice gives the same result (idempotent read)", () => {
  const a = fetchWith(PARTIAL("NOT_FOUND"), 1);
  const b = fetchWith(PARTIAL("NOT_FOUND"), 1);
  assert.deepStrictEqual(a, b);
});
test("classifyGraphqlResult is exported as a function", () => {
  assert.strictEqual(typeof links().classifyGraphqlResult, "function");
});
caseEnd();

caseBegin("forge-chunk-other-errors", "bin/lib/forge-issue-links.js");
for (const errType of ["FORBIDDEN", "INTERNAL", "RATE_LIMITED"]) {
  test(`exit 1 with data + ${errType} on a slot -> that slot is never read as issue_not_found`, () => {
    const r = fetchWith(PARTIAL(errType), 1);
    if (r.ok) assert.notStrictEqual((r.results[key(2)] || {}).reason, "issue_not_found", JSON.stringify(r));
    else assert.notStrictEqual(r.reason, "issue_not_found", JSON.stringify(r));
  });
}
test("exit 1 with no data (auth failure) -> a whole-call failure, not issue_not_found", () => {
  const r = fetchWith(null, 4, "To get started with GitHub CLI, please run:  gh auth login");
  assert.strictEqual(r.ok, false, JSON.stringify(r));
  assert.notStrictEqual(r.reason, "issue_not_found");
});
caseEnd();

// ancestry over the real fetchAncestorChains and the fake gh: retryability is decided in ancestry only.
const holder = { tag: "PM-x", session_id: P.uuid(0x29423001), issues: [] };
function holdersVia(body, exit, stderr) {
  fs.writeFileSync(OUT, body === null ? "" : JSON.stringify(body));
  process.env.FAKE_GH_EXIT = String(exit);
  process.env.FAKE_GH_ERR = stderr || "";
  const a = anc().createAncestry({ fetchAncestorChains: links().fetchAncestorChains });
  a.prefetch([ref(1), ref(2), ref(3)]);
  return [1, 2, 3].map((n) => a.holdersOf(ref(n), [holder]));
}
caseBegin("ancestry-retryable-classes", "bin/lib/pm-state/ancestry.js");
test("a NOT_FOUND slot is issue_not_found and not retryable; its batch peers resolve", () => {
  const [h1, h2, h3] = holdersVia(PARTIAL("NOT_FOUND"), 1);
  assert.deepStrictEqual([h1.ok, h3.ok], [true, true], JSON.stringify([h1, h3]));
  assert.deepStrictEqual({ ok: h2.ok, reason: h2.reason, retryable: h2.retryable }, { ok: false, reason: "issue_not_found", retryable: false });
});
for (const [label, exit, stderr] of [
  ["auth failure", 4, "To get started with GitHub CLI, please run:  gh auth login"],
  ["HTTP 401", 1, "HTTP 401: Bad credentials (https://api.github.com/graphql)"],
  ["network failure", 1, "error connecting to api.github.com"],
]) {
  test(`${label} -> ok:false and retryable`, () => {
    for (const h of holdersVia(null, exit, stderr)) {
      assert.strictEqual(h.ok, false, JSON.stringify(h));
      assert.strictEqual(h.retryable, true, JSON.stringify(h));
      assert.ok(anc().RETRYABLE.has(h.reason), h.reason);
    }
  });
}
test("RETRYABLE excludes issue_not_found and parse_failed, keeps timeout", () => {
  const R = anc().RETRYABLE;
  assert.strictEqual(R.has("issue_not_found"), false);
  assert.strictEqual(R.has("parse_failed"), false, "a malformed answer is not a network or auth failure");
  assert.strictEqual(R.has("timeout"), true);
});
test("unparsable stdout on exit 0 -> parse_failed, not retryable", () => {
  fs.writeFileSync(OUT, "not json");
  process.env.FAKE_GH_EXIT = "0";
  process.env.FAKE_GH_ERR = "";
  const a = anc().createAncestry({ fetchAncestorChains: links().fetchAncestorChains });
  const h = a.holdersOf(ref(1), [holder]);
  assert.deepStrictEqual({ ok: h.ok, reason: h.reason, retryable: h.retryable }, { ok: false, reason: "parse_failed", retryable: false });
});
caseEnd();

// #3152: three time-out classes (bin/lib/forge-failure.js) — budget-exhausted before gh runs, timeout when gh is
// killed, spawn-failed when gh cannot start — and the next-action wording keyed by reason. gh is injected through
// opts.spawnSync, so the fake gh on PATH must see no call.
const FF = () => P.load("bin/lib/forge-failure.js");
const kill = (code) => Object.assign(new Error(code), { code });
const ghLog = () => (fs.existsSync(LOG) ? fs.readFileSync(LOG, "utf8").split("\n").filter(Boolean).length : 0);
function injected(answer) {
  const calls = [];
  const spawnSync = (cmd, args, opts) => { calls.push({ cmd, args, opts }); return answer(calls.length - 1, opts); };
  return { calls, spawnSync };
}
const okAnswer = () => ({ status: 0, signal: null, stdout: JSON.stringify(PARTIAL("NOT_FOUND")), stderr: "" });

caseBegin("forge-failure-three-classes", "bin/lib/forge-issue-links.js");
test("classifyGhSpawn: a kill or a signal is timeout, any other spawn error is spawn-failed, an exit is not its business", () => {
  const F = FF();
  assert.strictEqual(typeof F.classifyGhSpawn, "function", "bin/lib/forge-failure.js does not export classifyGhSpawn");
  assert.strictEqual(F.classifyGhSpawn({ error: kill("ETIMEDOUT"), signal: "SIGTERM", status: null }), "timeout");
  assert.strictEqual(F.classifyGhSpawn({ error: null, signal: "SIGKILL", status: null }), "timeout");
  assert.strictEqual(F.classifyGhSpawn({ error: kill("ENOENT"), signal: null, status: null }), "spawn-failed");
  assert.strictEqual(F.classifyGhSpawn({ error: null, signal: null, status: 0 }), null);
  assert.strictEqual(F.classifyGhSpawn({ error: null, signal: null, status: 1 }), null);
});
test("classifyGraphqlResult tells a killed gh (timeout) from a gh that never started (spawn-failed)", () => {
  const L = links();
  assert.deepStrictEqual(L.classifyGraphqlResult({ error: kill("ETIMEDOUT"), signal: "SIGTERM" }, [], () => null), { ok: false, reason: "timeout" });
  assert.deepStrictEqual(L.classifyGraphqlResult({ error: kill("ENOENT"), signal: null }, [], () => null), { ok: false, reason: "spawn-failed" });
});
test("batchedGraphql: a deadline already past, or less left than minCallMs, is budget-exhausted and spawns nothing", () => {
  const before = ghLog();
  for (const opts of [{ deadlineAt: Date.now() - 1 }, { deadlineAt: Date.now() + 300, minCallMs: 400 }]) {
    const g = injected(okAnswer);
    const r = links().fetchAncestorChains([ref(1)], Object.assign({ spawnSync: g.spawnSync }, opts));
    assert.deepStrictEqual(r, { ok: false, reason: "budget-exhausted" }, JSON.stringify(opts));
    assert.strictEqual(g.calls.length, 0, `gh ran with ${JSON.stringify(opts)}`);
  }
  assert.strictEqual(ghLog(), before, "the gh on PATH was spawned");
});
test("batchedGraphql runs gh through opts.spawnSync, chunked by opts.chunkSize, with the remaining time as its timeout", () => {
  const before = ghLog();
  const g = injected(okAnswer);
  const r = links().fetchAncestorChains([ref(1), ref(2), ref(3)], { spawnSync: g.spawnSync, chunkSize: 2, deadlineAt: Date.now() + 5000, minCallMs: 400 });
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.strictEqual(g.calls.length, 2, "3 refs at chunkSize 2 take two gh calls");
  for (const c of g.calls) {
    assert.ok(c.opts.timeout > 0 && c.opts.timeout <= 5000, `timeout ${c.opts.timeout}`);
    assert.ok(/^query\b/.test(JSON.parse(c.opts.input).query.trim()), "the GraphQL query goes in on stdin");
  }
  assert.strictEqual(ghLog(), before, "the gh on PATH was spawned");
});
test("a gh killed or unable to start reaches the caller as timeout / spawn-failed", () => {
  const killed = links().fetchAncestorChains([ref(1)], { spawnSync: injected(() => ({ status: null, signal: "SIGTERM", error: kill("ETIMEDOUT") })).spawnSync });
  assert.deepStrictEqual(killed, { ok: false, reason: "timeout" });
  const absent = links().fetchAncestorChains([ref(1)], { spawnSync: injected(() => ({ status: null, signal: null, error: kill("ENOENT") })).spawnSync });
  assert.deepStrictEqual(absent, { ok: false, reason: "spawn-failed" });
});
caseEnd();

caseBegin("forge-failure-retryable-sets", "bin/lib/pm-state/ancestry.js");
test("RETRYABLE / NOT_RETRYABLE come from forge-failure.js and ancestry holds no copy of its own", () => {
  const F = FF();
  const R = F.RETRYABLE;
  const N = F.NOT_RETRYABLE;
  assert.ok(R instanceof Set && N instanceof Set, "forge-failure.js does not export RETRYABLE / NOT_RETRYABLE as Sets");
  assert.deepStrictEqual([...R].sort(), ["budget-exhausted", "gh_exec_failed", "spawn-failed", "timeout"]);
  for (const k of ["pm-field-ambiguous", "pm-field-truncated", "cycle", "depth-cap", "parse_failed", "sub-issue-overflow", "sub-issue-depth-cap", "issue_not_found", "repo-unknown"]) assert.ok(N.has(k), `NOT_RETRYABLE lacks ${k}`);
  assert.ok([...R].every((k) => !N.has(k)), "a reason is in both sets");
  assert.deepStrictEqual([...anc().RETRYABLE].sort(), [...R].sort(), "ancestry.js RETRYABLE differs from forge-failure.js");
});
test("ancestry reads budget-exhausted and spawn-failed as retryable, like the old timeout", () => {
  for (const reason of ["budget-exhausted", "spawn-failed", "timeout"]) {
    const a = anc().createAncestry({ fetchAncestorChains: () => ({ ok: false, reason }) });
    const h = a.holdersOf(ref(1), [holder]);
    assert.deepStrictEqual({ ok: h.ok, reason: h.reason, retryable: h.retryable }, { ok: false, reason, retryable: true });
  }
});
caseEnd();

caseBegin("forge-failure-next-action", "bin/lib/forge-issue-links.js");
const DEFAULT_ACTION = /retry when the forge is back/i;
test("nextActionOf gives each retryable reason its own next step", () => {
  const F = FF();
  assert.strictEqual(typeof F.nextActionOf, "function", "bin/lib/forge-failure.js does not export nextActionOf");
  const texts = ["budget-exhausted", "timeout", "spawn-failed", "gh_exec_failed"].map((r) => F.nextActionOf(r));
  for (const t of texts) assert.ok(typeof t === "string" && t.length > 0, JSON.stringify(texts));
  assert.strictEqual(new Set(texts).size, 4, `the four retryable reasons share a wording: ${JSON.stringify(texts)}`);
  assert.match(F.nextActionOf("gh_exec_failed"), DEFAULT_ACTION);
  assert.match(F.nextActionOf("spawn-failed"), /gh auth status/);
  assert.match(F.nextActionOf("budget-exhausted"), /fewer|smaller|reduce/i);
});
test("nextActionOf: NOT_RETRYABLE reasons never ask for a retry; issue_not_found / repo-unknown point at the reference", () => {
  const F = FF();
  const ref1 = F.nextActionOf("issue_not_found");
  assert.strictEqual(F.nextActionOf("repo-unknown"), ref1);
  assert.match(ref1, /owner\/repo#N/);
  const board = ["pm-field-ambiguous", "pm-field-truncated", "cycle", "depth-cap", "parse_failed", "sub-issue-overflow", "sub-issue-depth-cap"].map((r) => F.nextActionOf(r));
  for (const t of [ref1].concat(board)) {
    assert.ok(typeof t === "string" && t.length > 0);
    assert.doesNotMatch(t, DEFAULT_ACTION, `a non-retryable reason asks for a retry: ${t}`);
  }
  assert.ok(board.every((t) => t !== ref1), "the board / hierarchy group reuses the reference wording");
});
test("nextActionOf: an unknown reason gets today's wording, never undefined; the part after ':' is ignored", () => {
  const F = FF();
  for (const r of ["missing", "failed", "no-such-reason", "", undefined]) assert.match(String(F.nextActionOf(r)), DEFAULT_ACTION, String(r));
  assert.strictEqual(F.nextActionOf("timeout: o/r#5"), F.nextActionOf("timeout"));
});
test("nextActionOf(null) gets the default wording", () => {
  assert.match(String(FF().nextActionOf(null)), DEFAULT_ACTION);
});
// #3168: the gate (outside the hook) also emits budget-exhausted, so the sentence takes a neutral form without the hook as subject.
test("nextActionOf(budget-exhausted) does not name the hook (a neutral sentence that reads for both gate and hook)", () => {
  const t = String(FF().nextActionOf("budget-exhausted"));
  assert.doesNotMatch(t, /\bhook\b/i, `the budget-exhausted action names the hook: ${t}`);
  assert.match(t, /fewer|smaller|reduce/i, t);
});
caseEnd();

caseBegin("forge-failure-no-spawn-result", "bin/lib/forge-issue-links.js");
test("classifyGhSpawn: no spawn result at all (a spawnSync that threw) is spawn-failed", () => {
  const F = FF();
  assert.strictEqual(F.classifyGhSpawn(null), "spawn-failed");
  assert.strictEqual(F.classifyGhSpawn(undefined), "spawn-failed");
  assert.deepStrictEqual(links().classifyGraphqlResult(null, [], () => null), { ok: false, reason: "spawn-failed" });
});
caseEnd();
