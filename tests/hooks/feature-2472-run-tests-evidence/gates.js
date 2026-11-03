"use strict";
// Tests: hooks/workflow-state/record-step-verdict.js
// Tags: TL2, hooks, run-tests, workflow-state, completion-evidence, scope:issue-specific
// #2472 T5: a run_tests completion needs run evidence on every gate (sentinel / advance / mark).
// Without it the gate refuses with kind no-run-evidence and writes nothing; with a recorded
// complete (recordPass, baseline record, UNRUNNABLE accept, legacy declared pass, legacy
// baseline-user-accepted) every gate answers `already` and writes nothing.

const F = require("../../lib/run-tests-outcome-fixture");
const { check, eq, show, errText, seedPrefix, seed, status, note, runTests, eventCount, mod } = F;

const verdict = () => mod("hooks/workflow-state/record-step-verdict.js");
const GATES = ["sentinel", "advance", "mark"];
const gateOpts = (gate) => ({ gate, provenance: "observed", origin: gate === "mark" ? "next-step-mark" : "mark-step", repoDir: F.tmp() });

// Each recorded-complete shape a session can hold today, seeded the way its own writer leaves it.
const SHAPES = {
  "after recordPass": (sid) => {
    const { parseContractLine } = mod("hooks/lib/run-contract.js");
    mod("hooks/workflow-run-tests/record-run.js").recordRun({
      sessionId: sid, exitCode: 0, triggerCommand: "bash tests/run-all.sh", failingTests: null, hitSummary: [],
      outcomeInput: { attributed: true, contract: parseContractLine("RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0") },
    });
  },
  "after a baseline record": (sid) => seed(sid, [
    note("baseline_classification", { preexisting: ["tests/hooks/x.sh"] }, { origin: "run-tests-baseline-evidence" }),
    note("run_outcome", "pass", { origin: "run-tests-baseline-evidence" }),
    note("completion_basis", "baseline-preexisting", { origin: "run-tests-baseline-evidence" }),
    status("run_tests", "complete", { origin: "run-tests-baseline-evidence" }),
  ]),
  "after UNRUNNABLE accept (run_outcome unrunnable)": (sid) => seed(sid, [
    note("run_outcome", "unrunnable", { provenance: "declared", origin: "workflow-mark-run-tests-accept" }),
    note("completion_basis", "unrunnable-accepted", { provenance: "declared", origin: "workflow-mark-run-tests-accept" }),
    status("run_tests", "complete", { provenance: "declared", origin: "workflow-mark-run-tests-accept" }),
  ]),
  "legacy declared pass": (sid) => seed(sid, [
    note("run_outcome", "pass", { provenance: "declared", origin: "mark-step" }),
    status("run_tests", "complete", { provenance: "declared", origin: "mark-step" }),
  ]),
  "legacy baseline-user-accepted": (sid) => seed(sid, [
    note("baseline_accept", { tests: ["tests/hooks/x.sh"], reason: "legacy" }, { origin: "run-tests-baseline-evidence" }),
    note("run_outcome", "pass", { origin: "run-tests-baseline-evidence" }),
    note("completion_basis", "baseline-user-accepted", { origin: "run-tests-baseline-evidence" }),
    status("run_tests", "complete", { origin: "run-tests-baseline-evidence" }),
  ]),
};

let n = 0;
const sidFor = (tag) => `s-2472-${tag}-${++n}`;

// Gate call in-process; returns { res, before, after } around it.
function callGate(sid, gate) {
  const before = eventCount(sid);
  const res = verdict().recordStepVerdict(sid, "run_tests", "complete", gateOpts(gate));
  return { res, before, after: eventCount(sid) };
}

function refusesWithoutEvidence() {
  const preStates = {
    "run_tests absent": () => undefined,
    "run_tests pending with a failed run": (sid) => seed(sid, [note("run_outcome", "fail"), status("run_tests", "pending")]),
  };
  for (const [label, pre] of Object.entries(preStates)) {
    for (const gate of GATES) {
      let r = null;
      let sid = null;
      try {
        sid = sidFor(gate);
        seedPrefix(sid);
        pre(sid);
        r = callGate(sid, gate);
      } catch (e) {
        r = { error: errText(e) };
      }
      check(`T5: ${gate} gate, ${label} — completion is refused with kind no-run-evidence`, () => {
        if (r.error) return r.error;
        eq([r.res.ok, r.res.kind], [false, "no-run-evidence"], "ok, kind");
        return undefined;
      });
      check(`T5: ${gate} gate, ${label} — the refusal writes nothing`, () => {
        if (r.error) return r.error;
        eq(r.after, r.before, "event count");
        if (runTests(sid).status === "complete") return "run_tests became complete";
        return undefined;
      });
    }
  }
}

