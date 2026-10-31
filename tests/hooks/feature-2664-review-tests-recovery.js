"use strict";
// Tests: hooks/workflow-state/state-io/review-tests.js, hooks/workflow-mark/review-tests-handler.js
// Tags: TL2, workflow, review-tests, warnings-accepted, recovery, fallback-raw, scope:issue-specific, unreviewed
// #2664 item 2 — WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED recovers an in_progress review_tests not
// only after a terminal exit (rc 2/6) but also after exit 1/5 (continuing marker) and after an
// exit 3 fallback that ended NEEDS_REVISION — each only while the review scope still matches the
// fingerprint the marker pinned (T-RT1..T-RT9). #2842 (UA-*): also with no review result — the RT-2
// unreviewed marker and rc 3 with a missing / older fallback-raw; wsid markers via owner or pointer.
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
delete process.env.REVIEW_SCOPE_HEADER_TARGETS_BASH;
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const STATE = process.env.WORKFLOW_STATE_DIR;
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const REASON = "user accepts remaining gaps";
const ACCEPT = `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: ${REASON}>>"`;
const NOTHING = "nothing to accept";
const UNREVIEWED = "test-review-unreviewed.txt";
const ev = require(path.join(ROOT, "hooks", "workflow-gate", "review-tests-evidence.js"));
const stateIo = require(path.join(ROOT, "hooks", "workflow-state", "state-io.js"));
const BAD_BASH = path.join(TMP, "no-such-dir", "bash").replace(/\\/g, "/");

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
// repo(wsid) -> a repo with tests/x.sh (Tests: hooks/impl.js) and hooks/impl.js staged; wsid names a WORKTREE_NOTES.md
// Session-ID (left unstaged) that makes the workflow session id differ from the CC session id.
function repo(wsid) {
  const d = path.join(TMP, `repo-${++seq}`).replace(/\\/g, "/");
  gitInit(d);
  git(d, "config", "user.email", "t@example.invalid");
  git(d, "config", "user.name", "T");
  fs.writeFileSync(path.join(d, "README.md"), "seed\n");
  git(d, "add", "README.md");
  git(d, "commit", "-qm", "init");
  stage(d, "tests/x.sh", "#!/usr/bin/env bash\n# Tests: hooks/impl.js");
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
const ctl = (sid, name) => path.join(STATE, `${sid}.control`, name);
function put(sid, name, body) {
  fs.mkdirSync(path.join(STATE, `${sid}.control`), { recursive: true });
  fs.writeFileSync(ctl(sid, name), body);
  return ctl(sid, name);
}
// marker(sid, kind, rc, line2) -> the control marker path (kind: "terminal" | "continuing" | "unreviewed").
const marker = (sid, kind, rc, line2) => put(sid, `test-review-${kind}.txt`, `${rc}\n${line2 == null ? "" : line2}\n`);
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
// ownWsid(wsid, sid) — the plan context of wsid records the CC session sid, so the resolver trusts wsid.
function ownWsid(wsid, sid) {
  fs.writeFileSync(path.join(PLANS, `${wsid}-context.md`), `# context\nsession-id: ${sid}\n`);
}
// glossary(sid, d) — the glossary_check record a restore-to-complete crosses (#2529).
function glossary(sid, d) {
  const env = Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: d });
  spawnSync(process.execPath, [path.join(ROOT, "bin", "check-glossary-drift"), "--session", sid, "--stage", "tests", "--record"],
    { cwd: d, env, encoding: "utf8", timeout: 60000 });
}
// send(sid, d, wsid, opts) -> stdout+stderr of the real workflow-mark.js hook on opts.cmd (default: the
// ACCEPTED sentinel); opts.ccSid exports CLAUDE_CODE_SESSION_ID.
function send(sid, d, wsid, opts = {}) {
  glossary(sid, d);
  if (wsid) glossary(wsid, d);
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_PROJECT_DIR;
  delete env.CLAUDE_CODE_SESSION_ID;
  if (opts.ccSid) env.CLAUDE_CODE_SESSION_ID = opts.ccSid;
  const input = JSON.stringify({ session_id: sid, tool_name: "Bash", tool_input: { command: opts.cmd || ACCEPT }, cwd: d });
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks", "workflow-mark.js")],
    { input, env, cwd: d, encoding: "utf8", timeout: 60000 });
  assert.ok(!r.error, `hook ran: ${r.error && r.error.message}`);
  return `${r.stdout || ""}${r.stderr || ""}`;
}
const rawState = (sid) => JSON.parse(fs.readFileSync(path.join(STATE, `${sid}.json`), "utf8"));
const reviewTests = (sid) => {
  const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));
  const s = readState(sid);
  return (s && s.steps && s.steps.review_tests) || {};
};
const status = (sid) => reviewTests(sid).status;
// recoverySources(sid) -> every `source` value carried by the recovery batch's events.
const recoverySources = (sid) => (rawState(sid).events || [])
  .filter((e) => e && /^accept-.*review-tests$/.test(String(e.origin || "")))
  .map((e) => JSON.stringify(e)).join("\n");
