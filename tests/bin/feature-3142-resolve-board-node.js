"use strict";
// Tests: bin/lib/project-board/resolve.js
// Tags: TL2, scope:issue-specific, feature-3142, resolve-project, projects-v2
// #3142 Step 2: resolveBoard(repo, {timeoutMs, noCacheRead}) spawns resolve-board.sh (the bash resolver) and
// carries its four statuses to node as {status, owner, number, projectId, fieldIds, candidates}; spawn
// failure / timeout is fetch-failed; toInternalEnv(board) maps a board onto the _ISSUE_CREATE_INTERNAL_* names.
// TL3 gap (what this test does NOT catch):
// - gh is the #3142 JSON mock on PATH; the live GraphQL API and a real slow network are not exercised.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test, after } = require("node:test");

const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const MOD = path.join(ROOT, "bin", "lib", "project-board", "resolve.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f3142-rb-"));
const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE, PATH: process.env.PATH };
const MOCK_ENV = ["GH_MOCK_LOG", "GH_MOCK_REPO", "GH_MOCK_LINKED_FILE", "GH_MOCK_FAIL", "GH_MOCK_SLEEP"];
after(() => {
  for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  for (const k of MOCK_ENV) delete process.env[k];
  fs.rmSync(TMP, { recursive: true, force: true });
  restore();
});

process.env.HOME = path.join(TMP, "home");
process.env.USERPROFILE = process.env.HOME;
fs.mkdirSync(process.env.HOME);
const bin = path.join(TMP, "mockbin");
fs.mkdirSync(bin);
const mockSh = path.join(__dirname, "feature-3142-board-resolve", "_gh-mock.sh").replace(/\\/g, "/");
fs.writeFileSync(path.join(bin, "gh"), `#!/usr/bin/env bash\nexec bash "${mockSh}" "$@"\n`, { mode: 0o755 });
process.env.PATH = bin + path.delimiter + process.env.PATH;
const LINKED = path.join(TMP, "linked.json");
Object.assign(process.env, { GH_MOCK_LOG: path.join(TMP, "gh.log"), GH_MOCK_REPO: "mockowner/mockrepo", GH_MOCK_LINKED_FILE: LINKED });
for (const k of ["_ISSUE_CREATE_INTERNAL_OWNER", "_ISSUE_CREATE_INTERNAL_PROJECT_NUM", "_ISSUE_CREATE_INTERNAL_PROJECT_ID"]) delete process.env[k];

// linked(more, ...[id, number, owner, closed]) — the repository projectsV2 object the mock answers.
function linked(more, ...boards) {
  const nodes = boards.map(([id, number, login, closed]) => ({ id, number, closed: !!closed, owner: { login } }));
  fs.writeFileSync(LINKED, JSON.stringify({ nodes, pageInfo: { hasNextPage: more, endCursor: null } }));
}
function mod() {
  assert.ok(fs.existsSync(MOD), "bin/lib/project-board/resolve.js not found (implementation missing)");
  return require(MOD);
}
// resolve(opts, env, repo) — resolveBoard's answer; its callers (judge.js, pm-field prepare) are synchronous.
function resolve(opts, env, repo) {
  const m = mod();
  assert.strictEqual(typeof m.resolveBoard, "function", "resolve.js exports no resolveBoard");
  Object.assign(process.env, env || {});
  try {
    const started = Date.now();
    const board = m.resolveBoard(repo || "mockowner/mockrepo", Object.assign({ timeoutMs: 30000, noCacheRead: true }, opts));
    assert.ok(!board || typeof board.then !== "function", "resolveBoard returned a Promise; its callers are sync");
    return { board, elapsed: Date.now() - started };
  } finally {
    for (const k of Object.keys(env || {})) delete process.env[k];
  }
}
const brief = (b) => JSON.stringify(b).slice(0, 400);

