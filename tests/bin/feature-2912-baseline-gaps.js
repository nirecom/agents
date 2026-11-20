#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js, bin/worker-dispatch/emit.js, bin/workflow/lib/run-tests-baseline-evidence/disposition.js, bin/workflow/run-tests-baseline-evidence
// Tags: TL2, run-tests, baseline, run-parts, failing-exits, disposition, note, boundary, scope:issue-specific
// #2912 - the cases #2688 review_tests left open, on the JS side: mergeParts keeps failingExits
// to each test's latest run (a stale exit 124 must not reach the branch stage and auto-accept as
// flaky), emit.js's failing_exits mapping, the RERUN_STATE_RE and --note sanitize boundaries,
// and the detail column as `record` stores it. Classification rows use the #2956 five-column form
// (path, class, detail, new_count, new_head_json).
// TL3 gap: a real /run-tests partial rerun feeding the baseline CLI is not run here;
// tests/bin/feature-2912-baseline-gaps.sh drives the CLI on a fixture repo.

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "workflow", "run-tests-baseline-evidence");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rtb-2912-gaps-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
fs.mkdirSync(path.join(TMP, "cache"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.RUN_ALL_CACHE_DIR = path.join(TMP, "cache");
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { mergeParts, recordParts } = require(path.join(ROOT, "hooks", "workflow-run-tests", "run-parts.js"));
const { outcomeFields, resultFromOutcome } = require(path.join(ROOT, "bin", "worker-dispatch", "emit.js"));
const { dispositionOf, sanitizeNote, NOTE_MAX } = require(
  path.join(ROOT, "bin", "workflow", "lib", "run-tests-baseline-evidence", "disposition.js"));
const { appendEvents } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "events"));
const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));
const NOTE = require(path.join(ROOT, "hooks", "lib", "run-tests-completion-note.js"));

const A = "tests/bin/a.sh";
const B = "tests/bin/b.sh";
const C = "tests/bin/c.sh";
const IV = "iv-2912";

// part - one run_parts element as recordParts builds it.
let seq = 0;
function part(selection, failing, exits) {
  return { seq: ++seq, selection, failing, exits, hits: 0, hit_ids: [], hit_summary: [], unrunnable: 0, input_version: IV };
}

let serial = 0;
const sid = (label) => `gp-${label}-${process.pid}-${++serial}`;
const ann = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });
const entry = (id) => { const s = readState(id); return (s && s.steps && s.steps.run_tests) || {}; };
const cli = (args) => {
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: TMP, encoding: "utf8", timeout: 30000 });
  return { rc: r.status, out: String(r.stdout || ""), err: String(r.stderr || "") };
};

