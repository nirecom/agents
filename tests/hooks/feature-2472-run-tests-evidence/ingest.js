"use strict";
// Tests: hooks/workflow-run-tests/dispatch-outcome.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, completion-evidence, scope:issue-specific
// #2472 T5 (C5): a settled but not yet ingested dispatch outcome. The advance is refused with
// run-evidence-ingest-pending, exits non-zero and ingests nothing (the refused call has no
// PostToolUse). show-dispatch-outcome.sh exits 0 and its own PostToolUse ingests the outcome;
// the next advance then answers already (pass outcome) or no-run-evidence (fail outcome).

const F = require("../../lib/run-tests-outcome-fixture");
const { check, eq, show, errText, seedPrefix, runTests, eventCount, mod } = F;

const SHOW = "skills/run-tests/scripts/show-dispatch-outcome.sh";
const verdict = () => mod("hooks/workflow-state/record-step-verdict.js");
const advanceInProcess = (sid) => verdict().recordStepVerdict(sid, "run_tests", "complete", { gate: "advance", provenance: "declared", origin: "next-step-advance", repoDir: F.tmp() });

const VARIANTS = [
  { label: "pass outcome", sid: "s-2472-ingest-pass", contract: { pass: 1 }, then: ["already", true] },
  { label: "fail outcome", sid: "s-2472-ingest-fail", contract: { pass: 0, fail: 1 }, then: ["no-run-evidence", false] },
];

function oneVariant(v) {
  const seen = {};
  try {
    seedPrefix(v.sid);
    seen.stem = F.placeOutcome(v.sid, { seq: 1, contract: v.contract });
    seen.before = eventCount(v.sid);
    seen.first = advanceInProcess(v.sid);
    seen.cli = F.advance(v.sid, "run_tests", "--complete");
    seen.afterRefusal = eventCount(v.sid);
    seen.ingestedEarly = F.isIngested(v.sid, seen.stem);
    seen.show = F.run(SHOW, ["--session", v.sid], { cwd: F.ROOT });
    const cmd = `bash ${SHOW} --session ${v.sid}`;
    F.hook(v.sid, cmd, seen.show.status, seen.show.stdout);
    seen.ingested = F.isIngested(v.sid, seen.stem);
    seen.entry = runTests(v.sid);
    seen.second = advanceInProcess(v.sid);
  } catch (e) {
    seen.error = errText(e);
  }
  return seen;
}

function ingestPendingFlow() {
  for (const v of VARIANTS) {
    const s = oneVariant(v);
    check(`T5 C5: ${v.label} — advance before ingest is refused with run-evidence-ingest-pending`, () => {
      if (s.error && !s.first) return s.error;
      eq([s.first.ok, s.first.kind], [false, "run-evidence-ingest-pending"], "ok, kind");
      return undefined;
    });
    check(`T5 C5: ${v.label} — the refused next-step --advance exits non-zero and names show-dispatch-outcome.sh`, () => {
      if (!s.cli) return s.error || "CLI did not run";
      if (s.cli.status === 0) return `exit 0; stdout: ${s.cli.stdout.slice(0, 200)}`;
      if (!(s.cli.stdout + s.cli.stderr).includes("show-dispatch-outcome.sh")) return `no show-dispatch-outcome.sh guidance: ${(s.cli.stdout + s.cli.stderr).slice(0, 300)}`;
      return undefined;
    });
    check(`T5 C5: ${v.label} — the refusals leave state unchanged and ingest nothing`, () => {
      if (s.afterRefusal === undefined) return s.error || "flow stopped early";
      eq(s.afterRefusal, s.before, "event count");
      eq(s.ingestedEarly, false, ".ingested present after the refusal");
      return undefined;
    });
    check(`T5 C5: ${v.label} — show-dispatch-outcome.sh exits 0 and its PostToolUse ingests the outcome`, () => {
      if (!s.show) return s.error || "show-dispatch-outcome.sh did not run";
      eq(s.show.status, 0, `show-dispatch-outcome.sh exit (stderr: ${s.show.stderr.slice(0, 200)})`);
      eq(s.ingested, true, ".ingested present");
      const src = s.entry && s.entry.outcome_source;
      eq(src && src.stem, s.stem, "outcome_source.stem");
      return undefined;
    });
    check(`T5 C5: ${v.label} — the advance after ingest answers ${v.then[0]}`, () => {
      if (!s.second) return s.error || "flow stopped early";
      if (v.then[0] === "already") eq([s.second.ok, s.second.already], [true, true], "ok, already");
      else eq([s.second.ok, s.second.kind], [false, "no-run-evidence"], `ok, kind (run_outcome ${show(s.entry.run_outcome)})`);
      return undefined;
    });
  }
}