caseBegin("statuses-reach-node", "bin/lib/project-board/resolve.js");
test("N1 one open linked board resolves with its project owner, number and field ids", () => {
  linked(false, ["PVT_a", 3, "boardowner"]);
  const { board } = resolve();
  assert.deepStrictEqual([board.status, board.projectId, board.number, board.owner], ["resolved", "PVT_a", 3, "boardowner"], brief(board));
  assert.strictEqual(board.fieldIds.statusFieldId, "PVTSSF_st", brief(board));
  assert.strictEqual(board.fieldIds.todoOptionId, "OPT_todo", brief(board));
  assert.strictEqual(board.fieldIds.sessionIdFieldId, "PVTF_sid", brief(board));
});
test("N2 no open linked board is no-link", () => {
  linked(false, ["PVT_c", 2, "o", true]);
  const { board } = resolve();
  assert.strictEqual(board.status, "no-link", brief(board));
});
test("N3 two open linked boards are ambiguous with both candidates", () => {
  linked(false, ["PVT_a", 3, "o"], ["PVT_b", 4, "o"]);
  const { board } = resolve();
  assert.strictEqual(board.status, "ambiguous", brief(board));
  assert.deepStrictEqual((board.candidates || []).slice().sort(), ["o#3", "o#4"], brief(board));
});
test("N4 a graphql failure is fetch-failed with a reason", () => {
  const { board } = resolve({}, { GH_MOCK_FAIL: "linked" });
  assert.strictEqual(board.status, "fetch-failed", brief(board));
  assert.ok(board.reason, brief(board));
});
caseEnd();

caseBegin("spawn-failure-is-fetch-failed", "bin/lib/project-board/resolve.js");
test("N5 a spawn that outlives timeoutMs is killed and becomes fetch-failed", () => {
  linked(false, ["PVT_a", 3, "o"]);
  const { board, elapsed } = resolve({ timeoutMs: 500 }, { GH_MOCK_SLEEP: "8" });
  assert.strictEqual(board.status, "fetch-failed", brief(board));
  assert.ok(elapsed < 6000, `not killed at the timeout: ${elapsed} ms`);
});
test("N5b an invalid repo (non-zero resolver exit, not a timeout) is fetch-failed with a reason", () => {
  linked(false, ["PVT_a", 3, "o"]);
  // A repo with no owner/ part cannot be resolved: node must answer fetch-failed with a reason, not throw.
  const { board } = resolve({}, {}, "not-a-repo");
  assert.strictEqual(board.status, "fetch-failed", brief(board));
  assert.ok(typeof board.reason === "string" && board.reason.length > 0, brief(board));
});
test("N5c a resolver that exits 0 with no status line is fetch-failed with a reason", () => {
  // resolve.js binds spawnSync at load, so a fresh copy is loaded under a stubbed spawnSync.
  const cp = require("node:child_process");
  const real = cp.spawnSync;
  delete require.cache[require.resolve(MOD)];
  cp.spawnSync = () => ({ status: 0, signal: null, stdout: "", stderr: "" });
  let board;
  try {
    const m = mod();
    assert.doesNotThrow(() => { board = m.resolveBoard("mockowner/mockrepo", { timeoutMs: 5000 }); });
  } finally {
    cp.spawnSync = real;
    delete require.cache[require.resolve(MOD)];
  }
  assert.strictEqual(board.status, "fetch-failed", brief(board));
  assert.ok(typeof board.reason === "string" && board.reason.length > 0, brief(board));
});
caseEnd();

caseBegin("to-internal-env", "bin/lib/project-board/resolve.js");
test("N6 toInternalEnv maps a resolved board onto the resolver's short-circuit env names", () => {
  linked(false, ["PVT_a", 3, "boardowner"]);
  const { board } = resolve();
  const m = mod();
  assert.strictEqual(typeof m.toInternalEnv, "function", "resolve.js exports no toInternalEnv");
  const env = m.toInternalEnv(board);
  assert.deepStrictEqual(
    [env._ISSUE_CREATE_INTERNAL_OWNER, String(env._ISSUE_CREATE_INTERNAL_PROJECT_NUM), env._ISSUE_CREATE_INTERNAL_PROJECT_ID,
      env._ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID, env._ISSUE_CREATE_INTERNAL_SESSION_ID_FIELD_ID],
    ["boardowner", "3", "PVT_a", "PVTSSF_st", "PVTF_sid"], brief(env));
});
caseEnd();
