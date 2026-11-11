"use strict";
// tests/bin/feature-2924-issue-snapshot-cache.js
// Tests: bin/issue-snapshot
// Tags: TL2, bin, issue-snapshot, gh-stub, cache, gh-budget, scope:issue-specific, dup-group-keep:size-hard-limit
// lang-check: ignore — the assertions match plan-language marker values and plan text the code under test emits (functional data).
// #2924 cache-trust and gh-budget cases of bin/issue-snapshot, split from feature-2924-issue-snapshot.js
// (that file sits at the code HARD limit). Same gh stub: a node copy named gh plus a --require preload
// that logs argv; the preload also runs in the CLI's own node process, where GH_STUB_BUDGET_SKEW moves
// Date.now past GH_BUDGET_MS after the first gh spawn, so the budget path runs without a 90 s wait.
// TL3 gap (what this test does NOT catch): a real network hang consuming the budget in wall time.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2924-snapc-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "issue-snapshot");
const CD = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "control-dir.js"));
const F = require("../hooks/feature-2304-inheritance-state-copy/fixture");

// --- gh stub (minimum copy of feature-2924-issue-snapshot.js's) + the budget clock skew ----------
const STUB_DIR = path.join(TMP, "stub-bin");
fs.mkdirSync(STUB_DIR);
for (const name of process.platform === "win32" ? ["gh.exe"] : ["gh"]) {
  const dst = path.join(STUB_DIR, name);
  try { fs.linkSync(process.execPath, dst); } catch (_) { fs.copyFileSync(process.execPath, dst); }
  fs.chmodSync(dst, 0o755);
}
const PRELOAD = path.join(STUB_DIR, "gh-stub-preload.js");
fs.writeFileSync(PRELOAD, [
  "const path = require('path'); const fs = require('fs');",
  "const base = path.basename(process.execPath).replace(/\\.exe$/i, '').toLowerCase();",
  "if (base === 'gh') {",
  "  const a = process.argv.slice(1); if (a.length) a[0] = path.basename(a[0]);",
  "  if (process.env.GH_STUB_LOG) fs.appendFileSync(process.env.GH_STUB_LOG, JSON.stringify(a) + '\\n');",
  "  const num = a[2]; const ri = a.indexOf('--repo'); const repo = ri >= 0 ? a[ri + 1] : 'local';",
  "  const file = path.join(process.env.GH_STUB_DATA, repo.replace('/', '__') + '-' + num + '.json');",
  "  if (!fs.existsSync(file)) { fs.writeSync(2, 'GraphQL: Could not resolve to an issue\\n'); process.exit(1); }",
  "  const full = JSON.parse(fs.readFileSync(file, 'utf8'));",
  "  const ji = a.indexOf('--json'); const fields = ji >= 0 ? a[ji + 1].split(',') : Object.keys(full);",
  "  const raw = fields.join(',') === 'updatedAt' ? full.__rawProbe : full.__rawFull;",
  "  if (typeof raw === 'string') { fs.writeSync(1, raw); process.exit(0); }",
  "  const out = {}; for (const k of fields) out[k] = full[k];",
  "  fs.writeSync(1, JSON.stringify(out));",
  "  process.exit(0);",
  "} else if (process.env.GH_STUB_BUDGET_SKEW) {",
  "  const cp = require('child_process'); const orig = cp.spawnSync; const realNow = Date.now; let skew = 0;",
  "  Date.now = () => realNow() + skew;",
  "  cp.spawnSync = function (cmd, ...rest) {",
  "    const r = orig.call(this, cmd, ...rest);",
  "    if (cmd === 'gh') skew = Number(process.env.GH_STUB_BUDGET_SKEW);",
  "    return r;",
  "  };",
  "}",
].join("\n"));

const DATA_DIR = path.join(TMP, "gh-data");
fs.mkdirSync(DATA_DIR);
const NEUTRAL = path.join(TMP, "cwd");
fs.mkdirSync(NEUTRAL);

function issueFixture(num, o) {
  const data = Object.assign({
    title: `title ${num}`,
    url: `https://github.example.com/local/issues/${num}`,
    body: `body of ${num}`,
    comments: [{ author: { login: "alice" }, createdAt: "2026-01-02T00:00:00Z", body: `comment on ${num}` }],
    updatedAt: "2026-01-01T00:00:00Z",
  }, o || {});
  fs.writeFileSync(path.join(DATA_DIR, `local-${num}.json`), JSON.stringify(data));
}

const pathKey = (env) => Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";

