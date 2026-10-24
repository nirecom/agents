"use strict";
// Tests: hooks/workflow-state/state-io/review-tests.js, hooks/workflow-mark/review-tests-handler.js
// Tags: TL2, workflow, review-tests, warnings-accepted, recovery, fallback-raw, scope:issue-specific
// #2664 item 2 — WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED recovers an in_progress review_tests not
// only after a terminal exit (rc 2/6) but also after exit 1/5 (continuing marker) and after an
// exit 3 fallback that ended NEEDS_REVISION — each only while the review scope still matches the
// fingerprint the marker pinned (T-RT1..T-RT9).
// TL3 gap (what this test does NOT catch):
// - the real run-codex-review-loop.sh writing the markers (tests/skills/feature-2664-review-tests-continuing-marker.sh)
// - a real claude -p session firing the PostToolUse hook for the ACCEPTED sentinel
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2664rt-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.writeFileSync(path.join(CFG, ".env"), "");
fs.mkdirSync(path.join(TMP, "transcripts"));
fs.mkdirSync(path.join(TMP, "nogit"));
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.WORKFLOW_SESSION_ID;
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const STATE = process.env.WORKFLOW_STATE_DIR;
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const REASON = "user accepts remaining gaps";
const ACCEPT = `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: ${REASON}>>"`;
const NOTHING = "nothing to accept";
const ev = require(path.join(ROOT, "hooks", "workflow-gate", "review-tests-evidence.js"));

const git = (dir, ...a) => {
  const r = spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" });
  assert.strictEqual(r.status, 0, `git ${a.join(" ")}: ${r.stderr}`);
};
const stage = (repo, rel, body) => {
  fs.mkdirSync(path.dirname(path.join(repo, rel)), { recursive: true });
  fs.writeFileSync(path.join(repo, rel), `${body}\n`);
  git(repo, "add", "--", rel);
};
let seq = 0;
// repo(wsid) -> a repo with tests/x.sh and hooks/impl.js staged; wsid names a WORKTREE_NOTES.md
// Session-ID (left unstaged) that makes the workflow session id differ from the CC session id.
function repo(wsid) {
  const d = path.join(TMP, `repo-${++seq}`).replace(/\\/g, "/");
  gitInit(d);
  git(d, "config", "user.email", "t@example.invalid");
  git(d, "config", "user.name", "T");
  fs.writeFileSync(path.join(d, "README.md"), "seed\n");
  git(d, "add", "README.md");
  git(d, "commit", "-qm", "init");
  stage(d, "tests/x.sh", "echo x");
  stage(d, "hooks/impl.js", "impl");
  if (wsid) fs.writeFileSync(path.join(d, "WORKTREE_NOTES.md"), `# notes\n\nSession-ID: ${wsid}\n`);
  return d;
}
const fp = (d) => ev.computeReviewScopeFingerprint(d).fingerprint;
// seed(sid) — every step before review_tests complete, review_tests in_progress.
function seed(sid) {
  const steps = {};
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests"]) steps[s] = { status: "complete" };
  steps.review_tests = { status: "in_progress" };
  steps.write_code = { status: "complete" };
  for (const s of ["run_tests", "review_security", "docs", "review_docs", "user_verification", "cleanup", "pre_final_report_gate", "final_report"]) steps[s] = { status: "pending" };
  fs.writeFileSync(path.join(STATE, `${sid}.json`), JSON.stringify({ version: 1, session_id: sid, steps, closes_issues: [2664] }));
}
// marker(sid, kind, rc, line2) -> the control marker path (kind: "terminal" | "continuing").
function marker(sid, kind, rc, line2) {
  const dir = path.join(STATE, `${sid}.control`);
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, `test-review-${kind}.txt`);
  fs.writeFileSync(p, `${rc}\n${line2 == null ? "" : line2}\n`);
  return p;
}
// fallbackRaw(sid, firstLine, markerPath, offsetSec) — the exit-3 fallback output, its mtime set
// offsetSec relative to the marker's; firstLine "" writes a file with no non-empty line at all.
// The fallback reviewer's NEEDS_REVISION is the RT-5 WARNINGS outcome (SKILL.md exit 3 row), so
// NEEDS_REVISION is the one first line that makes rc 3 recoverable (detail.md 5-2).
function fallbackRaw(sid, firstLine, markerPath, offsetSec = 2) {
  const p = path.join(PLANS, `${sid}-test-review-fallback-raw.md`);
  fs.writeFileSync(p, firstLine === "" ? "\n  \n" : `\n${firstLine}\n- tests/x.sh misses the error path\n`);
  const t = fs.statSync(markerPath).mtimeMs / 1000 + offsetSec;
  fs.utimesSync(p, t, t);
}
// glossary(sid, d) — the glossary_check record a restore-to-complete crosses (#2529).
function glossary(sid, d) {
  const env = Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: d });
  spawnSync(process.execPath, [path.join(ROOT, "bin", "check-glossary-drift"), "--session", sid, "--stage", "tests", "--record"],
    { cwd: d, env, encoding: "utf8", timeout: 60000 });
}
// send(sid, d, wsid) -> stdout+stderr of the real workflow-mark.js hook on the ACCEPTED sentinel.
function send(sid, d, wsid) {
  glossary(sid, d);
  if (wsid) glossary(wsid, d);
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_PROJECT_DIR;
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = JSON.stringify({ session_id: sid, tool_name: "Bash", tool_input: { command: ACCEPT }, cwd: d });
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks", "workflow-mark.js")],
    { input, env, cwd: d, encoding: "utf8", timeout: 60000 });
  assert.ok(!r.error, `hook ran: ${r.error && r.error.message}`);
  return `${r.stdout || ""}${r.stderr || ""}`;
}
const rawState = (sid) => JSON.parse(fs.readFileSync(path.join(STATE, `${sid}.json`), "utf8"));
const status = (sid) => {
  const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));
  const s = readState(sid);
  return ((s && s.steps && s.steps.review_tests) || {}).status;
};
// recoverySources(sid) -> every `source` value carried by the recovery batch's events.
const recoverySources = (sid) => (rawState(sid).events || [])
  .filter((e) => e && /^accept-.*review-tests$/.test(String(e.origin || "")))
  .map((e) => JSON.stringify(e)).join("\n");
