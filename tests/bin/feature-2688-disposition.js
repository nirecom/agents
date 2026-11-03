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
const sid = (label) => `dp-${label}-${process.pid}-${++serial}`;
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

// record - rows are [path, class, detail]. seed, then get seq via failing, then record.
function record(label, rows, unrunnable = 0) {
  const id = sid(label);
  seed(id, rows.map((r) => r[0]), unrunnable);
  const f = cli(["failing", "--session", id]);
  const m = /^SEQ=(\S+)/m.exec(f.out);
  const file = path.join(TMP, `${id}.tsv`);
  fs.writeFileSync(file, rows.map((r) => r.join("\t")).join("\n") + "\n");
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
