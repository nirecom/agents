#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/lib/run-tests-baseline-evidence/disposition.js, bin/workflow/lib/run-tests-baseline-evidence.js, bin/workflow/lib/run-tests-baseline-evidence/approval.js, bin/workflow/lib/run-tests-baseline-evidence/preconditions.js, bin/workflow/run-tests-baseline-evidence
// Tags: TL2, run-tests, baseline, evidence, disposition, approval, table-driven, scope:issue-specific
// #3067 step 1: the approvable boundary (closed list in disposition.js), the shared unrunnable
// precondition, the approval hint `record` prints on exit 1 / 8, and `--head` recording. The
// bin/run-tests-baseline --head hand-off is TL2-covered by feature-2431-run-tests-baseline-cli-head.sh.
// TL3 gap (what this test does NOT catch):
// - The model reading the stderr hint and asking the user (skills/run-tests RNT-9).
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const LIB = path.join(ROOT, "bin", "workflow", "lib", "run-tests-baseline-evidence");
const CLI = path.join(ROOT, "bin", "workflow", "run-tests-baseline-evidence");

// Fixture isolation: pin the state / plans dirs to temp and unset the session ID.
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rtb-3067-appr-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
fs.mkdirSync(path.join(TMP, "cache"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.RUN_ALL_CACHE_DIR = path.join(TMP, "cache");
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { appendEvents } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "events"));
const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));
const disposition = () => require(path.join(LIB, "disposition.js"));
const approval = () => require(path.join(LIB, "approval.js"));
const preconditions = () => require(path.join(LIB, "preconditions.js"));

let serial = 0;
const sid = (label) => `ap-${label.replace(/[^A-Za-z0-9-]/g, "_")}-${process.pid}-${++serial}`;
const ann = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });
const HEAD40 = "0123456789abcdef0123456789abcdef01234567";
const HEAD64 = "0123456789abcdef".repeat(4);
const SENTINEL_NAME = "WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED";

// seed — pending + fail + failing_tests + unrunnable_count (null writes the tombstone).
function seed(id, paths, unrunnable) {
  appendEvents(id, [
    { kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" },
    ann("run_outcome", "fail"), ann("failing_tests", paths), ann("unrunnable_count", unrunnable)]);
}

function cli(args) {
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: TMP, encoding: "utf8", timeout: 30000 });
  return { rc: r.status, out: String(r.stdout || ""), err: String(r.stderr || "") };
}

function entry(id) {
  const s = readState(id);
  return (s && s.steps && s.steps.run_tests) || {};
}

// record — rows are [path, class, detail]; extra CLI args (e.g. --head) follow --classification.
function record(label, rows, opts = {}) {
  const id = sid(label);
  seed(id, rows.map((r) => r[0]), opts.unrunnable === undefined ? 0 : opts.unrunnable);
  const f = cli(["failing", "--session", id]);
  const m = /^SEQ=(\S+)/m.exec(f.out);
  const file = path.join(TMP, `${id}.tsv`);
  fs.writeFileSync(file, rows.map((r) => [...r, "0", "[]"].join("\t")).join("\n") + "\n");
  const r = cli(["record", "--session", id, "--seq", m ? m[1] : "1", "--classification", file,
    ...(opts.args || ["--head", HEAD40])]);
  return Object.assign(r, { id });
}

const row = (cls, detail) => ({ class: cls, detail });
// [name, class, detail, approvable]
const APPROVABLE_ROWS = [
  ["rerun-budget", "undetermined", "budget-exhausted", true],
  ["rerun-worktree", "undetermined", "worktree-create-failed", true],
  ["rerun-exec-setup", "undetermined", "exec-setup-failed", true],
  ["rerun-state", "undetermined", "state-RUNNING-at-base", true],
  ["rerun-via-rename", "undetermined", "budget-exhausted-via-rename:tests/bin/old.sh", true],
  ["rerun-state-via-rename", "undetermined", "state-foo_bar-at-base-via-rename:tests/bin/old.sh", true],
  ["unrunnable-at-base", "undetermined", "unrunnable-at-base", true],
  ["ambiguous-124", "undetermined", "ambiguous-exit-124", true],
  ["ambiguous-142", "undetermined", "ambiguous-exit-142", true],
  ["missing-at-base", "undetermined", "missing-at-base", false],
  ["compare-failed", "undetermined", "compare-failed", false],
  ["broken", "broken", "base-pass", false],
  ["new-case-missing-at-base", "new-case-failure-on-branch", "case-records-missing-at-base", false],
  ["new-case-missing-on-branch", "new-case-failure-on-branch", "case-records-missing-on-branch", false],
  ["new-case-new-lines", "new-case-failure-on-branch", "fails-at-base-exit-1-new-lines", false],
  ["passes-alone", "passes-alone-on-branch", "exit-1-then-pass", false],
  ["file-verdict-fails-at-base", "file-verdict-preexisting", "fails-at-base-exit-1", false],
  ["unknown-detail", "undetermined", "no-such-cause-3067", false],
  ["unrunnable-via-rename", "undetermined", "unrunnable-at-base-via-rename:x", false],
  ["ambiguous-124-near-miss", "undetermined", "ambiguous-exit-124X", false],
  ["ambiguous-142-near-miss", "undetermined", "ambiguous-exit-1420", false],
  ["unrunnable-near-miss", "undetermined", "unrunnable-at-baseX", false],
  ["approvable-detail-wrong-class", "broken", "unrunnable-at-base", false],
  ["proof", "preexisting", "base-fail", false],
  ["auto-class", "flaky-timeout-on-branch", "exit-124-then-pass", false],
  ["auto-file-verdict", "file-verdict-preexisting", "no-case-records", false],
];

