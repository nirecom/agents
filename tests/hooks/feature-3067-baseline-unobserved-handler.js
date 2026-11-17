#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-mark/run-tests-baseline-unobserved-handler.js, hooks/lib/sentinel-patterns.js, hooks/workflow-mark.js, hooks/workflow-state/state-io/events.js, hooks/workflow-run-tests/record-run.js, hooks/lib/run-tests-completion-note.js, settings.json
// Tags: TL2, hooks, run-tests, baseline, approval, sentinel, workflow-mark, workflow-state, scope:issue-specific
// #3067 step 3: WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED completes a run_tests whose only
// blockers are approvable rows, bound to the fixture repo's HEAD; every other state is refused.
// TL3 gap (what this test does NOT catch):
// - The user answering the settings.json ask prompt for the sentinel in a live session.
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

// Fixture isolation: pin the state / plans dirs to temp and unset the session ID before any hook loads.
const restore = isolate();
const F = require("../lib/baseline-unobserved-fixture");
const { runMark, bashPayload } = require("../lib/workflow-mark-output");
process.env.RUN_ALL_CACHE_DIR = path.join(F.TMP, "cache");
fs.mkdirSync(process.env.RUN_ALL_CACHE_DIR);
after(() => { restore(); F.cleanup(); });

const mod = (rel) => require(path.join(F.ROOT, rel));
const REASON = "base worktree could not start the test";
const A = ["tests/bin/a.sh", "undetermined", "unrunnable-at-base"];
const B = ["tests/bin/b.sh", "undetermined", "ambiguous-exit-142"];
const P = ["tests/bin/p.sh", "preexisting", "base-fail"];
const M = ["tests/bin/m.sh", "undetermined", "missing-at-base"];
const asTest = ([p, c, d]) => ({ path: p, class: c, detail: d });
const pick = (e) => ({ status: e.status, completion_basis: e.completion_basis ?? null,
  run_outcome: e.run_outcome ?? null, accept: e.baseline_unobserved_accept ?? null });

function assertApproved(id, head, tests, label) {
  const e = F.runTests(id);
  assert.equal(e.status, "complete", `${label}: status`);
  assert.equal(e.completion_basis, F.BASIS, `${label}: completion_basis`);
  assert.equal(e.run_outcome, "pass", `${label}: run_outcome`);
  const acc = e.baseline_unobserved_accept || {};
  assert.equal(acc.reason, REASON, `${label}: accept.reason`);
  assert.equal(acc.head, head, `${label}: accept.head`);
  assert.deepEqual(structuredClone(acc.tests), tests, `${label}: accept.tests are the approvable rows only`);
}

// approve(label, extra) — a pending state of A, B, P bound to a fresh repo's HEAD, then the sentinel.
function approve(label, extra = {}) {
  const repo = F.repo(label);
  const head = F.headOf(repo);
  const id = F.sid(label);
  F.seedPending(id, Object.assign({ rows: [A, B, P], head }, extra));
  return { repo, head, id, res: F.handle(id, F.sentinel(REASON), repo) };
}