let sidSeq = 0;
const sidOf = (tag) => `rt${tag}${++sidSeq}sid`;

caseBegin("rt-continuing-marker-recovers", "hooks/workflow-state/state-io/review-tests.js");
test("control: terminal rc 6 recovers through this fixture (line 2 is not compared)", () => {
  const d = repo();
  const sid = sidOf("t6");
  seed(sid);
  marker(sid, "terminal", "6", "not-the-fingerprint");
  const out = send(sid, d);
  assert.strictEqual(status(sid), "complete", `restored to complete (${out})`);
});
for (const rc of ["1", "5"]) {
  test(`T-RT${rc === "1" ? 1 : 2}: continuing rc ${rc} pinned to the current scope -> complete (source continuing-${rc})`, () => {
    const d = repo();
    const sid = sidOf(`c${rc}`);
    seed(sid);
    const m = marker(sid, "continuing", rc, fp(d));
    const out = send(sid, d);
    assert.strictEqual(status(sid), "complete", `restored to complete (${out})`);
    assert.ok(recoverySources(sid).includes(`continuing-${rc}`), `the recovery event records source continuing-${rc}`);
    assert.ok(!fs.existsSync(m), "accepting ends the review: the continuing marker is removed");
  });
}
caseEnd();

caseBegin("rt-fallback-needs-revision-recovers", "hooks/workflow-state/state-io/review-tests.js");
test("T-RT3: terminal rc 3 + a newer fallback-raw whose verdict is NEEDS_REVISION (= WARNINGS) under the wsid -> complete (source fallback-3)", () => {
  const wsid = `${sidOf("w")}wf`;
  const d = repo(wsid);
  const sid = sidOf("f3");
  seed(sid);
  fallbackRaw(wsid, "NEEDS_REVISION", marker(sid, "terminal", "3", fp(d)));
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "complete", `restored to complete (${out})`);
  assert.ok(recoverySources(sid).includes("fallback-3"), "the recovery event records source fallback-3");
});
test("T-RT8: no wsid resolves -> the fallback-raw under the CC session id is used", () => {
  const d = repo();
  const sid = sidOf("f8");
  seed(sid);
  fallbackRaw(sid, "NEEDS_REVISION", marker(sid, "terminal", "3", fp(d)));
  const out = send(sid, d);
  assert.strictEqual(status(sid), "complete", `restored to complete (${out})`);
});
caseEnd();