let sidSeq = 0;
const sidOf = (tag) => `rt${tag}${++sidSeq}sid`;
// selectScope(sid, d, env) -> stdout of the real RT-2 CLI (it writes the unreviewed marker on a full selection).
function selectScope(sid, d, env) {
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "select-review-scope.js"), "--session", sid, "--worktree", d],
    { env: Object.assign({}, process.env, env || {}), encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `select-review-scope: ${r.stderr}`);
  return r.stdout;
}
const recordManifest = (sid, d) => stateIo.appendEvents(sid, [{
  kind: "step_annotation", step: "review_tests", key: "review_scope_manifest",
  value: { v: 1, files: ev.computeReviewScopeManifest(d).files }, provenance: "observed", origin: "review-tests-complete",
}]);
function assertRecovered(sid, out, source, label) {
  assert.strictEqual(status(sid), "complete", `${label}: restored to complete (${out})`);
  assert.ok(recoverySources(sid).includes(source), `${label}: recovery source ${source}: ${recoverySources(sid)}`);
}

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
  ownWsid(wsid, sid);
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
test("T-RT4: rc 3 with a fallback-raw that ran but is not NEEDS_REVISION (APPROVED / INPUT_ERROR / empty / garbage) stays in_progress", () => {
  const scenes = [["approved", "APPROVED", 2], ["inputerror", "INPUT_ERROR tests/x.sh", 2],
    ["empty", "", 2], ["garbage", "LGTM ship it", 2]];
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
  ownWsid(wsid, sid);
  const m = marker(sid, "terminal", "3", fp(d));
  fallbackRaw(wsid, "APPROVED", m);
  fallbackRaw(sid, "NEEDS_REVISION", m);
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "in_progress", `not recovered (${out})`);
});
test("T-RT10: a wsid whose context does not record this CC session is another session's — its fallback-raw is not used", () => {
  const wsid = `${sidOf("w10")}wf`;
  const d = repo(wsid);
  const sid = sidOf("f10");
  seed(sid);
  fs.writeFileSync(path.join(PLANS, `${wsid}-context.md`), "# context\n\nsession: some-other-session\n");
  const m = marker(sid, "terminal", "3", fp(d));
  fallbackRaw(wsid, "NEEDS_REVISION", m);
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "in_progress", `foreign NEEDS_REVISION ignored (${out})`);
});
test("T-RT10: with a foreign wsid, the CC-id fallback-raw is judged instead", () => {
  const wsid = `${sidOf("w10b")}wf`;
  const d = repo(wsid);
  const sid = sidOf("f10b");
  seed(sid);
  const m = marker(sid, "terminal", "3", fp(d));
  fallbackRaw(wsid, "APPROVED", m);
  fallbackRaw(sid, "NEEDS_REVISION", m);
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "complete", `restored to complete (${out})`);
});
// approvalTrace(sid) -> every recorded trace of an acceptance: the reason, the recovery source, the recovery events.
const approvalTrace = (sid) => {
  const rt = reviewTests(sid);
  return JSON.stringify({ reason: rt.warnings_accepted_reason || null, source: rt.recovery_source || null, recovery: recoverySources(sid) });
};
test("T-RT10c (C1): a foreign wsid whose context holds only a prefix-truncated CC id does not own it -> its fallback-raw is ignored", () => {
  const wsid = `${sidOf("w10c")}wf`;
  const d = repo(wsid);
  const sid = sidOf("f10c");
  seed(sid);
  fs.writeFileSync(path.join(PLANS, `${wsid}-context.md`), `# context\n\nsession: ${sid.slice(0, -2)}\nprefix: ${sid.slice(0, 4)}\n`);
  const m = marker(sid, "terminal", "3", fp(d));
  fallbackRaw(wsid, "NEEDS_REVISION", m);
  const before = approvalTrace(sid);
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "in_progress", `partial id is not ownership (${out})`);
  assert.strictEqual(approvalTrace(sid), before, "no approval event is added");
  assert.strictEqual(recoverySources(sid), "", "no recovery event exists");
});
test("T-RT10d: a foreign wsid whose context holds a longer id or only a quoted mention of the CC id does not own it -> its fallback-raw is ignored", () => {
  const bodies = [
    ["longer", (sid) => `# context\nsession-id: ${sid}-extra\n`],
    ["quoted", (sid) => `# context\n> was session-id: ${sid} earlier\nnote: ${sid}\n`],
  ];
  for (const [label, body] of bodies) {
    const wsid = `${sidOf(`w10d${label}`)}wf`;
    const d = repo(wsid);
    const sid = sidOf(`f10d${label}`);
    seed(sid);
    fs.writeFileSync(path.join(PLANS, `${wsid}-context.md`), body(sid));
    const m = marker(sid, "terminal", "3", fp(d));
    fallbackRaw(wsid, "NEEDS_REVISION", m);
    const before = approvalTrace(sid);
    const out = send(sid, d, wsid);
    assert.strictEqual(status(sid), "in_progress", `${label}: not ownership (${out})`);
    assert.strictEqual(approvalTrace(sid), before, `${label}: no approval event is added`);
    assert.strictEqual(recoverySources(sid), "", `${label}: no recovery event exists`);
  }
});
caseEnd();