let runNo = 0;
function run(sid, extraEnv) {
  runNo += 1;
  const log = path.join(TMP, `gh-${runNo}.log`);
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const pk = pathKey(env);
  env[pk] = STUB_DIR + path.delimiter + (env[pk] || "");
  env.NODE_OPTIONS = `--require "${PRELOAD.replace(/\\/g, "/")}"`;
  env.GH_STUB_LOG = log;
  env.GH_STUB_DATA = DATA_DIR;
  Object.assign(env, extraEnv || {});
  const started = Date.now();
  const r = spawnSync(process.execPath, [CLI, "--session", sid], { cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  const calls = fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  return {
    code: r.status, stdout: r.stdout || "", stderr: r.stderr || "", calls, ms: Date.now() - started,
    show: `rc=${r.status} err=${r.error ? r.error.message : ""} stdout=${String(r.stdout).slice(0, 300)} stderr=${String(r.stderr).slice(0, 300)}`,
  };
}

function seedSession(sid, issueLines) {
  F.seedDownstream(sid);
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "plan-artifact-path"), "--step", "clarify_intent", "--session", sid],
    { cwd: NEUTRAL, encoding: "utf8", timeout: 30000 });
  assert.strictEqual(r.status, 0, `plan-artifact-path failed: ${r.stderr}`);
  const p = r.stdout.trim();
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, `# Intent\n\n## Issues\n\n${issueLines.join("\n")}\n\n## Goal\n\nx\n`);
}

// A successful run prints one absolute path line naming an issues.md inside its untrusted-data frame.
function snapshotOf(r) {
  assert.strictEqual(r.code, 0, r.show);
  assert.match(r.stdout, /^[^\r\n]+\r?\n$/, `stdout must be one line: ${r.show}`);
  const p = r.stdout.trim();
  assert.ok(path.isAbsolute(p) && path.basename(p) === "issues.md" && fs.existsSync(p), `bad path: ${p}`);
  const text = fs.readFileSync(p, "utf8");
  const lines = text.replace(/\n$/, "").split("\n");
  const s = lines.indexOf("[ISSUE SNAPSHOT START]");
  assert.ok(s > 0 && lines.indexOf("[ISSUE SNAPSHOT END]") === lines.length - 1, `frame broken:\n${text}`);
  return { path: p, text };
}

const fieldsOf = (call) => { const i = call.indexOf("--json"); return i >= 0 ? call[i + 1].split(",").sort().join(",") : ""; };
const FULL = ["body", "comments", "title", "updatedAt", "url"].join(",");
const callsFor = (r, num) => r.calls.filter((c) => c[0] === "issue" && c[1] === "view" && c[2] === String(num));
const cacheFileOf = (sid) => path.join(CD.getSessionControlDir(sid), "issue-snapshot.json");
function plantCache(sid, record, num = 301) {
  const file = cacheFileOf(sid);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ issues: { [`#${num}`]: record } }));
}

const CANARY = "WRONGSHAPE-CANARY-2924";
// updatedAt equals the stub's, so a trusted record is a cache hit and is rendered as-is.
const UPD = "2026-01-01T00:00:00Z";
const base = { repo: null, number: 301, updatedAt: UPD, title: `t ${CANARY}`, url: "https://github.example.com/local/issues/301",
  body: `${CANARY} body`, comments: [{ author: { login: "c" }, createdAt: UPD, body: `${CANARY} comment` }] };
issueFixture(301, { body: "fresh body of 301" });

caseBegin("wrong-shape-cache-record-is-refetched", "bin/issue-snapshot");
const SHAPES = [
  ["comments-not-array", { comments: `${CANARY} comments` }, "reject"],
  ["updatedAt-not-string", { updatedAt: 20260101 }, "reject"],
  ["updatedAt-missing", { updatedAt: undefined }, "reject"],
  ["body-not-string", { body: { text: CANARY } }, "reject"],
  ["title-not-string", { title: [CANARY] }, "reject"],
  ["url-not-string", { url: { href: CANARY } }, "reject"],
  ["record-is-array", null, "reject"],
  ["valid-shape-control", {}, "accept"],
  ["body-absent-is-valid", { body: undefined, title: CANARY }, "accept"],
];
for (const [name, patch, want] of SHAPES) {
  test(`${name} → ${want === "accept" ? "trusted cache hit" : "refetched, never rendered"}`, () => {
    const sid = `f2924-snapc-shape-${name.toLowerCase()}`;
    seedSession(sid, ["- #301: shape"]);
    plantCache(sid, patch === null ? [base] : Object.assign({}, base, patch));
    const r = run(sid);
    const snap = snapshotOf(r);
    const fields = callsFor(r, 301).map(fieldsOf);
    if (want === "accept") {
      assert.deepStrictEqual(fields, ["updatedAt"], `a valid record must be a cache hit: ${JSON.stringify(r.calls)}`);
      assert.ok(snap.text.includes(CANARY), `control: the trusted record was not rendered (vacuous canary):\n${snap.text}`);
      return;
    }
    assert.ok(fields.includes(FULL), `no full fetch for a wrong-shape record: ${JSON.stringify(r.calls)}`);
    assert.ok(!snap.text.includes(CANARY), `wrong-shape cache content reached issues.md:\n${snap.text}`);
    assert.match(snap.text, /^> fresh body of 301$/m, snap.text);
    assert.ok(!snap.text.includes("(updatedAt 未確認)"), snap.text);
    const rec = JSON.parse(fs.readFileSync(cacheFileOf(sid), "utf8")).issues["#301"];
    assert.ok(rec && typeof rec.updatedAt === "string" && Array.isArray(rec.comments) && !JSON.stringify(rec).includes(CANARY),
      `cache not rebuilt with the fetched record: ${JSON.stringify(rec)}`);
  });
}
caseEnd();