// The sentinel route of the same refusal: MARK_STEP_run_tests_complete through mark-step-handler.
function markStep(sid) {
  const msgs = [];
  mod("hooks/workflow-mark/mark-step-handler.js").handle({
    cmd: 'echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"', sessionId: sid, repoCwd: F.tmp(),
    pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(`FATAL ${m}`),
  });
  return msgs.join("\n");
}

function markStepIngestPendingFlow() {
  const sid = "s-2472-ingest-mark";
  const s = {};
  try {
    seedPrefix(sid);
    s.stem = F.placeOutcome(sid, { seq: 1, contract: { pass: 1 } });
    s.before = eventCount(sid);
    s.firstMsg = markStep(sid);
    s.afterRefusal = eventCount(sid);
    s.statusAfterRefusal = runTests(sid).status;
    s.ingestedEarly = F.isIngested(sid, s.stem);
    s.show = F.run(SHOW, ["--session", sid], { cwd: F.ROOT });
    F.hook(sid, `bash ${SHOW} --session ${sid}`, s.show.status, s.show.stdout);
    s.ingested = F.isIngested(sid, s.stem);
    s.beforeSecond = eventCount(sid);
    s.secondMsg = markStep(sid);
    s.afterSecond = eventCount(sid);
    s.entry = runTests(sid);
  } catch (e) {
    s.error = errText(e);
  }
  check("T5 C5: MARK_STEP run_tests before ingest — refused as run-evidence-ingest-pending naming show-dispatch-outcome.sh", () => {
    if (s.firstMsg === undefined) return s.error || "MARK_STEP did not run";
    if (!/ingest/.test(s.firstMsg)) return `no ingest-pending refusal: ${s.firstMsg.slice(0, 300)}`;
    if (!s.firstMsg.includes("show-dispatch-outcome.sh")) return `no show-dispatch-outcome.sh guidance: ${s.firstMsg.slice(0, 300)}`;
    if (/failed to write state/.test(s.firstMsg)) return `relayed as a write failure: ${s.firstMsg}`;
    return undefined;
  });
  check("T5 C5: MARK_STEP run_tests before ingest — writes no state and ingests nothing", () => {
    if (s.afterRefusal === undefined) return s.error || "flow stopped early";
    eq(s.afterRefusal, s.before, "event count");
    if (s.statusAfterRefusal === "complete") return "run_tests became complete";
    eq(s.ingestedEarly, false, ".ingested present after the refusal");
    return undefined;
  });
  check("T5 C5: MARK_STEP run_tests after ingest of a pass outcome — passes and run_tests is complete", () => {
    if (!s.entry) return s.error || "flow stopped early";
    eq(s.ingested, true, ".ingested present");
    if (/ingest|no-run-evidence|failed to write state|FATAL/.test(s.secondMsg)) return `MARK_STEP refused: ${s.secondMsg.slice(0, 300)}`;
    eq(s.entry.status, "complete", "status");
    eq(s.afterSecond, s.beforeSecond, "event count across the already MARK_STEP");
    return undefined;
  });
}

module.exports = { ingestPendingFlow, markStepIngestPendingFlow };
