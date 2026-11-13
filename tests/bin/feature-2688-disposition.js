#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/lib/run-tests-baseline-evidence/disposition.js, bin/workflow/run-tests-baseline-evidence
// Tags: TL2, run-tests, baseline, evidence, disposition, auto-accept, table-driven, scope:issue-specific
// #2688 T1 - the record allowlist. Verify via the record CLI whether each class/detail becomes "recorded / auto-accepted /
// re-run requested (exit 8) / pending (exit 1)", plus the multi-row aggregation rule.
// TL3 gap: the end-to-end path from a real /run-tests failure to baseline is substituted by
// tests/bin/feature-2688-branch-rerun.sh on a fixture repo. Duration on a real CI host is out of scope.

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "workflow", "run-tests-baseline-evidence");
const DISPOSITION_JS = path.join(ROOT, "bin", "workflow", "lib", "run-tests-baseline-evidence", "disposition.js");

// Fixture isolation: pin the state / plans dirs to temp and unset the session ID.
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rtb-2688-disp-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
fs.mkdirSync(path.join(TMP, "cache"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.RUN_ALL_CACHE_DIR = path.join(TMP, "cache");
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { appendEvents } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "events"));
const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));

let serial = 0;
const sid = (label) => `dp-${label.replace(/[^A-Za-z0-9-]/g, "_")}-${process.pid}-${++serial}`;
const ann = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });

