#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests/failing-list.js, hooks/lib/worker-outcome-contract.js, bin/worker-dispatch/workers/test-runner.js
// Tags: TL2, hooks, run-tests, failing-test-exits, dispatch-outcome, scope:issue-specific
// #2688 D2: run_tests records failing_test_exits, a {path: exit} map built from the run's own
// "FAIL: <path> (exit N)" lines, so a timeout (exit 124) is told apart from an assertion
// failure. The stdout route reads run-all's lines; the worker route carries them in
// worker_result.failing_exits, which the outcome contract keeps and validates.

const path = require("path");
const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const F = require("../lib/run-tests-outcome-fixture");

F.setup("f2688-failing-exits");
process.env.DEFAULT_BRANCHES = "main,master";
const { check, eq, show } = F;

const fails = () => F.totals.failed;
after(() => process.stdout.write(`Total: ${F.totals.passed} passed, ${F.totals.failed} failed\n`));

const B = "tests/hooks/b.js";
const C = "tests/hooks/c.js";
const BODY = "#!/usr/bin/env node\n\"use strict\";\n";
let n = 0;
const session = (tag) => {
  const sid = `s-2688-fx-${tag}-${++n}`;
  F.seedPrefix(sid);
  return sid;
};

function workerRun(tag, failingExits) {
  const cwd = F.makeRepo(`fx-${++n}`, { [B]: BODY, [C]: BODY }, {});
  const sid = session(tag);
  const o = { seq: 1, cwd, testArgs: [], contract: { pass: 0, fail: 2, timeout: 1 }, failing: [B, C] };
  if (failingExits !== undefined) o.failingExits = failingExits;
  const stem = F.placeOutcome(sid, o);
  F.hook(sid, "git status", 0, "");
  return { sid, stem };
}

caseBegin("stdout-route-records-failing-test-exits", "hooks/workflow-run-tests/record-run.js");
test("stdout-route-records-failing-test-exits", () => noNewFailures(fails, () => {
  const sid = session("stdout");
  const T1 = "tests/hooks/feature-2472-run-tests-evidence.js";
  const T2 = "tests/hooks/feature-2472-test-file-path.js";
  const stdout = [
    `FAIL: ${T1} (exit 124)`,
    `FAIL: ${T2} (exit 1)`,
    "RUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=1",
    "",
  ].join("\n");
  F.hook(sid, `bash ${F.ROOT_FWD}/tests/run-all.sh ${T1} ${T2}`, 1, stdout, F.ROOT_FWD);
  const rt = F.runTests(sid);
  check("D2: stdout route precondition — the failed run is recorded with its failing list", () => {
    eq(rt.status, "pending", "status");
    eq((rt.failing_tests || []).slice().sort(), [T1, T2].sort(), "failing_tests");
  });
  check("D2: stdout route — failing_test_exits maps each failing path to its exit", () => {
    eq(rt.failing_test_exits, { [T1]: 124, [T2]: 1 }, "failing_test_exits");
  });
}));
caseEnd();

caseBegin("worker-route-records-failing-test-exits", "hooks/workflow-run-tests/record-run.js");
test("worker-route-records-failing-test-exits", () => noNewFailures(fails, () => {
  const { sid, stem } = workerRun("worker", { [B]: 124, [C]: 1 });
  const rt = F.runTests(sid);
  check("D2: worker route precondition — the outcome carrying failing_exits is ingested", () => {
    if (!F.isIngested(sid, stem)) return `${stem} not ingested`;
    eq(rt.status, "pending", "status");
    return undefined;
  });
  check("D2: worker route — failing_test_exits comes from worker_result.failing_exits", () => {
    eq(rt.failing_test_exits, { [B]: 124, [C]: 1 }, "failing_test_exits");
  });

  const partial = workerRun("partial", { [B]: 124 });
  check("D2: a failing path with no known exit has no value in failing_test_exits", () => {
    eq(F.runTests(partial.sid).failing_test_exits, { [B]: 124 }, "failing_test_exits");
  });
}));
caseEnd();

