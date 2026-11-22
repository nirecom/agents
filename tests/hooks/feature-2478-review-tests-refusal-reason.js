"use strict";
// Tests: hooks/workflow-mark/review-tests-handler.js, hooks/workflow-state/state-io/review-tests.js
// Tags: TL2, feature-2478, feature-3123, workflow, review-tests, warnings-accepted, refusal-reason, scope:issue-specific
// #3123 T9 (S5-b): a refused WARNINGS_ACCEPTED whose evidence names a reason (fallback-raw-unowned)
// says that reason and the way forward instead of "nothing to accept"; no evidence at all keeps the
// old message. The fallback-3 acceptance reports "exit 3, fallback ended without a recorded round".
// TL3 gap: a real claude -p session firing the PostToolUse hook for the ACCEPTED sentinel.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2478rr-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.writeFileSync(path.join(CFG, ".env"), "");
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.WORKFLOW_SESSION_ID;
delete process.env.REVIEW_SCOPE_HEADER_TARGETS_BASH;
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const STATE = process.env.WORKFLOW_STATE_DIR;
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const ACCEPT = 'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: user accepts remaining gaps>>"';
const ev = require(path.join(ROOT, "hooks", "workflow-gate", "review-tests-evidence.js"));

const git = (dir, ...a) => {
  const r = spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" });
  assert.strictEqual(r.status, 0, `git ${a.join(" ")}: ${r.stderr}`);
};
let seq = 0;
// repo(wsid) -> a repo with a staged test + target; wsid names a WORKTREE_NOTES.md Session-ID.
function repo(wsid) {
  const d = path.join(TMP, `repo-${++seq}`).replace(/\\/g, "/");
  gitInit(d);
  git(d, "config", "user.email", "t@example.invalid");
  git(d, "config", "user.name", "T");
  fs.writeFileSync(path.join(d, "README.md"), "seed\n");
  git(d, "add", "README.md");
  git(d, "commit", "-qm", "init");
  for (const [rel, body] of [["tests/x.sh", "#!/usr/bin/env bash\n# Tests: hooks/impl.js"], ["hooks/impl.js", "impl"]]) {
    fs.mkdirSync(path.dirname(path.join(d, rel)), { recursive: true });
    fs.writeFileSync(path.join(d, rel), `${body}\n`);
    git(d, "add", "--", rel);
  }
  if (wsid) fs.writeFileSync(path.join(d, "WORKTREE_NOTES.md"), `# notes\n\nSession-ID: ${wsid}\n`);
  return d;
}
const fp = (d) => ev.computeReviewScopeFingerprint(d).fingerprint;
function seed(sid) {
  const steps = {};
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "write_code"]) steps[s] = { status: "complete" };
  steps.review_tests = { status: "in_progress" };
  for (const s of ["run_tests", "review_security", "docs", "review_docs", "user_verification", "cleanup", "pre_final_report_gate", "final_report"]) steps[s] = { status: "pending" };
  fs.writeFileSync(path.join(STATE, `${sid}.json`), JSON.stringify({ version: 1, session_id: sid, steps, closes_issues: [3123] }));
}
function marker(sid, rc, line2) {
  const dir = path.join(STATE, `${sid}.control`);
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, "test-review-terminal.txt");
  fs.writeFileSync(p, `${rc}\n${line2}\n`);
  return p;
}
// fallbackRaw(sid, markerPath) — an APPROVED fallback output newer than the marker.
function fallbackRaw(sid, markerPath) {
  const p = path.join(PLANS, `${sid}-test-review-fallback-raw.md`);
  fs.writeFileSync(p, "<!-- begin-codex-output -->\nAPPROVED\n<!-- end-codex-output -->\n");
  const t = fs.statSync(markerPath).mtimeMs / 1000 + 2;
  fs.utimesSync(p, t, t);
}
function glossary(sid, d) {
  spawnSync(process.execPath, [path.join(ROOT, "bin", "check-glossary-drift"), "--session", sid, "--step", "review_tests", "--record"],
    { cwd: d, env: Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: d }), encoding: "utf8", timeout: 60000 });
}
// send(sid, d) -> stdout+stderr of the real workflow-mark.js hook on the ACCEPTED sentinel.
function send(sid, d) {
  glossary(sid, d);
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_PROJECT_DIR;
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = JSON.stringify({ session_id: sid, tool_name: "Bash", tool_input: { command: ACCEPT }, cwd: d });
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks", "workflow-mark.js")], { input, env, cwd: d, encoding: "utf8", timeout: 60000 });
  assert.ok(!r.error, `hook ran: ${r.error && r.error.message}`);
  return `${r.stdout || ""}${r.stderr || ""}`;
}
const status = (sid) => {
  const s = require(path.join(ROOT, "hooks", "workflow-state")).readState(sid);
  return ((s && s.steps && s.steps.review_tests) || {}).status;
};
let sidSeq = 0;
const sidOf = (tag) => `rr${tag}${++sidSeq}sid`;

caseBegin("unowned-fallback-raw-refusal-names-its-reason", "hooks/workflow-mark/review-tests-handler.js");
test("T9: rc 3 pinned, the only raw under a wsid this session does not own -> refused with fallback-raw-unowned, not 'nothing to accept'", () => {
  const wsid = `${sidOf("w")}wf`;
  const d = repo(wsid);
  const sid = sidOf("u");
  seed(sid);
  const m = marker(sid, "3", fp(d));
  fallbackRaw(wsid, m);
  const out = send(sid, d);
  assert.strictEqual(status(sid), "in_progress", `not recovered (${out})`);
  assert.ok(out.includes("fallback-raw-unowned"), `the refusal names its reason: ${out}`);
  assert.ok(!out.includes("nothing to accept") && !out.includes("nothing to clear"), `not reported as no evidence: ${out}`);
  assert.ok(out.includes("/review-tests"), `the refusal names the way forward (re-review): ${out}`);
  assert.ok(fs.existsSync(m), "the marker is kept (state unchanged)");
});
caseEnd();

caseBegin("no-evidence-keeps-the-nothing-to-accept-message", "hooks/workflow-mark/review-tests-handler.js");
test("T9: in_progress with no marker at all -> the unchanged 'nothing to accept' message", () => {
  const d = repo();
  const sid = sidOf("n");
  seed(sid);
  const out = send(sid, d);
  assert.strictEqual(status(sid), "in_progress", out);
  assert.ok(out.includes("nothing to accept"), `no-evidence keeps its message: ${out}`);
  assert.ok(!out.includes("fallback-raw-unowned"), `no reason is invented: ${out}`);
});
caseEnd();

caseBegin("fallback-3-acceptance-wording", "hooks/workflow-mark/review-tests-handler.js");
test("S5-b: rc 3 with an owned newer raw is accepted as 'exit 3, fallback ended without a recorded round'", () => {
  const d = repo();
  const sid = sidOf("f");
  seed(sid);
  fallbackRaw(sid, marker(sid, "3", fp(d)));
  const out = send(sid, d);
  assert.strictEqual(status(sid), "complete", out);
  assert.ok(out.includes("exit 3, fallback ended without a recorded round"), `the new wording: ${out}`);
  assert.ok(!out.includes("exit 3, NEEDS_REVISION"), `the old wording is gone: ${out}`);
});
caseEnd();
