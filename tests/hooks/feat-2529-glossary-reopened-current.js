"use strict";
// Tests: hooks/workflow-state/current-step.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/completion-refusal.js, hooks/workflow-mark/glossary-accept-handler.js, bin/workflow/lib/next-step/advance-shared.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, current-step, idempotency, scope:issue-specific
// #2529 review fix: a plan stage recorded complete that the reconciled view reopens (glossary
// refusal) is the current step for every reader — resolveCurrentStep, the WORKFLOW_GLOSSARY_ACCEPTED
// stage pick — and a re-issued --advance complete on it is refused, never answered already=true.
// Split from feat-2529-glossary-stale-complete.js for the per-file time budget;
// fixture: tests/lib/glossary-check-fixture.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2529-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const { resolveCurrentStep } = require(path.join(F.ROOT, "hooks/workflow-state/current-step.js"));
const { reconcileEffectiveState } = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));

const effective = (s, step) => reconcileEffectiveState(F.readState(s.sid), s.sid, { repoDir: s.repo }).steps[step];
const current = (s) => resolveCurrentStep(F.readState(s.sid), { sessionId: s.sid, repoDir: s.repo });
const grantsOf = (sid, stage) => ((F.recordOf(sid, stage) || {}).grants || []).length;
const { VALID_STEPS } = require(path.join(F.ROOT, "hooks/workflow-state/state-io"));
after(() => {
  restoreIsolation();
  F.finish();
});

// The fixture seeds only the gated steps; settle every other step before `step` (research, …)
// so the stage under test is the first candidate for the current step.
function setup(tag, stage, word) {
  const s = F.setupStage(tag, stage, word, { ownStatus: "complete" });
  const own = F.STAGE_STEP[stage];
  const st = F.readState(s.sid).steps || {};
  const settle = [];
  for (const step of VALID_STEPS) {
    if (step === own) break;
    if (((st[step] || {}).status || "pending") === "pending") settle.push(F.stepStatusEvent(step, "skipped"));
  }
  if (settle.length) F.appendRaw(s.sid, settle);
  return s;
}

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("resolveCurrentStep returns a plan stage the glossary refusal reopened", "hooks/workflow-state/current-step.js");
test("resolveCurrentStep returns a plan stage the glossary refusal reopened", () => noNewFailures(F.failureCount, () => guarded("current step", () => {
  for (const stage of F.RA_STAGES) {
    const step = F.STAGE_STEP[stage];
    const s = setup(`cur-${stage}`, stage, F.TERM);
    F.drift(s.sid, stage, s.repo);
    F.check(`${stage}: a current record leaves ${step} settled (current is later)`, current(s) !== step, String(current(s)));
    F.touchGlossary(s.repo);
    F.check(`${stage}: a stale record makes ${step} the current step`, current(s) === step, String(current(s)));
  }
})));
caseEnd();

caseBegin("WORKFLOW_GLOSSARY_ACCEPTED grants the finding on the reopened plan stage", "hooks/workflow-mark/glossary-accept-handler.js");
test("WORKFLOW_GLOSSARY_ACCEPTED grants the finding on the reopened plan stage", () => noNewFailures(F.failureCount, () => guarded("accept on reopened", () => {
  const s = setup("acc-outline", "outline", F.VARIANT);
  const r = F.drift(s.sid, "outline", s.repo);
  F.check("outline: --record reports the open finding (exit 1)", r.code === 1, `exit=${r.code} ${r.out}${r.err}`);
  F.check("outline: the reopened outline is the current step", current(s) === "outline", String(current(s)));
  const m = F.mark(s.sid, `echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=${F.VARIANT} — fixture accepted spelling>>"`, s.repo);
  F.check("outline: the ACCEPTED grant lands on the outline record", grantsOf(s.sid, "outline") > 0, `${m.out}${m.err}`);
  const eff = effective(s, "outline");
  F.check("outline: the granted record restores outline complete", eff && eff.status === "complete", JSON.stringify(eff));
})));
caseEnd();

caseBegin("--advance complete on a glossary-reopened plan stage is refused, not already", "hooks/workflow-state/record-step-verdict.js");
test("--advance complete on a glossary-reopened plan stage is refused, not already", () => noNewFailures(F.failureCount, () => guarded("advance refused", () => {
  const s = setup("adv-outline", "outline", F.VARIANT);
  F.drift(s.sid, "outline", s.repo);
  const r = F.advance(s.sid, "outline", s.repo);
  F.check("advance: exits non-zero", r.code !== 0, `exit=${r.code} ${r.out}${r.err}`);
  F.check("advance: names glossary-findings-unresolved", /glossary-findings-unresolved/.test(r.out + r.err), `${r.out}${r.err}`);
  F.check("advance: is not reported as already recorded", !/already/i.test(r.out + r.err), `${r.out}${r.err}`);
  F.check("advance: the recorded status stays complete", F.statusOf(s.sid, "outline") === "complete", F.statusOf(s.sid, "outline"));
  F.grantFindings(s.sid, "outline");
  const again = F.advance(s.sid, "outline", s.repo);
  F.check("advance: after the grant the repeat is an idempotent success", again.code === 0, `exit=${again.code} ${again.out}${again.err}`);
})));
caseEnd();