caseBegin("outcome-contract-keeps-and-validates-failing-exits", "hooks/lib/worker-outcome-contract.js");
test("outcome-contract-keeps-and-validates-failing-exits", () => noNewFailures(fails, () => {
  const W = F.mod("hooks/lib/worker-outcome-contract.js");
  const base = (failingExits) => {
    const wr = {
      run_contract: { pass: 0, fail: 1, skip: 0, executed: 1, unrunnable: 0, timeout: 1 },
      failing_tests: [B], log_tail: [], summary: "fail",
    };
    if (failingExits !== undefined) wr.failing_exits = failingExits;
    return {
      schema_version: W.SCHEMA_VERSION, worker: "test-runner", stem: "worker-test-runner-1", session_id: "s",
      payload_sha256: "0".repeat(64), cwd: "", status: "fail", exit_code: 1, duration_ms: 1, worker_result: wr,
    };
  };
  const ok = W.validateOutcome(base({ [B]: 124 }));
  check("D2: a well-formed failing_exits map validates and survives buildOutcome", () => {
    if (!ok.ok) return `rejected: ${ok.reason}`;
    eq(ok.outcome.worker_result.failing_exits, { [B]: 124 }, "failing_exits");
    return undefined;
  });
  check("D2: failing_exits stays optional (absent is valid and not invented)", () => {
    const r = W.validateOutcome(base(undefined));
    if (!r.ok) return `rejected: ${r.reason}`;
    return r.outcome.worker_result.failing_exits === undefined ? undefined : `invented ${show(r.outcome.worker_result.failing_exits)}`;
  });
  for (const [label, bad] of [["a list", [B]], ["a string exit", { [B]: "124" }], ["a fractional exit", { [B]: 1.5 }]]) {
    check(`D2: failing_exits as ${label} is rejected`, () => {
      const r = W.validateOutcome(base(bad));
      if (r.ok) return "accepted";
      return /failing_exits/.test(r.reason) ? undefined : `reason does not name failing_exits: ${r.reason}`;
    });
  }
}));
caseEnd();

// A single abnormal exit value rejects the whole outcome (the "124" string is in the case above).
// NaN / Infinity do not survive JSON, so pass them to validateOutcome directly.
caseBegin("outcome-contract-rejects-abnormal-exit-values", "hooks/lib/worker-outcome-contract.js");
test("outcome-contract-rejects-abnormal-exit-values", () => noNewFailures(fails, () => {
  const W = F.mod("hooks/lib/worker-outcome-contract.js");
  const outcome = (failingExits) => ({
    schema_version: W.SCHEMA_VERSION, worker: "test-runner", stem: "worker-test-runner-1", session_id: "s",
    payload_sha256: "0".repeat(64), cwd: "", status: "fail", exit_code: 1, duration_ms: 1,
    worker_result: {
      run_contract: { pass: 0, fail: 1, skip: 0, executed: 1, unrunnable: 0, timeout: 1 },
      failing_tests: [B], log_tail: [], summary: "fail", failing_exits: failingExits,
    },
  });
  const bad = [["a negative exit", { [B]: -1 }], ["a null exit", { [B]: null }], ["a NaN exit", { [B]: NaN }],
    ["an Infinity exit", { [B]: Infinity }], ["a mixed map with one string exit", { [B]: 124, [C]: "1" }]];
  for (const [label, value] of bad) {
    check(`D2: failing_exits with ${label} is rejected`, () => {
      const r = W.validateOutcome(outcome(value));
      if (r.ok) return "accepted";
      return /failing_exits/.test(r.reason) ? undefined : `reason does not name failing_exits: ${r.reason}`;
    });
  }
}));
caseEnd();