caseBegin("rt-accept-replay-is-inert", "hooks/workflow-state/state-io/review-tests.js");
test("T-RT11 (C2): re-sending the ACCEPTED sentinel after a recovery changes neither state nor events and revives no marker", () => {
  const scenes = [
    ["fallback-3", (sid, d, wsid) => fallbackRaw(wsid, "NEEDS_REVISION", marker(sid, "terminal", "3", fp(d)))],
    ["continuing-1", (sid, d) => marker(sid, "continuing", "1", fp(d))],
  ];
  for (const [label, arrange] of scenes) {
    const wsid = `${sidOf("w11")}wf`;
    const d = repo(wsid);
    const sid = sidOf(`r11${label.replace(/\W/g, "")}`);
    seed(sid);
    ownWsid(wsid, sid);
    arrange(sid, d, wsid);
    const out1 = send(sid, d, wsid);
    assert.strictEqual(status(sid), "complete", `${label}: recovered (${out1})`);
    const after1 = rawState(sid);
    const after1RT = reviewTests(sid);
    const out2 = send(sid, d, wsid);
    assert.strictEqual(status(sid), "complete", `${label}: still complete (${out2})`);
    // send() re-records the glossary_check itself (test helper), so those events are not the hook's.
    const hookEvents = (s) => (s.events || []).filter((e) => e && e.origin !== "check-glossary-drift");
    assert.deepStrictEqual(hookEvents(rawState(sid)), hookEvents(after1), `${label}: no event added by the replay`);
    assert.deepStrictEqual(reviewTests(sid), after1RT, `${label}: review_tests unchanged`);
    for (const k of ["continuing", "terminal"]) {
      assert.ok(!fs.existsSync(path.join(STATE, `${sid}.control`, `test-review-${k}.txt`)), `${label}: no ${k} marker revived`);
    }
  }
});
caseEnd();