caseBegin("rt-fallback-invalid-stays-in-progress", "hooks/workflow-state/state-io/review-tests.js");
test("T-RT4: rc 3 without a NEEDS_REVISION fallback-raw (missing / APPROVED / INPUT_ERROR / empty / garbage / older) stays in_progress", () => {
  const scenes = [["missing", null, 0], ["approved", "APPROVED", 2], ["inputerror", "INPUT_ERROR tests/x.sh", 2],
    ["empty", "", 2], ["garbage", "LGTM ship it", 2], ["older", "NEEDS_REVISION", -60]];
  for (const [label, first, offset] of scenes) {
    const d = repo();
    const sid = sidOf(`f4${label}`);
    seed(sid);
    const m = marker(sid, "terminal", "3", fp(d));
    if (first !== null) fallbackRaw(sid, first, m, offset);
    const out = send(sid, d);
    assert.strictEqual(status(sid), "in_progress", `${label}: not recovered (${out})`);
  }
});
test("T-RT9: the first fallback-raw found (wsid, APPROVED) is the only one judged; the CC-id NEEDS_REVISION is ignored", () => {
  const wsid = `${sidOf("w9")}wf`;
  const d = repo(wsid);
  const sid = sidOf("f9");
  seed(sid);
  const m = marker(sid, "terminal", "3", fp(d));
  fallbackRaw(wsid, "APPROVED", m);
  fallbackRaw(sid, "NEEDS_REVISION", m);
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "in_progress", `not recovered (${out})`);
});
caseEnd();

caseBegin("rt-continuing-manifest-unavailable", "hooks/workflow-mark/review-tests-handler.js");
test("T-RT5: continuing rc 1 with no computable manifest -> MANIFEST_UNAVAILABLE, marker kept", () => {
  const d = repo();
  const sid = sidOf("c5");
  seed(sid);
  const m = marker(sid, "continuing", "1", fp(d));
  const out = send(sid, path.join(TMP, "nogit").replace(/\\/g, "/"));
  assert.strictEqual(status(sid), "in_progress");
  assert.ok(out.includes("manifest unavailable"), `says manifest unavailable: ${out}`);
  assert.ok(fs.existsSync(m), "the continuing marker is kept for a retry");
});
caseEnd();

caseBegin("rt-continuing-other-rc-stays-in-progress", "hooks/workflow-state/state-io/review-tests.js");
test("T-RT6: continuing marker rc 7 / empty / abc -> in_progress (fail-closed)", () => {
  for (const rc of ["7", "", "abc"]) {
    const d = repo();
    const sid = sidOf(`c6${rc || "empty"}`);
    seed(sid);
    marker(sid, "continuing", rc, fp(d));
    const out = send(sid, d);
    assert.strictEqual(status(sid), "in_progress", `rc=[${rc}] not recovered (${out})`);
  }
});
caseEnd();

caseBegin("rt-stale-evidence-refused", "hooks/workflow-mark/review-tests-handler.js");
test("T-RT7: the scope moved after the marker (or line 2 is empty) -> STALE_EVIDENCE: in_progress, marker kept", () => {
  const scenes = [
    ["continuing-moved", "continuing", "1", true, false],
    ["fallback-moved", "terminal", "3", true, true],
    ["continuing-empty-line2", "continuing", "1", false, false],
  ];
  for (const [label, kind, rc, pin, withFallback] of scenes) {
    const d = repo();
    const sid = sidOf(`s7${kind}`);
    seed(sid);
    const m = marker(sid, kind, rc, pin ? fp(d) : "");
    if (withFallback) fallbackRaw(sid, "NEEDS_REVISION", m);
    if (pin) stage(d, "tests/x.sh", "echo x changed after the review");
    const out = send(sid, d);
    assert.strictEqual(status(sid), "in_progress", `${label}: not recovered (${out})`);
    assert.ok(fs.existsSync(m), `${label}: the marker is kept so the next review can re-judge`);
    assert.ok(!out.includes(NOTHING) && out.includes("/review-tests"), `${label}: tells the user to re-run /review-tests: ${out}`);
  }
});
caseEnd();