caseBegin("approvable-table", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("approvable-table", () => {
  const { isApprovable } = disposition();
  for (const [name, cls, detail, want] of APPROVABLE_ROWS) {
    assert.equal(isApprovable(row(cls, detail)), want, `${name}: isApprovable(${cls}/${detail})`);
  }
});
caseEnd();

caseBegin("auto-details-are-never-approvable", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("auto-details-are-never-approvable", () => {
  const { isApprovable, AUTO_UNDETERMINED, APPROVABLE_UNDETERMINED, dispositionOf } = disposition();
  const auto = [...AUTO_UNDETERMINED];
  const appr = [...APPROVABLE_UNDETERMINED];
  assert.ok(auto.length >= 10, `AUTO_UNDETERMINED exported (${auto.length})`);
  assert.deepEqual([...appr].sort(), ["ambiguous-exit-124", "ambiguous-exit-142", "unrunnable-at-base"]);
  assert.deepEqual(auto.filter((d) => appr.includes(d)), [], "AUTO_UNDETERMINED and the approvable list are disjoint");
  for (const d of auto) {
    assert.equal(dispositionOf(row("undetermined", d)), "auto", `${d}: control, still auto`);
    assert.equal(isApprovable(row("undetermined", d)), false, `${d}: an auto detail is not approvable`);
  }
});
caseEnd();

// [name, rows, ok, approved details]
const AGGREGATES = [
  ["approvable-plus-missing", [row("undetermined", "unrunnable-at-base"), row("undetermined", "missing-at-base")], false, ["unrunnable-at-base"]],
  ["auto-plus-approvable", [row("undetermined", "skip-at-base"), row("undetermined", "ambiguous-exit-124")], true, ["ambiguous-exit-124"]],
  ["proof-plus-rerun", [row("preexisting", "base-fail"), row("undetermined", "budget-exhausted")], true, ["budget-exhausted"]],
  ["all-auto", [row("undetermined", "skip-at-base"), row("undetermined", "timeout-at-base")], false, []],
  ["empty", [], false, []],
];

caseBegin("approvable-aggregate", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("approvable-aggregate", () => {
  const { approvable } = disposition();
  for (const [name, rows, ok, approved] of AGGREGATES) {
    const got = approvable(rows);
    assert.equal(got.ok, ok, `${name}: ok`);
    assert.deepEqual(got.rows.map((e) => e.detail), approved, `${name}: rows are the approvable rows only`);
    if (name === "approvable-plus-missing") {
      assert.deepEqual(got.blocking.map((e) => e.detail), ["missing-at-base"], `${name}: blocking`);
    }
  }
});
caseEnd();

// [name, detail, exit]
const HINTED = [
  ["rerun-hint", "budget-exhausted", 8],
  ["rerun-state-hint", "state-RUNNING-at-base", 8],
  ["unrunnable-at-base-hint", "unrunnable-at-base", 1],
  ["ambiguous-124-hint", "ambiguous-exit-124", 1],
  ["ambiguous-142-hint", "ambiguous-exit-142", 1],
];

function expectPending(r, rc, label) {
  assert.equal(r.rc, rc, `${label}: exit (stderr=${r.err})`);
  const e = entry(r.id);
  assert.equal(e.status, "pending", `${label}: status`);
  assert.equal(e.completion_basis ?? null, null, `${label}: completion_basis`);
}

caseBegin("record-prints-approval-hint", "bin/workflow/lib/run-tests-baseline-evidence/approval.js");
test("record-prints-approval-hint", () => {
  const { APPROVAL_SENTINEL_FORM } = approval();
  assert.match(APPROVAL_SENTINEL_FORM, new RegExp(SENTINEL_NAME));
  for (const [name, detail, rc] of HINTED) {
    const r = record(name, [["tests/bin/t.sh", "undetermined", detail]]);
    expectPending(r, rc, name);
    assert.ok(r.err.includes(APPROVAL_SENTINEL_FORM), `${name}: stderr names the sentinel: ${r.err}`);
  }
});
caseEnd();

// [name, rows, unrunnable, exit]
const UNHINTED = [
  ["mixed-with-missing", [["tests/bin/a.sh", "undetermined", "unrunnable-at-base"], ["tests/bin/b.sh", "undetermined", "missing-at-base"]], 0, 1],
  ["unrunnable-count-1", [["tests/bin/a.sh", "undetermined", "unrunnable-at-base"]], 1, 1],
  ["unrunnable-count-null", [["tests/bin/a.sh", "undetermined", "ambiguous-exit-124"]], null, 1],
  ["missing-only", [["tests/bin/a.sh", "undetermined", "missing-at-base"]], 0, 1],
];

caseBegin("record-withholds-hint-when-not-approvable", "bin/workflow/lib/run-tests-baseline-evidence.js");
test("record-withholds-hint-when-not-approvable", () => {
  for (const [name, rows, unrunnable, rc] of UNHINTED) {
    const r = record(name, rows, { unrunnable });
    expectPending(r, rc, name);
    assert.doesNotMatch(r.err, new RegExp(SENTINEL_NAME), `${name}: no approval hint`);
  }
});
caseEnd();

const REASON_1 = "1 selected test(s) were UNRUNNABLE; install the missing runtime and re-run /run-tests";
const REASON_NULL = "the failing run recorded no unrunnable_count; re-run /run-tests";
// [name, unrunnable_count, want]
const PRECONDITIONS = [["zero", 0, null], ["one", 1, REASON_1], ["null", null, REASON_NULL]];

caseBegin("unrunnable-precondition-values", "bin/workflow/lib/run-tests-baseline-evidence/preconditions.js");
test("unrunnable-precondition-values", () => {
  const { unrunnablePrecondition } = preconditions();
  for (const [name, count, want] of PRECONDITIONS) {
    assert.equal(unrunnablePrecondition({ unrunnable_count: count }), want, name);
  }
  assert.match(unrunnablePrecondition({ unrunnable_count: 3 }), /^3 selected test\(s\) were UNRUNNABLE/);
});
caseEnd();

caseBegin("record-uses-the-shared-unrunnable-reason", "bin/workflow/lib/run-tests-baseline-evidence.js");
test("record-uses-the-shared-unrunnable-reason", () => {
  const { unrunnablePrecondition } = preconditions();
  for (const [name, count] of [["one", 1], ["null", null]]) {
    const r = record(`proof-${name}`, [["tests/bin/p.sh", "preexisting", "base-fail"]], { unrunnable: count });
    expectPending(r, 1, name);
    assert.ok(r.err.includes(unrunnablePrecondition({ unrunnable_count: count })), `${name}: ${r.err}`);
  }
});
caseEnd();

caseBegin("head-is-recorded-in-classification", "bin/workflow/run-tests-baseline-evidence");
test("head-is-recorded-in-classification", () => {
  // [name, head, detail, exit]: the pending path (exit 1) and the re-run path (exit 8) both record it.
  for (const [name, head, detail, rc] of [["sha1", HEAD40, "unrunnable-at-base", 1], ["sha256", HEAD64, "unrunnable-at-base", 1],
    ["budget-exhausted", HEAD40, "budget-exhausted", 8]]) {
    const r = record(`head-${name}`, [["tests/bin/h.sh", "undetermined", detail]], { args: ["--head", head] });
    expectPending(r, rc, name);
    assert.equal((entry(r.id).baseline_classification || {}).head, head, `${name}: baseline_classification.head`);
  }
});
caseEnd();

// [name, head]
const BAD_HEADS = [["upper", HEAD40.toUpperCase()], ["short", HEAD40.slice(1)], ["long", `${HEAD40}0`],
  ["symbolic", "HEAD"], ["non-hex", `${HEAD40.slice(1)}g`], ["empty", ""]];

caseBegin("bad-head-is-usage-error", "bin/workflow/run-tests-baseline-evidence");
test("bad-head-is-usage-error", () => {
  const control = record("goodhead-control", [["tests/bin/h.sh", "preexisting", "base-fail"]], { args: ["--head", HEAD40] });
  assert.equal(control.rc, 0, `control: a valid --head is accepted (stderr=${control.err})`);
  for (const [name, head] of BAD_HEADS) {
    const r = record(`badhead-${name}`, [["tests/bin/h.sh", "preexisting", "base-fail"]], { args: ["--head", head] });
    assert.equal(r.rc, 2, `${name}: exit (stderr=${r.err})`);
    assert.equal(entry(r.id).status, "pending", `${name}: state untouched`);
    assert.equal(entry(r.id).baseline_classification ?? null, null, `${name}: no classification written`);
  }
});
caseEnd();
