"use strict";
// Tests: hooks/lib/audit-ledger.js, hooks/lib/branch-diff.js, hooks/lib/supervisor-state-writer/audit-run.js, hooks/workflow-gate/user-verified-audit.js
// Tags: TL1, scope:issue-specific, supervisor, audit, scope-drift
// #2448: the declared_files snapshot keeps plan_files (first path token per "Files to modify"
// line) and files (plan_files inside the diff, with diff_scope empty|unavailable|scoped).
// Scope drift is judged against plan_files, so a file a line only mentions is drift.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2448-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
for (const k of ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL", "WORKFLOW_SESSION_ID"]) delete process.env[k];
process.on("exit", () => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const ROOT = path.resolve(__dirname, "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));
const BD = mod("hooks/lib/branch-diff.js");
const LEDGER = mod("hooks/lib/audit-ledger.js");
const AR = mod("hooks/lib/supervisor-state-writer/audit-run.js");
const UVA = mod("hooks/workflow-gate/user-verified-audit.js");
const writer = mod("hooks/lib/supervisor-state-writer");
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const show = (v) => JSON.stringify(v);

const DETAIL = [
  "# Detail", "", "## Files to modify", "",
  "- `src/a.js` — edit; mirrors the pattern in `src/ref.js`",
  "- `src/b.js` — new helper", "- `docs/c.md` — document it", "",
  "## Risks", "", "- `src/other.js` may also need a look", "",
].join("\n");

let n = 0;
const nextSid = (tag) => `f2448-${tag}-${++n}`;
function writeDetail(sid, text) {
  for (const a of ["intent", "outline"]) fs.writeFileSync(path.join(PLANS, `${sid}-${a}.md`), `# ${a}\n\nfixture ${sid}\n`);
  fs.writeFileSync(path.join(PLANS, `${sid}-detail.md`), text);
}
const git = (dir, ...args) => spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
function makeRepo(tag) {
  const repo = path.join(TMP, `repo-${tag}`);
  gitInit(repo);
  git(repo, "checkout", "-q", "-b", "main");
  for (const f of ["src/a.js", "src/b.js", "src/ref.js", "docs/c.md"]) {
    fs.mkdirSync(path.dirname(path.join(repo, f)), { recursive: true });
    fs.writeFileSync(path.join(repo, f), `${f}\n`);
  }
  git(repo, "add", "-A");
  git(repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "init");
  git(repo, "checkout", "-q", "-b", "feature");
  return repo;
}
const audit = (sid) => writer.readState(sid).audit;
const arm = (sid, tr, cwd) => AR.armAuditRun(sid, { tr_ids: [tr], cause: tr === "TR3" ? "pre-confirm:detail" : "step-complete:write_code", cwd, plans_dir: PLANS, plan_session_id: sid });
const settle = (sid, runId) => AR.finalizeAuditRun(sid, { audit_run_id: runId, verdict: "CONTINUE", verdict_summary: "ok" });

caseBegin("parse-takes-the-first-path-token-per-line", "hooks/lib/branch-diff.js");
test("(a)(b) parseDetailFilesToModify reads only the first path token of each Files to modify line", () => {
  const cases = [
    { name: "reference-in-description", input: "## Files to modify\n- `src/a.js` — mirrors `src/ref.js`\n", want: ["src/a.js"] },
    { name: "other-section-excluded", input: "## Files to modify\n- `src/a.js`\n## Risks\n- `src/other.js`\n", want: ["src/a.js"] },
    { name: "plain-bullet", input: "## Files to modify\n- src/x.js\n", want: ["src/x.js"] },
    { name: "prose-bullet-skipped", input: "## Files to modify\n- update the docs too\n", want: [] },
    { name: "symbol-before-path", input: "## Files to modify\n- `armCore` in `hooks/lib/x.js`\n", want: ["hooks/lib/x.js"] },
    { name: "fixture-detail", input: DETAIL, want: ["src/a.js", "src/b.js", "docs/c.md"] },
  ];
  const bad = [];
  for (const { name, input, want } of cases) {
    const sid = nextSid("parse");
    writeDetail(sid, input);
    const got = BD.parseDetailFilesToModify(PLANS, sid);
    if (show(got) !== show(want)) bad.push(`${name}: want ${show(want)} got ${show(got)}`);
  }
  assert.deepStrictEqual(bad, [], "every parse case matches");
});
caseEnd();

caseBegin("pre-confirm-tr3-arm-with-empty-diff", "hooks/lib/supervisor-state-writer/audit-run.js");
test("(c) a TR3 arm on an empty diff keeps plan_files and records files [] with diff_scope empty", () => {
  const sid = nextSid("c");
  writeDetail(sid, DETAIL);
  const r = arm(sid, "TR3", makeRepo("c"));
  assert.ok(r.ok, `arm ${show(r)}`);
  const snap = audit(sid).declared_files;
  assert.deepStrictEqual(snap.plan_files, ["src/a.js", "src/b.js", "docs/c.md"], `snapshot ${show(snap)}`);
  assert.deepStrictEqual(snap.files, []);
  assert.strictEqual(snap.diff_scope, "empty");
  assert.ok(snap.detail_key, "detail_key recorded for a pre-confirm arm");
  assert.deepStrictEqual(r.scope_drift, [], "drift against plan_files on an empty diff");
});
caseEnd();

caseBegin("tr3-arm-without-a-diff-is-unavailable", "hooks/lib/supervisor-state-writer/audit-run.js");
test("a TR3 arm whose diff cannot be computed records diff_scope unavailable", () => {
  const sid = nextSid("u");
  writeDetail(sid, DETAIL);
  const notRepo = path.join(TMP, "not-a-repo");
  fs.mkdirSync(notRepo, { recursive: true });
  arm(sid, "TR3", notRepo);
  const snap = audit(sid).declared_files;
  assert.deepStrictEqual(snap.plan_files, ["src/a.js", "src/b.js", "docs/c.md"], `snapshot ${show(snap)}`);
  assert.deepStrictEqual(snap.files, []);
  assert.strictEqual(snap.diff_scope, "unavailable");
});
caseEnd();

caseBegin("tr3-arm-with-a-diff-scopes-files-to-the-diff", "hooks/lib/supervisor-state-writer/audit-run.js");
test("a TR3 arm with a non-empty diff keeps plan_files whole and scopes files to plan_files in the diff", () => {
  const sid = nextSid("t3d");
  writeDetail(sid, DETAIL);
  const repo = makeRepo("t3d");
  fs.writeFileSync(path.join(repo, "src/a.js"), "changed\n");
  fs.writeFileSync(path.join(repo, "docs/c.md"), "changed\n");
  fs.writeFileSync(path.join(repo, "src/ref.js"), "changed\n");
  const r = arm(sid, "TR3", repo);
  assert.ok(r.ok, `arm ${show(r)}`);
  const snap = audit(sid).declared_files;
  assert.deepStrictEqual(snap.plan_files, ["src/a.js", "src/b.js", "docs/c.md"], `plan_files whole ${show(snap)}`);
  assert.deepStrictEqual([...(snap.files || [])].sort(), ["docs/c.md", "src/a.js"], `files = plan_files ∩ changedFiles ${show(snap)}`);
  assert.ok(!snap.files.includes("src/b.js"), "a declared file outside the diff stays out of files");
  assert.ok(!snap.files.includes("src/ref.js"), "an undeclared changed file stays out of files");
  assert.strictEqual(snap.diff_scope, "scoped");
  assert.ok(snap.detail_key, "detail_key recorded for a pre-confirm arm");
});
caseEnd();

caseBegin("later-tr4-arm-scopes-files-to-the-diff","hooks/lib/supervisor-state-writer/audit-run.js");
test("(d)(f) a TR4 arm with a diff scopes files to plan_files in the diff and reports a referenced file as drift", () => {
  const sid = nextSid("d");
  writeDetail(sid, DETAIL);
  const repo = makeRepo("d");
  settle(sid, arm(sid, "TR3", repo).audit_run_id);
  fs.writeFileSync(path.join(repo, "src/a.js"), "changed\n");
  fs.writeFileSync(path.join(repo, "src/ref.js"), "changed\n");
  const r = arm(sid, "TR4", repo);
  const snap = audit(sid).declared_files;
  assert.deepStrictEqual(snap.plan_files, ["src/a.js", "src/b.js", "docs/c.md"], `plan_files unchanged ${show(snap)}`);
  assert.deepStrictEqual(snap.files, ["src/a.js"]);
  assert.strictEqual(snap.diff_scope, "scoped");
  assert.deepStrictEqual(r.scope_drift, ["src/ref.js"], `drift ${show(r.scope_drift)}`);
});
caseEnd();

caseBegin("detail-edit-then-tr3-rearm-refreshes-plan-files", "hooks/lib/supervisor-state-writer/audit-run.js");
test("(e) editing detail and re-arming TR3 refreshes plan_files and detail_key", () => {
  const sid = nextSid("e");
  writeDetail(sid, DETAIL);
  const repo = makeRepo("e");
  settle(sid, arm(sid, "TR3", repo).audit_run_id);
  const before = audit(sid).declared_files;
  writeDetail(sid, DETAIL.replace("- `docs/c.md` — document it", "- `src/d.js` — another helper"));
  arm(sid, "TR3", repo);
  const after = audit(sid).declared_files;
  assert.deepStrictEqual(after.plan_files, ["src/a.js", "src/b.js", "src/d.js"], `snapshot ${show(after)}`);
  assert.notStrictEqual(after.detail_key, before.detail_key, "detail_key recomputed");
});
caseEnd();

caseBegin("snapshot-stale-reads-plan-files-and-legacy-files", "hooks/workflow-gate/user-verified-audit.js");
test("(g) snapshotStale compares plan_files, and a legacy snapshot without plan_files still uses files", () => {
  const sid = nextSid("g");
  writeDetail(sid, DETAIL);
  const cases = [
    { name: "legacy-subset", snap: { files: ["src/a.js", "src/b.js"] }, want: false },
    { name: "legacy-narrowed", snap: { files: ["src/a.js", "src/gone.js"] }, want: true },
    { name: "plan-files-subset", snap: { plan_files: ["src/a.js", "docs/c.md"], files: [] }, want: false },
    { name: "plan-files-narrowed-outside-diff", snap: { plan_files: ["src/a.js", "src/gone.js"], files: ["src/a.js"] }, want: true },
  ];
  const bad = [];
  for (const { name, snap, want } of cases) {
    const got = UVA.snapshotStale({ declared_files: snap }, PLANS, sid);
    if (got.narrowed !== want) bad.push(`${name}: want narrowed=${want} got ${show(got)}`);
  }
  assert.deepStrictEqual(bad, [], "every snapshotStale case matches");
});
caseEnd();

caseBegin("cap-declared-files-caps-plan-files", "hooks/lib/audit-ledger.js");
test("capDeclaredFiles cuts plan_files at DECLARED_FILES_CAP and marks truncated", () => {
  const many = Array.from({ length: LEDGER.DECLARED_FILES_CAP + 1 }, (_, i) => `src/f${i}.js`);
  const got = LEDGER.capDeclaredFiles({ plan_files: many, files: [] });
  assert.strictEqual(got.plan_files.length, LEDGER.DECLARED_FILES_CAP);
  assert.strictEqual(got.truncated, true);
  const small = LEDGER.capDeclaredFiles({ plan_files: ["src/a.js"], files: ["src/a.js"] });
  assert.deepStrictEqual(small.plan_files, ["src/a.js"]);
  assert.strictEqual(small.truncated, false);
});
caseEnd();