caseBegin("rt-refusal-writes-nothing", "hooks/workflow-state/state-io/review-tests.js");
test("T-RT12 (C3): an invalid fallback-raw or a stale marker writes no approval reason and no recovery event", () => {
  const scenes = [
    ["approved", "APPROVED", 2, false], ["inputerror", "INPUT_ERROR tests/x.sh", 2, false],
    ["empty", "", 2, false], ["garbage", "LGTM ship it", 2, false],
    ["stale", "NEEDS_REVISION", 2, true],
  ];
  for (const [label, first, offset, moved] of scenes) {
    const d = repo();
    const sid = sidOf(`x12${label}`);
    seed(sid);
    const m = marker(sid, "terminal", "3", fp(d));
    if (first !== null) fallbackRaw(sid, first, m, offset);
    if (moved) stage(d, "tests/x.sh", "echo x changed after the review");
    const before = approvalTrace(sid);
    const out = send(sid, d);
    assert.strictEqual(status(sid), "in_progress", `${label}: not recovered (${out})`);
    assert.strictEqual(approvalTrace(sid), before, `${label}: no approval reason / recovery event written`);
    assert.strictEqual(reviewTests(sid).warnings_accepted_reason == null, true, `${label}: no acceptance reason`);
    assert.strictEqual(recoverySources(sid), "", `${label}: no recovery event`);
  }
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
test("T-RT7 / UA-c / UA-g2: the scope moved after the marker (or line 2 is empty) -> STALE_EVIDENCE: in_progress, marker kept", () => {
  const scenes = [
    ["continuing-moved", "continuing", "1", true, false],
    ["fallback-moved", "terminal", "3", true, true],
    ["continuing-empty-line2", "continuing", "1", false, false],
    ["UA-c unreviewed-moved", "unreviewed", "scope-full:no-record", true, false],
    ["UA-g2 terminal3-empty-line2", "terminal", "3", false, false],
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

caseBegin("ua-scope-full-marker-accepted", "hooks/workflow-state/state-io/review-tests.js");
test("UA-a: full/header-map-unavailable leaves a marker; ACCEPTED -> complete with unreviewed-scope-full source, marker gone", () => {
  const d = repo();
  const sid = sidOf("ua");
  seed(sid);
  recordManifest(sid, d);
  stage(d, "hooks/impl.js", "impl v2");
  assert.ok(selectScope(sid, d, { REVIEW_SCOPE_HEADER_TARGETS_BASH: BAD_BASH }).includes("header-map-unavailable"), "fixture reaches header-map-unavailable");
  assert.ok(fs.existsSync(ctl(sid, UNREVIEWED)), "RT-2 wrote the unreviewed marker");
  assert.deepStrictEqual(fs.readFileSync(ctl(sid, UNREVIEWED), "utf8").split(/\r?\n/).slice(0, 2), ["scope-full:header-map-unavailable", fp(d)]);
  const out = send(sid, d);
  assertRecovered(sid, out, "unreviewed-scope-full:header-map-unavailable", "UA-a");
  assert.strictEqual(fs.existsSync(ctl(sid, UNREVIEWED)), false, "accepting removes the marker");
});
test("UA-b: the marker does not depend on REASON — no-record and explicit-rereview recover the same way", () => {
  for (const [reason, arrange] of [["no-record", () => {}], ["explicit-rereview", (sid, d) => recordManifest(sid, d)]]) {
    const d = repo();
    const sid = sidOf(`ub${reason.length}`);
    seed(sid);
    arrange(sid, d);
    assert.ok(selectScope(sid, d).includes(reason), `${reason}: fixture reaches the reason`);
    const out = send(sid, d);
    assertRecovered(sid, out, `unreviewed-scope-full:${reason}`, reason);
  }
});
test("UA-e: an accepted COMPLETE sentinel removes the unreviewed marker", () => {
  const d = repo();
  const sid = sidOf("ue");
  seed(sid);
  marker(sid, "unreviewed", "scope-full:no-record", fp(d));
  const out = send(sid, d, null, { cmd: `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=${fp(d)}>>"` });
  assert.strictEqual(status(sid), "complete", out);
  assert.strictEqual(fs.existsSync(ctl(sid, UNREVIEWED)), false, "COMPLETE clears the marker");
});
caseEnd();

caseBegin("ua-terminal-3-without-fallback", "hooks/workflow-state/state-io/review-tests.js");
// APPROVED / INPUT_ERROR (T-RT4) and NEEDS_REVISION (T-RT3, T-RT8) keep their outcome; only a fallback that never ran is new.
test("UA-g: rc 3 pinned with the fallback-raw missing or older than the marker -> complete (source unreviewed-terminal-3)", () => {
  for (const [label, offset] of [["missing", null], ["older", -60]]) {
    const d = repo();
    const sid = sidOf(`ug${label}`);
    seed(sid);
    const m = marker(sid, "terminal", "3", fp(d));
    if (offset !== null) fallbackRaw(sid, "NEEDS_REVISION", m, offset);
    assertRecovered(sid, send(sid, d), "unreviewed-terminal-3", label);
  }
});
test("UA-h: terminal rc 2 with an empty line 2 is still accepted on line 1 alone", () => {
  const d = repo();
  const sid = sidOf("uh");
  seed(sid);
  marker(sid, "terminal", "2", "");
  const out = send(sid, d);
  assert.strictEqual(status(sid), "complete", out);
});
caseEnd();

caseBegin("ua-wsid-markers", "hooks/workflow-state/state-io/review-tests.js");
test("UA-i: markers only under an owned ambient wsid are judged and removed (terminal 3, continuing 1)", () => {
  for (const [kind, rc, source] of [["terminal", "3", "unreviewed-terminal-3"], ["continuing", "1", "continuing"]]) {
    const wsid = `${sidOf("uiw")}wf`;
    const d = repo(wsid);
    const sid = sidOf(`ui${kind}`);
    seed(sid);
    ownWsid(wsid, sid);
    const m = marker(wsid, kind, rc, fp(d));
    const out = send(sid, d, wsid);
    assertRecovered(sid, out, source, `wsid ${kind}`);
    assert.strictEqual(fs.existsSync(m), false, `wsid ${kind}: the wsid-side marker is removed`);
  }
});
test("UA-j: a wsid owned by another CC session, with no pointer, is not read — nothing to accept, marker kept", () => {
  const wsid = `${sidOf("ujw")}wf`;
  const d = repo(wsid);
  const sid = sidOf("uj");
  seed(sid);
  ownWsid(wsid, "some-other-session");
  const m = marker(wsid, "terminal", "3", fp(d));
  const out = send(sid, d, wsid);
  assert.strictEqual(status(sid), "in_progress", out);
  assert.ok(out.includes(NOTHING) && out.includes("unreviewed"), `nothing-to-accept names the unreviewed evidence: ${out}`);
  assert.ok(fs.existsSync(m), "the foreign marker is kept");
});
test("UA-k: wsid != CC sid, ambient wsid = CC sid -> the CC-side pointer reaches the wsid terminal; an invalid pointer is ignored", () => {
  for (const [label, pointer, want] of [["pointer", null, "complete"], ["bad-pointer", "../x", "in_progress"]]) {
    const wsid = `${sidOf("ukw")}wf`;
    const d = repo();
    const sid = sidOf(`uk${label}`);
    seed(sid);
    fs.writeFileSync(path.join(PLANS, `${sid}-intent.md`), "# intent\n");
    const m = marker(wsid, "terminal", "3", fp(d));
    put(sid, "test-review-wsid.txt", `${pointer === null ? wsid : pointer}\n`);
    const out = send(sid, d, null, { ccSid: sid });
    assert.strictEqual(status(sid), want, `${label}: ${out}`);
    if (want === "complete") {
      assert.ok(recoverySources(sid).includes("unreviewed-terminal-3"), `${label}: ${recoverySources(sid)}`);
      assert.strictEqual(fs.existsSync(m), false, `${label}: the wsid terminal is removed`);
    } else {
      assert.ok(out.includes(NOTHING), `${label}: nothing to accept: ${out}`);
      assert.ok(fs.existsSync(m), `${label}: the marker is kept (fail-closed)`);
    }
  }
});
caseEnd();