// Malformed FAIL lines on the stdout route: a negative exit yields no value; a line whose exit is unreadable defers the whole list (null)
// and leaves no value in failing_test_exits (no partial map is built).
caseBegin("stdout-route-abnormal-fail-lines", "hooks/workflow-run-tests/failing-list.js");
test("stdout-route-abnormal-fail-lines", () => noNewFailures(fails, () => {
  const T1 = "tests/hooks/feature-2472-run-tests-evidence.js";
  const T2 = "tests/hooks/feature-2472-test-file-path.js";
  const contract = "RUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=1";
  const run = (tag, lines) => {
    const sid = session(tag);
    F.hook(sid, `bash ${F.ROOT_FWD}/tests/run-all.sh ${T1} ${T2}`, 1, [...lines, contract, ""].join("\n"), F.ROOT_FWD);
    return F.runTests(sid);
  };
  const empty = (v) => (v === undefined || v === null || Object.keys(v).length === 0 ? undefined : `partial map ${show(v)}`);

  const neg = run("neg", [`FAIL: ${T1} (exit 124)`, `FAIL: ${T2} (exit -1)`]);
  check("D2: negative exit precondition — both paths are still recorded as failing", () => {
    eq((neg.failing_tests || []).slice().sort(), [T1, T2].sort(), "failing_tests");
  });
  check("D2: a negative exit has no value in failing_test_exits", () => {
    eq(neg.failing_test_exits, { [T1]: 124 }, "failing_test_exits");
  });

  for (const [tag, line] of [["word", `FAIL: ${T2} (exit abc)`], ["noexit", `FAIL: ${T2}`], ["empty", `FAIL: ${T2} (exit )`]]) {
    const rt = run(tag, [`FAIL: ${T1} (exit 124)`, line]);
    check(`D2: malformed FAIL line (${tag}) precondition — the failing list is withheld`, () => {
      if (rt.failing_tests != null) return `failing_tests recorded: ${show(rt.failing_tests)}`;
      return undefined;
    });
    check(`D2: malformed FAIL line (${tag}) leaves no exit values`, () => empty(rt.failing_test_exits));
  }
}));
caseEnd();

caseBegin("test-runner-worker-returns-failing-exits", "bin/worker-dispatch/workers/test-runner.js");
test("test-runner-worker-returns-failing-exits", () => noNewFailures(fails, () => {
  const spawnPath = require.resolve(path.join(F.ROOT, "bin/worker-dispatch/spawn.js"));
  const runnerPath = require.resolve(path.join(F.ROOT, "bin/worker-dispatch/workers/test-runner.js"));
  const saved = require.cache[spawnPath];
  const stdout = [`FAIL: ${B} (exit 124)`, `FAIL: ${C} (exit 1)`,
    "RUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=1", ""].join("\n");
  require.cache[spawnPath] = {
    id: spawnPath, filename: spawnPath, loaded: true,
    exports: {
      run: () => ({ stdout, stderr: "", status: 1, timedOut: false, spawnError: null }),
      scriptExists: () => "/stub/tests/run-all.sh",
    },
  };
  delete require.cache[runnerPath];
  let res = null;
  try {
    res = require(runnerPath).run({ cwd: "/stub", timeout_seconds: 120, test_args: [] }, { anchors: {}, entry: {} });
  } finally {
    delete require.cache[runnerPath];
    if (saved) require.cache[spawnPath] = saved; else delete require.cache[spawnPath];
  }
  check("D2: test-runner precondition — the stubbed suite fails with both paths listed", () => {
    eq(res.status, "fail", "status");
    eq(res.failingTests, [B, C], "failingTests");
  });
  check("D2: test-runner returns failingExits beside failingTests", () => {
    eq(res.failingExits, { [B]: 124, [C]: 1 }, "failingExits");
  });
}));
caseEnd();

caseBegin("failing-list-exports-extract-failing-exits", "hooks/workflow-run-tests/failing-list.js");
test("failing-list-exports-extract-failing-exits", () => noNewFailures(fails, () => {
  const L = F.mod("hooks/workflow-run-tests/failing-list.js");
  check("D2: failing-list exports extractFailingExits beside extractFailingTests", () => {
    eq(typeof L.extractFailingTests, "function", "extractFailingTests");
    eq(typeof L.extractFailingExits, "function", "extractFailingExits");
  });
}));
caseEnd();