// seed — pending + fail + failing_tests + unrunnable_count.
function seed(id, paths, unrunnable = 0) {
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

// record - rows are [path, class, detail], written as the #2956 S8 5-column TSV
// (new_count 0, empty head). seed, then get seq via failing, then record.
function record(label, rows, unrunnable = 0) {
  const id = sid(label);
  seed(id, rows.map((r) => r[0]), unrunnable);
  return recordTsv(id, rows.map((r) => [...r, "0", "[]"].join("\t")).join("\n") + "\n");
}

// recordTsv - record an already seeded session with the TSV text as given (no padding).
function recordTsv(id, text) {
  const f = cli(["failing", "--session", id]);
  const m = /^SEQ=(\S+)/m.exec(f.out);
  const file = path.join(TMP, `${id}-${++serial}.tsv`);
  fs.writeFileSync(file, text);
  const r = cli(["record", "--session", id, "--seq", m ? m[1] : "1", "--classification", file]);
  return Object.assign(r, { id });
}

// expect - rc 0 is complete with a basis; anything else stays pending with no completion_basis.
function expectOutcome(r, rc, basis) {
  assert.equal(r.rc, rc, `exit (stderr=${r.err})`);
  const e = entry(r.id);
  if (basis === null) {
    assert.equal(e.status, "pending");
    assert.equal(e.completion_basis ?? null, null);
  } else {
    assert.equal(e.status, "complete");
    assert.equal(e.completion_basis, basis);
    assert.match(r.out, new RegExp(`^RECORDED completion_basis=${basis}$`, "m"));
  }
}

const PRE = "baseline-preexisting";
const AUTO = "baseline-auto-accepted";
// Each allowlist row (normal cases), plus unknown details and boundaries (error cases). [class, detail, exit, basis]
const ROWS = [
  ["preexisting", "base-fail", 0, PRE],
  ["preexisting-inherited", "same-base", 0, PRE],
  ["flaky-timeout-on-branch", "exit-124-then-pass", 0, AUTO],
  ["undetermined", "ambiguous-exit-137", 0, AUTO],
  ["undetermined", "ambiguous-exit-143", 0, AUTO],
  ["undetermined", "skip-at-base", 0, AUTO],
  ["undetermined", "unsupported-at-base", 0, AUTO],
  ["undetermined", "base-launcher-predates-result-conversion", 0, AUTO],
  ["undetermined", "timeout-at-base", 0, AUTO],
  ["undetermined", "root-decoy-hit-at-base", 0, AUTO],
  ["undetermined", "home-claude-ref", 0, AUTO],
  ["undetermined", "budget-exhausted", 8, null],
  ["undetermined", "worktree-create-failed", 8, null],
  ["undetermined", "exec-setup-failed", 8, null],
  ["undetermined", "state-RUNNING-at-base", 8, null],
  ["broken", "base-pass", 1, null],
  ["passes-alone-on-branch", "exit-1-then-pass", 1, null],
  ["undetermined", "missing-at-base", 1, null],
  ["undetermined", "no-such-cause-2688", 1, null],
  ["undetermined", "state-RUNNING", 1, null],
  // #2956 S8 table 1: a file-level verdict is auto for its two details only (a rename suffix is
  // stripped before matching); a new failure on the branch is never registered, so it is pending.
  ["file-verdict-preexisting", "test-file-changed", 0, AUTO],
  ["file-verdict-preexisting", "no-case-records", 0, AUTO],
  ["file-verdict-preexisting", "test-file-changed-via-rename:tests/bin/old-t.sh", 0, AUTO],
  ["file-verdict-preexisting", "no-case-records-via-rename:tests/bin/old-t.sh", 0, AUTO],
  ["file-verdict-preexisting", "fails-at-base-exit-1", 1, null],
  ["file-verdict-preexisting", "test-file-changedx", 1, null],
  ["new-case-failure-on-branch", "case-records-missing-on-branch", 1, null],
  ["new-case-failure-on-branch", "case-records-missing-at-base", 1, null],
  ["new-case-failure-on-branch", "fails-at-base-exit-1-new-lines", 1, null],
];
// ambiguous-exit-137 / -143 must match exactly. Similar values stay pending.
const AMBIGUOUS_BOUNDARY = ["ambiguous-exit-1", "ambiguous-exit-13", "ambiguous-exit-1370", "ambiguous-exit-137x"];

caseBegin("disposition-module-present", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("disposition-module-present", () => {
  assert.ok(fs.existsSync(DISPOSITION_JS), "disposition.js is not implemented yet");
});
caseEnd();

caseBegin("allow-list-row-dispositions", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("allow-list-row-dispositions", async (t) => {
  for (const [cls, detail, rc, basis] of ROWS) {
    await t.test(`${cls}/${detail}`, () => {
      expectOutcome(record(detail, [["tests/bin/t.sh", cls, detail]]), rc, basis);
    });
  }
});
caseEnd();

caseBegin("ambiguous-exit-exact-match-only", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("ambiguous-exit-exact-match-only", async (t) => {
  for (const detail of AMBIGUOUS_BOUNDARY) {
    await t.test(detail, () => {
      expectOutcome(record(detail, [["tests/bin/t.sh", "undetermined", detail]]), 1, null);
    });
  }
});
caseEnd();

caseBegin("aggregate-pending-beats-rerun", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("aggregate-pending-beats-rerun", () => {
  expectOutcome(record("agg1", [["tests/bin/a1.sh", "broken", "base-pass"],
    ["tests/bin/a2.sh", "undetermined", "budget-exhausted"]]), 1, null);
});
caseEnd();

caseBegin("aggregate-rerun-beats-auto-accept", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("aggregate-rerun-beats-auto-accept", () => {
  expectOutcome(record("agg2", [["tests/bin/b1.sh", "undetermined", "skip-at-base"],
    ["tests/bin/b2.sh", "undetermined", "worktree-create-failed"]]), 8, null);
});
caseEnd();

caseBegin("aggregate-basis-from-any-auto-accept", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("aggregate-basis-from-any-auto-accept", () => {
  expectOutcome(record("agg3", [["tests/bin/c1.sh", "preexisting", "base-fail"],
    ["tests/bin/c2.sh", "undetermined", "timeout-at-base"]]), 0, AUTO);
  expectOutcome(record("agg4", [["tests/bin/d1.sh", "preexisting", "base-fail"],
    ["tests/bin/d2.sh", "preexisting-inherited", "same-base"]]), 0, PRE);
});
caseEnd();

caseBegin("aggregate-new-case-failure-beats-file-verdict", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("aggregate-new-case-failure-beats-file-verdict", () => {
  expectOutcome(record("agg5", [["tests/bin/g1.sh", "file-verdict-preexisting", "no-case-records"],
    ["tests/bin/g2.sh", "new-case-failure-on-branch", "case-records-missing-on-branch"]]), 1, null);
  expectOutcome(record("agg6", [["tests/bin/h1.sh", "preexisting", "base-fail"],
    ["tests/bin/h2.sh", "file-verdict-preexisting", "test-file-changed"]]), 0, AUTO);
});
caseEnd();

// #2956 S8: the classification file has 5 columns; the 3-column form is a usage error.
caseBegin("three-column-classification-is-usage-error", "bin/workflow/lib/run-tests-baseline-evidence.js");
test("three-column-classification-is-usage-error", () => {
  const id = sid("three-col");
  seed(id, ["tests/bin/t.sh"]);
  const r = recordTsv(id, "tests/bin/t.sh\tpreexisting\tbase-fail\n");
  assert.equal(r.rc, 2, `stderr=${r.err}`);
  assert.equal(entry(id).status, "pending");
  expectOutcome(recordTsv(id, "tests/bin/t.sh\tpreexisting\tbase-fail\t0\t[]\n"), 0, PRE);
});
caseEnd();

// #2956 S9: a row with new lines is kept in baseline_new_lines_seen; a new run (the hook's own
// RUN_TOMBSTONES) and a later green record leave it in place, so the PR can still disclose it.
caseBegin("new-lines-seen-written-and-kept-across-runs", "bin/workflow/lib/run-tests-baseline-evidence.js");
test("new-lines-seen-written-and-kept-across-runs", () => {
  const { markStep } = require(path.join(ROOT, "hooks", "workflow-state"));
  const { RUN_TOMBSTONES } = require(path.join(ROOT, "hooks", "workflow-run-tests", "record-run.js"));
  const id = sid("nls");
  const p = "tests/bin/n1.sh";
  seed(id, [p, "tests/bin/n2.sh"]);
  const r1 = recordTsv(id, `${p}\tnew-case-failure-on-branch\tfails-at-base-exit-1-new-lines\t2\t["line L1","line L2"]\n`
    + "tests/bin/n2.sh\tpreexisting\tbase-fail\t0\t[]\n");
  expectOutcome(r1, 1, null);
  const want = (e, label) => {
    const seen = e.baseline_new_lines_seen || {};
    assert.ok(seen[p], `${label}: ${p} missing in ${JSON.stringify(seen)}`);
    assert.equal(seen[p].count, 2, label);
    assert.equal(seen[p].class, "new-case-failure-on-branch", label);
    assert.match(JSON.stringify(seen[p].head), /line L1/, label);
    assert.equal(seen["tests/bin/n2.sh"], undefined, `${label}: a row with no new lines is not kept`);
  };
  want(entry(id), "written");
  markStep(id, "run_tests", "pending", Object.assign({ run_outcome: "fail", failing_tests: [p],
    unrunnable_count: 0 }, RUN_TOMBSTONES));
  assert.equal(entry(id).baseline_classification ?? null, null, "control: the next run cleared the classification");
  want(entry(id), "after the next run");
  expectOutcome(recordTsv(id, `${p}\tpreexisting\tbase-fail\t0\t[]\n`), 0, PRE);
  want(entry(id), "after the fixed run completes");
});
caseEnd();

caseBegin("auto-accept-keeps-the-unrunnable-gate", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("auto-accept-keeps-the-unrunnable-gate", () => {
  expectOutcome(record("unr", [["tests/bin/e1.sh", "undetermined", "skip-at-base"]], 2), 1, null);
});
caseEnd();

caseBegin("listless-hint-asks-for-a-rerun", "bin/workflow/run-tests-baseline-evidence");
test("listless-hint-asks-for-a-rerun", () => {
  const id = sid("listless");
  seed(id, []);
  const r = cli(["failing", "--session", id]);
  assert.equal(r.rc, 3);
  assert.match(r.err, /\/run-tests/);
  assert.doesNotMatch(r.err, /BASELINE_ACCEPTED|baseline-accept/);
});
caseEnd();

caseBegin("accept-subcommand-removed", "bin/workflow/run-tests-baseline-evidence");
test("accept-subcommand-removed", () => {
  const id = sid("acc");
  seed(id, ["tests/bin/f1.sh"]);
  const r = cli(["accept", "--session", id]);
  assert.equal(r.rc, 2, `accept must be an unknown subcommand (usage), stderr=${r.err}`);
  assert.doesNotMatch(r.out, /RECORDED/);
  const help = cli(["--help"]);
  assert.doesNotMatch(help.out + help.err, /\baccept\b/, "usage text must not list accept");
  assert.equal(entry(id).status, "pending");
});
caseEnd();