caseBegin("gh-budget-exhausted-degrades-remaining-issues", "bin/issue-snapshot");
test("past GH_BUDGET_MS no further gh call is made: cached issues render (updatedAt 未確認), uncached read `snapshot なし (gh-budget)`", () => {
  const sid = "f2924-snapc-budget";
  issueFixture(311, { body: "body of 311" });
  issueFixture(312, { body: "cached body of 312" });
  issueFixture(313, { body: "body of 313" });
  seedSession(sid, ["- #311: first", "- #312: cached"]);
  snapshotOf(run(sid));
  seedSession(sid, ["- #311: first", "- #312: cached", "- #313: uncached"]);
  const r = run(sid, { GH_STUB_BUDGET_SKEW: "1000000" });
  const snap = snapshotOf(r);
  assert.deepStrictEqual(r.calls.map((c) => [c[2], fieldsOf(c)]), [["311", "updatedAt"]], `gh called past the budget: ${JSON.stringify(r.calls)}`);
  const lines = snap.text.split("\n");
  const h311 = lines.find((l) => l.startsWith("### #311 "));
  const h312 = lines.find((l) => l.startsWith("### #312 "));
  assert.ok(h311 && !h311.includes("(updatedAt 未確認)"), `#311 was verified before the budget ran out:\n${snap.text}`);
  assert.ok(h312 && h312.includes("(updatedAt 未確認)"), `#312 must fall back to the cache:\n${snap.text}`);
  assert.match(snap.text, /^> cached body of 312$/m, snap.text);
  assert.ok(lines.includes("#313: snapshot なし (gh-budget)"), snap.text);
  assert.ok(r.ms < 30000, `no hang expected, took ${r.ms} ms`);
});
test("control: without the clock skew the same session makes a gh call for every issue", () => {
  const r = run("f2924-snapc-budget");
  snapshotOf(r);
  for (const num of [311, 312, 313]) assert.ok(callsFor(r, num).length > 0, `#${num}: ${JSON.stringify(r.calls)}`);
});
caseEnd();

// gh exits 0 but prints valid JSON that is not an object: a gh failure like any other, never a crash.
caseBegin("gh-non-object-json-degrades-like-gh-failure", "bin/issue-snapshot");
const UNVERIFIED_MARK = "(updatedAt 未確認)";
const cachedRec = (num) => Object.assign({}, base, { number: num, url: `https://github.example.com/local/issues/${num}` });
const NON_OBJECT = [
  // [name, num, stub fixture, cached]
  ["probe-null-with-cache", 321, { __rawProbe: "null", __rawFull: "null" }, true],
  ["probe-null-no-cache", 322, { __rawProbe: "null", __rawFull: "null" }, false],
  ["full-array-with-cache", 323, { updatedAt: "2026-02-01T00:00:00Z", __rawFull: "[]" }, true],
  ["full-array-no-cache", 324, { updatedAt: "2026-02-01T00:00:00Z", __rawFull: "[]" }, false],
  ["full-number-with-cache", 325, { updatedAt: "2026-02-01T00:00:00Z", __rawFull: "42" }, true],
  ["full-number-no-cache", 326, { updatedAt: "2026-02-01T00:00:00Z", __rawFull: "42" }, false],
];
for (const [name, num, fixture, cached] of NON_OBJECT) {
  test(`${name} → exit 0, ${cached ? `cached record rendered ${UNVERIFIED_MARK}` : "`snapshot なし (gh-bad-json)`"}`, () => {
    const sid = `f2924-snapc-nonobj-${name}`;
    issueFixture(num, fixture);
    seedSession(sid, [`- #${num}: non-object json`]);
    if (cached) plantCache(sid, cachedRec(num), num);
    const r = run(sid);
    const snap = snapshotOf(r);
    const lines = snap.text.split("\n");
    if (!cached) {
      assert.ok(lines.includes(`#${num}: snapshot なし (gh-bad-json)`), `expected the gh-bad-json marker:\n${snap.text}`);
      return;
    }
    const head = lines.find((l) => l.startsWith(`### #${num} `));
    assert.ok(head && head.includes(UNVERIFIED_MARK), `cached record must render unverified:\n${snap.text}`);
    assert.ok(snap.text.includes(`${CANARY} body`), `cached body not rendered:\n${snap.text}`);
  });
}
caseEnd();