function alreadyOnRecordedComplete() {
  for (const [label, shape] of Object.entries(SHAPES)) {
    for (const gate of GATES) {
      let r = null;
      let sid = null;
      try {
        sid = sidFor("already");
        seedPrefix(sid);
        shape(sid);
        if (runTests(sid).status !== "complete") throw new Error(`precondition: seeded run_tests is ${show(runTests(sid).status)}`);
        r = callGate(sid, gate);
      } catch (e) {
        r = { error: errText(e) };
      }
      check(`T5: ${gate} gate, ${label} — answers ok with already=true and writes nothing`, () => {
        if (r.error) return r.error;
        eq([r.res.ok, r.res.already], [true, true], "ok, already");
        eq(r.after, r.before, "event count");
        return undefined;
      });
    }
  }
}

// The sentinel route end to end: mark-step-handler relays the refusal as its own message.
function markStepHandlerRelaysRefusal() {
  const msgs = [];
  let sid = null;
  let before = 0;
  let error = null;
  try {
    sid = sidFor("handler");
    seedPrefix(sid);
    before = eventCount(sid);
    mod("hooks/workflow-mark/mark-step-handler.js").handle({
      cmd: 'echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"', sessionId: sid, repoCwd: F.tmp(),
      pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(`FATAL ${m}`),
    });
  } catch (e) {
    error = errText(e);
  }
  check("T5: MARK_STEP_run_tests_complete without evidence — run_tests stays not complete", () => {
    if (error) return error;
    if (runTests(sid).status === "complete") return "run_tests became complete";
    eq(eventCount(sid), before, "event count");
    return undefined;
  });
  check("T5: MARK_STEP_run_tests_complete without evidence — the refusal is relayed as workflow-mark guidance naming /run-tests", () => {
    if (error) return error;
    const m = msgs.join("\n");
    if (!msgs.some((x) => x.startsWith("workflow-mark: "))) return `no workflow-mark message: ${show(msgs)}`;
    if (/failed to write state/.test(m)) return `relayed as a write failure: ${m}`;
    if (!/run-tests/.test(m)) return `no /run-tests guidance: ${m}`;
    return undefined;
  });
}

// The refusal reaches the model through the CLI: next-step --advance exits non-zero.
function advanceCliRefuses() {
  let r = null;
  let sid = null;
  let before = 0;
  try {
    sid = sidFor("cli");
    seedPrefix(sid);
    before = eventCount(sid);
    r = F.advance(sid, "run_tests", "--complete");
  } catch (e) {
    r = { error: errText(e) };
  }
  check("T5: next-step --advance --step run_tests --complete without evidence — exits non-zero and writes nothing", () => {
    if (r.error) return r.error;
    if (r.status === 0) return `exit 0; stdout: ${r.stdout.slice(0, 200)}`;
    eq(eventCount(sid), before, "event count");
    return undefined;
  });
}

// checkRunTestsCompletion(sessionId, state) is the one owner of the run_tests rule.
function evidenceModuleContract() {
  let m = null;
  let error = null;
  try {
    m = mod("hooks/workflow-state/record-step-verdict/run-tests-evidence.js");
  } catch (e) {
    error = `run-tests-evidence.js not loadable: ${errText(e).split("\n")[0]}`;
  }
  check("T5: run-tests-evidence.checkRunTestsCompletion — complete is already, no evidence is no-run-evidence", () => {
    if (error) return error;
    const sid = sidFor("unit");
    seedPrefix(sid);
    const st = mod("hooks/workflow-state").readState(sid);
    const none = m.checkRunTestsCompletion(sid, st);
    eq([none.ok, none.kind], [false, "no-run-evidence"], "no evidence: ok, kind");
    SHAPES["legacy declared pass"](sid);
    const done = m.checkRunTestsCompletion(sid, mod("hooks/workflow-state").readState(sid));
    eq([done.ok, done.already], [true, true], "complete: ok, already");
    return undefined;
  });
}

module.exports = { refusesWithoutEvidence, alreadyOnRecordedComplete, markStepHandlerRelaysRefusal, advanceCliRefuses, evidenceModuleContract, sidFor, gateOpts };