function seed(id, paths, exits) {
  const ev = [{ kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" },
    ann("run_outcome", "fail"), ann("failing_tests", paths), ann("unrunnable_count", 0)];
  if (exits !== undefined) ev.push(ann("failing_test_exits", exits));
  appendEvents(id, ev);
}

// record - rows are [path, class, detail]; written in the five-column form with no new lines.
function record(label, rows, extra = []) {
  const id = sid(label);
  seed(id, rows.map((r) => r[0]));
  const m = /^SEQ=(\S+)/m.exec(cli(["failing", "--session", id]).out);
  const file = path.join(TMP, `${id}.tsv`);
  fs.writeFileSync(file, rows.map((r) => [r[0], r[1], r[2], "0", "[]"].join("\t")).join("\n") + "\n");
  const r = cli(["record", "--session", id, "--seq", m ? m[1] : "1", "--classification", file, ...extra]);
  return Object.assign(r, { id });
}

caseBegin("merge-parts-latest-exit-wins", "hooks/workflow-run-tests/run-parts.js");
test("merge-parts-latest-exit-wins", () => {
  const m = mergeParts([part("full", [A, B], { [A]: 124, [B]: 1 }), part([A], [A], { [A]: 1 })]);
  assert.ok(m, "a full run plus a partial rerun of the same input_version merges");
  assert.deepEqual(m.failingTests, [A, B]);
  assert.deepEqual(m.failingExits, { [A]: 1, [B]: 1 }, "a's exit is its rerun's, not the full run's 124");
});
caseEnd();

caseBegin("merge-parts-clean-rerun-drops-the-stale-exit", "hooks/workflow-run-tests/run-parts.js");
test("merge-parts-clean-rerun-drops-the-stale-exit", () => {
  const m = mergeParts([part("full", [A, B], { [A]: 124, [B]: 1 }), part([A], [], {})]);
  assert.deepEqual(m.failingTests, [B]);
  assert.deepEqual(m.failingExits, { [B]: 1 });
});
caseEnd();

caseBegin("merge-parts-unknown-rerun-exit-drops-the-stale-124", "hooks/workflow-run-tests/run-parts.js");
test("merge-parts-unknown-rerun-exit-drops-the-stale-124", () => {
  const m = mergeParts([part("full", [A, B], { [A]: 124, [B]: 1 }), part([A], [A], {})]);
  assert.deepEqual(m.failingTests, [A, B]);
  assert.equal(Object.prototype.hasOwnProperty.call(m.failingExits, A), false,
    `a failed again with no recorded exit; the full run's 124 must not survive: ${JSON.stringify(m.failingExits)}`);
  assert.deepEqual(m.failingExits, { [B]: 1 });
});
caseEnd();

caseBegin("merge-parts-exits-start-over-at-the-last-full-run", "hooks/workflow-run-tests/run-parts.js");
test("merge-parts-exits-start-over-at-the-last-full-run", () => {
  const m = mergeParts([part("full", [A], { [A]: 124 }), part([B], [B], { [B]: 2 }),
    part("full", [C], { [C]: 1 }), part([C], [], {})]);
  assert.deepEqual(m.failingTests, []);
  assert.deepEqual(m.failingExits, {}, "nothing from before the last full run leaks in");
  const keys = mergeParts([part("full", [A, B], { [A]: 124, [B]: 1 }), part([A, B], [B], { [B]: 3 })]);
  for (const k of Object.keys(keys.failingExits)) assert.ok(keys.failingTests.includes(k), `exit for non-failing ${k}`);
});
caseEnd();

caseBegin("merged-exits-reach-the-failing-list-without-the-stale-124", "bin/workflow/run-tests-baseline-evidence");
test("merged-exits-reach-the-failing-list-without-the-stale-124", () => {
  const m = mergeParts([part("full", [A, B], { [A]: 124, [B]: 124 }), part([A], [A], { [A]: 1 }), part([B], [B], {})]);
  const id = sid("chain");
  seed(id, m.failingTests, m.failingExits);
  const r = cli(["failing", "--session", id]);
  assert.equal(r.rc, 0, r.err);
  const exitLines = r.out.split("\n").filter((l) => l.startsWith("EXIT\t"));
  assert.deepEqual(exitLines, [`EXIT\t1\t${A}`], "the branch stage reads a's latest exit and no exit for b");
});
caseEnd();

const runnerEntry = { renderer: "test-runner-yaml" };
const runnerResult = (failingTests, failingExits) => ({ status: "fail", exitCode: 1, durationSeconds: 1, summary: "fail",
  failingTests, logTail: [], runContract: null, failingExits });

caseBegin("emit-failing-exits-keeps-only-listed-non-negative-integers", "bin/worker-dispatch/emit.js");
test("emit-failing-exits-keeps-only-listed-non-negative-integers", () => {
  const f = outcomeFields(runnerEntry, runnerResult([A, B, C, "tests/bin/d.sh", "tests/bin/e.sh"], {
    [A]: 124, [B]: 0, [C]: -1, "tests/bin/d.sh": 1.5, "tests/bin/e.sh": "124", "tests/bin/outside.sh": 2 }));
  assert.deepEqual(f.worker_result.failing_exits, { [A]: 124, [B]: 0 });
});
caseEnd();

caseBegin("emit-failing-exits-absent-when-nothing-maps", "bin/worker-dispatch/emit.js");
test("emit-failing-exits-absent-when-nothing-maps", async (t) => {
  for (const [label, v] of [["null", null], ["array", [124]], ["string", "124"], ["all filtered", { [A]: -1 }],
    ["outside the list", { [B]: 124 }], ["empty", {}], ["undefined", undefined]]) {
    await t.test(label, () => {
      const f = outcomeFields(runnerEntry, runnerResult([A], v));
      assert.equal(Object.prototype.hasOwnProperty.call(f.worker_result, "failing_exits"), false,
        JSON.stringify(f.worker_result.failing_exits));
    });
  }
});
caseEnd();

caseBegin("emit-failing-exits-round-trips-through-the-outcome", "bin/worker-dispatch/emit.js");
test("emit-failing-exits-round-trips-through-the-outcome", () => {
  const f = outcomeFields(runnerEntry, runnerResult([A, B], { [A]: 124, [B]: 1 }));
  assert.deepEqual(resultFromOutcome(f).failingExits, { [A]: 124, [B]: 1 });
  const none = outcomeFields(runnerEntry, runnerResult([A], null));
  assert.equal(resultFromOutcome(none).failingExits, undefined);
});
caseEnd();

caseBegin("rerun-state-re-boundaries", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("rerun-state-re-boundaries", async (t) => {
  const rows = [
    ["state-RUNNING-at-base", "rerun"], ["state-a_1-at-base", "rerun"], ["state-X-at-base", "rerun"],
    ["state--at-base", "pending"], ["state-RUN NING-at-base", "pending"], ["state-RUN-NING-at-base", "pending"],
    ["xstate-RUNNING-at-base", "pending"], ["state-RUNNING-at-basex", "pending"], ["state-RUNNING-at-base\n", "pending"],
    ["state-RUNNING", "pending"], ["STATE-RUNNING-at-base", "pending"], ["state-RÜN-at-base", "pending"],
  ];
  for (const [detail, want] of rows) {
    await t.test(JSON.stringify(detail), () => assert.equal(dispositionOf({ class: "undetermined", detail }), want));
  }
  await t.test("only the undetermined class reads the detail", () => {
    assert.equal(dispositionOf({ class: "broken", detail: "state-RUNNING-at-base" }), "pending");
    assert.equal(dispositionOf({ class: "passes-alone-on-branch", detail: "state-RUNNING-at-base" }), "pending");
  });
});
caseEnd();

caseBegin("sanitize-note-boundaries", "bin/workflow/lib/run-tests-baseline-evidence/disposition.js");
test("sanitize-note-boundaries", () => {
  assert.equal(NOTE_MAX, 200);
  assert.equal(sanitizeNote("x".repeat(200)), "x".repeat(200), "exactly NOTE_MAX is kept whole");
  assert.equal(sanitizeNote("x".repeat(201)), "x".repeat(200), "one over is cut to NOTE_MAX");
  assert.equal(sanitizeNote("x".repeat(199)), "x".repeat(199));
  assert.equal(sanitizeNote(`  ${"x".repeat(200)}  `), "x".repeat(200), "surrounding blanks do not count toward the cap");
  assert.equal(sanitizeNote("a\r\n\r\nb\rc\nd"), "a b c d", "each run of line breaks becomes one space");
  for (const blank of ["", " ", "   ", "\t", " \t ", "\r\n", "\n\n", " \r\n\t "]) {
    assert.equal(sanitizeNote(blank), null, `whitespace-only ${JSON.stringify(blank)} is no note`);
  }
  for (const nonString of [undefined, null, 0, 1, true, {}, []]) assert.equal(sanitizeNote(nonString), null);
});
caseEnd();

const PRE = "- Unverified tests:";
const autoNone = `${PRE} 1 failing test(s) auto-accepted without baseline proof (causes: exit-124-then-pass; note: (none))`;
const FLAKY = [A, "flaky-timeout-on-branch", "exit-124-then-pass"];

caseBegin("record-whitespace-only-note-is-no-note", "bin/workflow/run-tests-baseline-evidence");
test("record-whitespace-only-note-is-no-note", async (t) => {
  for (const blank of ["   ", " \t ", "\r\n"]) {
    await t.test(JSON.stringify(blank), () => {
      const r = record("blank", [FLAKY], ["--note", blank]);
      assert.equal(r.rc, 0, `a whitespace-only note is not a usage error: ${r.err}`);
      assert.equal(entry(r.id).baseline_note ?? null, null);
      assert.equal(NOTE.readCompletionNote(r.id), autoNone);
    });
  }
});
caseEnd();

caseBegin("record-note-cap-boundary", "bin/workflow/run-tests-baseline-evidence");
test("record-note-cap-boundary", () => {
  const exact = record("cap200", [FLAKY], ["--note", "y".repeat(200)]);
  assert.equal(exact.rc, 0, exact.err);
  assert.equal(entry(exact.id).baseline_note, "y".repeat(200));
  const over = record("cap201", [FLAKY], ["--note", ` ${"y".repeat(201)} `]);
  assert.equal(over.rc, 0, over.err);
  assert.equal(entry(over.id).baseline_note, "y".repeat(200));
});
caseEnd();

caseBegin("record-keeps-the-detail-column", "bin/workflow/run-tests-baseline-evidence");
test("record-keeps-the-detail-column", () => {
  const r = record("detail", [FLAKY]);
  assert.equal(r.rc, 0, `a five-column flaky row auto-accepts: ${r.err}`);
  const e = entry(r.id);
  assert.equal(e.completion_basis, "baseline-auto-accepted");
  const got = (e.baseline_classification && e.baseline_classification.entries) || [];
  assert.equal(got.length, 1);
  assert.equal(got[0].detail, "exit-124-then-pass", "the detail is the third column alone");
  const nl = got[0].new_lines;
  assert.ok(nl, "the entry carries new_lines");
  assert.deepEqual({ count: nl.count, head: [...nl.head] }, { count: 0, head: [] });
  const p = record("detail-pending", [[B, "passes-alone-on-branch", "exit-1-then-pass"]]);
  assert.equal(p.rc, 1, p.err);
  assert.equal(entry(p.id).status, "pending");
});
caseEnd();

// #3063 C1: a same-version part pushed out of the run_parts window (MAX_PARTS) must not take its
// failure or its open hold with it; a full run rebuilds the window and clears the hold.
const WINDOW = 50;
const savedBranches = process.env.DEFAULT_BRANCHES;
process.env.DEFAULT_BRANCHES = "main,master";
after(() => {
  if (savedBranches === undefined) delete process.env.DEFAULT_BRANCHES;
  else process.env.DEFAULT_BRANCHES = savedBranches;
});
const REPO = path.join(TMP, "repo").replace(/\\/g, "/");
fs.mkdirSync(REPO);
gitInit(REPO);
fs.writeFileSync(path.join(REPO, "README.md"), "fixture\n");
for (const args of [["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"],
  ["checkout", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "base"]]) {
  const g = spawnSync("git", ["-C", REPO, ...args], { encoding: "utf8", timeout: 30000 });
  if (g.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${g.stderr || g.error}`);
}

const start = (label) => {
  const id = sid(label);
  appendEvents(id, [{ kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" }]);
  return id;
};
const setParts = (id, parts) => appendEvents(id, [ann("run_parts", parts)]);
// rec - one recordParts call on the fixture repo, its run_parts persisted as record-run does.
function rec(id, args, executed, failing = []) {
  const r = recordParts({ sessionId: id, part: { args, root: REPO, cwd: REPO, results: null },
    run: { trusted: true, contract: { executed, unrunnable: 0 }, failing, exits: {}, hitCount: 0, hitSummary: [], unrunnable: 0 } });
  setParts(id, r.runParts);
  return r;
}
const greens = (n, iv) => Array.from({ length: n }, () => ({ ...part([B], [], {}), input_version: iv }));
function pad(id, n) {
  const prev = entry(id).run_parts;
  setParts(id, prev.concat(greens(n, prev[prev.length - 1].input_version)));
}
const truncatedIn = (r) => r.runParts.filter((e) => e.truncated === true).length;
let repoIv = null;
function repoVersion() {
  if (repoIv === null) repoIv = rec(start("iv"), [B], 1).runParts[0].input_version;
  assert.equal(typeof repoIv, "string", "fixture: the repo has an input_version");
  return repoIv;
}

// overflow - the first part, then WINDOW proven greens of b: the first part leaves the window.
function overflow(label, args, executed) {
  const id = start(label);
  const first = rec(id, args, executed, [A]);
  assert.equal(typeof first.runParts[0].input_version, "string", "fixture: the repo has an input_version");
  pad(id, WINDOW - 1);
  const r = rec(id, [B], 1);
  assert.equal(r.runParts.length, WINDOW);
  assert.equal(r.runParts.some((e) => e.seq === first.runParts[0].seq), false, "fixture: the first part left the window");
  return { id, first, r };
}

caseBegin("window-overflow-of-unknown-failure-holds-open", "hooks/workflow-run-tests/run-parts.js");
test("window-overflow-of-unknown-failure-holds-open", () => {
  const { first, r } = overflow("ovf-unknown", ["tests/bin"], 3);
  assert.equal(first.selection, "unknown");
  assert.ok(r.merged && r.merged.open === true, `the pushed-out unknown failure must hold run_tests open: ${JSON.stringify(r.merged)}`);
  assert.equal(r.runParts[r.runParts.length - 1].truncated, true, "the element that pushed it out is marked truncated");
});
caseEnd();

caseBegin("window-overflow-of-proven-failure-keeps-it", "hooks/workflow-run-tests/run-parts.js");
test("window-overflow-of-proven-failure-keeps-it", () => {
  const { first, r } = overflow("ovf-proven", [A], 1);
  assert.deepEqual(first.selection, [A]);
  assert.equal(truncatedIn(r), 1, "fixture: the pusher shares the pushed-out part's input_version");
  assert.equal(r.merged.open, true, `a's pushed-out failure must hold run_tests open: ${JSON.stringify(r.merged)}`);
});
caseEnd();

caseBegin("window-of-exactly-max-parts-is-not-truncated", "hooks/workflow-run-tests/run-parts.js");
test("window-of-exactly-max-parts-is-not-truncated", async (t) => {
  for (const [label, args, executed, open] of [["unknown", ["tests/bin"], 3, true], ["proven", [A], 1, false]]) {
    await t.test(label, () => {
      const id = start(`edge-${label}`);
      rec(id, args, executed, [A]);
      pad(id, WINDOW - 2);
      const r = rec(id, [B], 1);
      assert.equal(r.runParts.length, WINDOW, "nothing is pushed out");
      assert.equal(truncatedIn(r), 0);
      assert.equal(r.merged.open, open);
      assert.deepEqual(r.merged.failingTests, [A]);
    });
  }
});
caseEnd();

caseBegin("window-overflow-of-another-version-stays-closed", "hooks/workflow-run-tests/run-parts.js");
test("window-overflow-of-another-version-stays-closed", () => {
  const iv = repoVersion();
  const id = start("ovf-other");
  setParts(id, [{ ...part("unknown", [A], {}), input_version: "iv-other" }].concat(greens(WINDOW - 1, iv)));
  const r = rec(id, [B], 1);
  assert.equal(r.runParts.length, WINDOW);
  assert.equal(r.runParts.some((e) => e.input_version === "iv-other"), false, "fixture: the other-version part left the window");
  assert.equal(truncatedIn(r), 0, "pushing out another version's part truncates nothing");
  assert.equal(r.merged.open, false);
  assert.deepEqual(r.merged.failingTests, []);
});
caseEnd();

caseBegin("full-rebuild-clears-window-truncation", "hooks/workflow-run-tests/run-parts.js");
test("full-rebuild-clears-window-truncation", () => {
  const { id, r } = overflow("ovf-rebuild", ["tests/bin"], 3);
  assert.ok(r.merged && r.merged.open === true, `precondition: the overflow holds run_tests open: ${JSON.stringify(r.merged)}`);
  const full = rec(id, [], 3);
  assert.deepEqual(full.runParts.map((e) => e.selection), ["full"]);
  assert.equal(truncatedIn(full), 0);
  assert.ok(full.merged === null || full.merged.open !== true, JSON.stringify(full.merged));
  const next = rec(id, [B], 1);
  assert.equal(truncatedIn(next), 0);
  assert.equal(next.merged.open, false, "the window is no longer held open after the rebuild");
});
caseEnd();