caseBegin("approve-approvable-rows", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("approve-approvable-rows", () => {
  const { head, id, res } = approve("normal");
  assert.equal(res.handled, true, "the handler claims the sentinel");
  assert.equal(res.unapplied, "", "nothing refused");
  assertApproved(id, head, [asTest(A), asTest(B)], "normal");
  assert.match(res.info, /RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED/, "info names the sentinel");
});
caseEnd();

// The classification `record` really writes (with --head) is the one the handler accepts.
const cli = F.cli;

caseBegin("approve-after-real-record", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("approve-after-real-record", () => {
  const repo = F.repo("cli");
  const head = F.headOf(repo);
  const id = F.sid("cli");
  F.seedPending(id, { rows: [A], classification: false });
  const seq = (/^SEQ=(\S+)/m.exec(cli(["failing", "--session", id]).out) || [])[1];
  assert.ok(seq, "failing printed SEQ=");
  const file = path.join(F.TMP, `${id}.tsv`);
  fs.writeFileSync(file, `${A.join("\t")}\t0\t[]\n`);
  const rec = cli(["record", "--session", id, "--seq", seq, "--classification", file, "--head", head]);
  assert.equal(rec.rc, 1, `record leaves the approvable row pending (stderr=${rec.err})`);
  const res = F.handle(id, F.sentinel(REASON), repo);
  assert.equal(res.unapplied, "", "nothing refused");
  assertApproved(id, head, [asTest(A)], "after real record");
});
caseEnd();

// [name, seed overrides, sentinel reason, refusal pattern, repoCwd]; the classification head is
// always the fixture repo's HEAD; repoCwd "non-git" hands the handler a dir with no HEAD to read.
const REFUSALS = [
  ["mixed-with-missing", { rows: [A, M] }, REASON, /rejected/],
  ["legacy-without-head", { head: undefined }, REASON, /rejected/],
  ["no-classification", { classification: false }, REASON, /rejected/],
  ["cover-gap", { failing: [A[0], B[0], P[0], "tests/bin/extra.sh"] }, REASON, /rejected/],
  ["unrunnable-count-1", { unrunnable: 1 }, REASON, /UNRUNNABLE/],
  ["unrunnable-count-null", { unrunnable: null }, REASON, /unrunnable_count/],
  ["already-complete", { status: "complete" }, REASON, /rejected/],
  ["reason-too-short", {}, "ab", /too short/],
  ["head-unreadable", {}, REASON, /rejected|HEAD/, "non-git"],
  ["unsettled-dispatch", { unsettledDispatch: true }, REASON, /has not settled/],
  ["outcome-source-mismatch", { outcomeSource: { stem: "worker-test-runner", outcome_sha256: "0".repeat(64) } }, REASON, /outcome source/],
  ["unattributed-hits", { hits: 2 }, REASON, /HITS>0/],
  ["no-approvable-row", { rows: [P] }, REASON, /awaiting an approval/],
];

caseBegin("refusals-leave-state-unchanged", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("refusals-leave-state-unchanged", () => {
  for (const [name, extra, reason, pattern, cwd] of REFUSALS) {
    const repo = F.repo(name);
    const id = F.sid(name);
    F.seedPending(id, Object.assign({ rows: [A, B, P], head: F.headOf(repo) }, extra));
    const before = pick(F.runTests(id));
    const res = F.handle(id, F.sentinel(reason), cwd === "non-git" ? F.nonGitDir() : repo);
    assert.equal(res.handled, true, `${name}: handled`);
    assert.match(res.unapplied, pattern, `${name}: refused aloud (info=${res.info})`);
    assert.deepEqual(pick(F.runTests(id)), before, `${name}: state unchanged`);
    assert.notEqual(F.runTests(id).completion_basis, F.BASIS, `${name}: no approval basis`);
  }
});
caseEnd();

// The shortest accepted reason: 3 characters ("ab" is refused in REFUSALS).
caseBegin("approve-three-char-reason", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("approve-three-char-reason", () => {
  const repo = F.repo("abc");
  const head = F.headOf(repo);
  const id = F.sid("abc");
  F.seedPending(id, { rows: [A, P], head });
  const res = F.handle(id, F.sentinel("abc"), repo);
  assert.equal(res.unapplied, "", `nothing refused (info=${res.info})`);
  assert.equal((F.runTests(id).baseline_unobserved_accept || {}).reason, "abc", "accept.reason");
  assert.equal(F.runTests(id).completion_basis, F.BASIS, "completion_basis");
});
caseEnd();

caseBegin("refuse-head-moved-after-record", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("refuse-head-moved-after-record", () => {
  const repo = F.repo("moved");
  const h0 = F.headOf(repo);
  const id = F.sid("moved");
  F.seedPending(id, { rows: [A], head: h0 });
  const h1 = F.commit(repo, "src2.txt");
  assert.notEqual(h1, h0, "control: the fixture commit moved HEAD");
  const before = pick(F.runTests(id));
  const res = F.handle(id, F.sentinel(REASON), repo);
  assert.match(res.unapplied, /rejected/, `refused (info=${res.info})`);
  assert.match(res.unapplied, /bin\/run-tests-baseline/, "names the re-run");
  assert.deepEqual(pick(F.runTests(id)), before, "state unchanged");
});
caseEnd();

// The Bash call's cwd (toolCwd) wins over the resolved session cwd (repoCwd).
caseBegin("tool-cwd-wins-over-repo-cwd", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("tool-cwd-wins-over-repo-cwd", () => {
  const repo = F.repo("toolcwd");
  const head = F.headOf(repo);
  const id = F.sid("toolcwd");
  F.seedPending(id, { rows: [A], head });
  const bad = F.handle(id, F.sentinel(REASON), repo, F.nonGitDir());
  assert.match(bad.unapplied, /HEAD of the session's worktree cannot be read/, `toolCwd non-git refuses despite a valid repoCwd (info=${bad.info})`);
  assert.notEqual(F.runTests(id).completion_basis, F.BASIS, "no approval from the losing repoCwd");
  const ok = F.handle(id, F.sentinel(REASON), F.nonGitDir(), repo);
  assert.equal(ok.unapplied, "", `toolCwd repo approves despite a non-git repoCwd (info=${ok.info})`);
  assertApproved(id, head, [asTest(A)], "toolCwd");
});
caseEnd();

caseBegin("refuse-without-session","hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("refuse-without-session", () => {
  const res = F.handle(null, F.sentinel(REASON), F.TMP);
  assert.equal(res.handled, true, "handled");
  assert.match(res.unapplied, /session/i, "refused for the missing session");
});
caseEnd();

caseBegin("new-run-tombstones-the-approval", "hooks/workflow-run-tests/record-run.js");
test("new-run-tombstones-the-approval", () => {
  const { id } = approve("tomb");
  assert.equal(F.runTests(id).completion_basis, F.BASIS, "precondition: approved");
  const { parseContractLine } = mod("hooks/lib/run-contract.js");
  mod("hooks/workflow-run-tests/record-run.js").recordRun({
    sessionId: id, exitCode: 1, triggerCommand: "bash tests/run-all.sh", failingTests: [A[0]], hitSummary: [],
    outcomeInput: { attributed: true, contract: parseContractLine("RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0") },
  });
  const e = F.runTests(id);
  assert.equal(e.baseline_unobserved_accept ?? null, null, "baseline_unobserved_accept cleared");
  assert.equal(e.completion_basis ?? null, null, "completion_basis cleared");
  assert.notEqual(e.status, "complete", "the new failing run is not complete");
});
caseEnd();

caseBegin("annotation-key-registered", "hooks/workflow-state/state-io/events.js");
test("annotation-key-registered", () => {
  const { STEP_ANNOTATION_KEYS } = mod("hooks/workflow-state/state-io/events.js");
  const i = STEP_ANNOTATION_KEYS.indexOf("baseline_unobserved_accept");
  assert.ok(i >= 0, "baseline_unobserved_accept is in STEP_ANNOTATION_KEYS");
  assert.equal(STEP_ANNOTATION_KEYS[i - 1], "baseline_note", "it follows baseline_note");
});
caseEnd();

caseBegin("completion-note-discloses-the-approval", "hooks/lib/run-tests-completion-note.js");
test("completion-note-discloses-the-approval", () => {
  const note = mod("hooks/lib/run-tests-completion-note.js");
  assert.equal(note.BASELINE_UNOBSERVED_BASIS, F.BASIS, "basis constant exported");
  const { id } = approve("note");
  const line = String(note.completionNote(F.runTests(id)));
  assert.ok(line.startsWith("- Unverified tests: 2 failing test(s) accepted by the user without a base observation (details: "), line);
  assert.ok(line.endsWith("; reason: `" + REASON + "`)"), `ends with the reason: ${line}`);
  for (const d of [A[2], B[2]]) assert.ok(line.includes(d), `names ${d}: ${line}`);
  assert.ok(!line.includes(P[2]) && !line.includes("\n"), `one line, no proof row: ${line}`);
});
caseEnd();

caseBegin("completion-note-adds-the-auto-line", "hooks/lib/run-tests-completion-note.js");
test("completion-note-adds-the-auto-line", () => {
  const { completionNote } = mod("hooks/lib/run-tests-completion-note.js");
  const auto = ["tests/bin/c.sh", "undetermined", "skip-at-base"];
  const entries = [A, auto, P].map(([p, c, d]) => ({ path: p, class: c, detail: d, new_lines: { count: 0, head: [] } }));
  const lines = String(completionNote({ status: "complete", completion_basis: F.BASIS,
    baseline_classification: { base: "f".repeat(40), head: "e".repeat(40), entries },
    baseline_unobserved_accept: { reason: REASON, head: "e".repeat(40), tests: [asTest(A)] } })).split("\n");
  assert.equal(lines.length, 2, `two lines: ${lines.join(" | ")}`);
  assert.match(lines[0], /^- Unverified tests: 1 failing test\(s\) accepted by the user without a base observation \(details: unrunnable-at-base;/);
  assert.match(lines[1], /^- Unverified tests: 1 failing test\(s\) auto-accepted without baseline proof \(causes: skip-at-base;/);
});
caseEnd();

const MALFORMED = [
  ["paren", `echo "<<${F.SENTINEL_NAME}: base (worktree) failed>>"`],
  ["semicolon", `echo "<<${F.SENTINEL_NAME}: base; worktree failed>>"`],
  ["pipe", `echo "<<${F.SENTINEL_NAME}: base | worktree failed>>"`],
  ["amp", `echo "<<${F.SENTINEL_NAME}: base & worktree failed>>"`],
  ["backtick", `echo "<<${F.SENTINEL_NAME}: base \`worktree\` failed>>"`],
  ["no-reason", `echo "<<${F.SENTINEL_NAME}>>"`],
  ["gt", `echo "<<${F.SENTINEL_NAME}: base > worktree failed>>"`],
];
// Not the sentinel at all: chained after a valid one, or a longer name sharing its prefix.
const NOT_THE_SENTINEL = [
  ["chained", `${F.sentinel(REASON)} && echo done`],
  ["name-prefix", `echo "<<${F.SENTINEL_NAME}X: ${REASON}>>"`],
];

caseBegin("sentinel-patterns", "hooks/lib/sentinel-patterns.js");
test("sentinel-patterns", () => {
  const sp = mod("hooks/lib/sentinel-patterns.js");
  const DQ = sp.RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED_RE_DQ;
  const LIKE = sp.RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED_LOOKSLIKE_RE;
  assert.ok(DQ instanceof RegExp && LIKE instanceof RegExp, "both patterns exported");
  const good = F.sentinel(REASON);
  assert.equal(DQ.exec(good)[1], REASON, "DQ captures the reason");
  assert.equal(sp.isSentinel(good), true, "isSentinel");
  assert.equal(sp.isStrictSentinel(good), true, "isStrictSentinel");
  for (const [name, cmd] of MALFORMED) {
    assert.equal(DQ.test(cmd), false, `${name}: not the strict form`);
    assert.equal(LIKE.test(cmd), true, `${name}: looks like the sentinel`);
  }
  assert.equal(DQ.test('echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: pwsh missing>>"'), false, "not the UNRUNNABLE sentinel");
  for (const [name, cmd] of NOT_THE_SENTINEL) {
    assert.equal(DQ.test(cmd), false, `${name}: DQ misses`);
    assert.equal(LIKE.test(cmd), false, `${name}: LIKE misses`);
    assert.equal(F.handle(F.sid(name), cmd, F.TMP).handled, false, `${name}: left unhandled`);
  }
});
caseEnd();

caseBegin("malformed-sentinel-is-refused-aloud", "hooks/workflow-mark/run-tests-baseline-unobserved-handler.js");
test("malformed-sentinel-is-refused-aloud", () => {
  const id = F.sid("malformed");
  for (const [name, cmd] of MALFORMED) {
    const res = F.handle(id, cmd, F.TMP);
    assert.equal(res.handled, true, `${name}: handled`);
    assert.match(res.unapplied, new RegExp(`malformed ${F.SENTINEL_NAME}`), `${name}: advisory refusal`);
  }
  assert.equal(F.handle(id, 'echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: pwsh missing>>"', F.TMP).handled, false,
    "another sentinel is left to its own handler");
});
caseEnd();

caseBegin("workflow-mark-dispatches-the-sentinel", "hooks/workflow-mark.js");
test("workflow-mark-dispatches-the-sentinel", () => {
  const repo = F.repo("hook");
  const head = F.headOf(repo);
  const id = F.sid("hook");
  F.seedPending(id, { rows: [A], head });
  const r = runMark(bashPayload(F.sentinel(REASON), { sid: id, cwd: repo }), { cwd: repo });
  assert.doesNotMatch(r.stdout + r.stderr, /no handler for this sentinel/, "a handler is registered");
  assertApproved(id, head, [asTest(A)], "via workflow-mark.js");
});
caseEnd();

caseBegin("settings-asks-for-the-sentinel", "settings.json");
test("settings-asks-for-the-sentinel", () => {
  const settings = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8"));
  const ask = (settings.permissions && settings.permissions.ask) || [];
  assert.ok(ask.includes(`Bash(echo "<<${F.SENTINEL_NAME}: *>>")`), "permissions.ask carries the sentinel rule");
  const allow = (settings.permissions && settings.permissions.allow) || [];
  assert.ok(!allow.some((r) => r.includes(F.SENTINEL_NAME)), "the sentinel is never auto-allowed");
});
caseEnd();
