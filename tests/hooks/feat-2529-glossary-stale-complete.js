"use strict";
// Tests: hooks/workflow-state/effective-state.js, hooks/workflow-state/glossary-check/record.js, bin/workflow/lib/next-step/approval-reason.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, effective-state, fingerprint, scope:issue-specific
// #2529 review fix: a plan step (clarify_intent / outline / detail) already recorded complete whose
// glossary_check record the completion predicate now refuses reads pending in
// reconcileEffectiveState, resolved_from the refusal code: glossary-check-stale (a fresh --record
// restores complete), glossary-findings-unresolved (a grant restores it) and
// glossary-fingerprint-unavailable (fixing the unreadable input restores it). next-step names the
// same code with its per-code recovery. A complete with no record (recorded before #2529) keeps
// reading complete. Split from feat-2529-glossary-completion.js for the per-file time budget;
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
const { reconcileEffectiveState } = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
const { glossaryRefusalOfComplete } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/record.js"));

const effective = (s, step) => reconcileEffectiveState(F.readState(s.sid), s.sid, { repoDir: s.repo }).steps[step];
after(() => {
  restoreIsolation();
  F.finish();
});

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

caseBegin("an already-complete plan step with a stale glossary record reads pending until re-recorded", "hooks/workflow-state/effective-state.js");
test("an already-complete plan step with a stale glossary record reads pending until re-recorded", () => noNewFailures(F.failureCount, () => guarded("stale complete", () => {
  for (const step of F.RA_STEPS) {
    const s = F.setupStep(`stale-${step}`, step, F.TERM, { ownStatus: "complete" });
    const r = F.drift(s.sid, step, s.repo);
    F.check(`${step}: check-glossary-drift --record exits 0`, r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
    let eff = effective(s, step);
    F.check(`${step}: a current record keeps ${step} complete`, eff && eff.status === "complete", JSON.stringify(eff));

    // #2962: a glossary-only change stales a clean record only through a new finding.
    F.addDriftingEntry(s.repo);
    const code = glossaryRefusalOfComplete(s.sid, step, F.readState(s.sid), { repoDir: s.repo });
    F.check(`${step}: glossaryRefusalOfComplete is glossary-check-stale after the glossary changed`,
      code === "glossary-check-stale", String(code));
    eff = effective(s, step);
    F.check(`${step}: a stale record reads ${step} pending (glossary-check-stale)`,
      eff && eff.status === "pending" && eff.resolved_from === "glossary-check-stale", JSON.stringify(eff));
    F.check(`${step}: the recorded status stays complete (read-time only)`, F.statusOf(s.sid, step) === "complete", F.statusOf(s.sid, step));

    const again = F.drift(s.sid, step, s.repo);
    F.check(`${step}: re-record reports the new finding (exit 1)`, again.code === 1 && again.out.includes(F.DRIFTING_TERM),
      `exit=${again.code} ${again.out}${again.err}`);
    F.check(`${step}: a grant is recorded for the new finding`, F.grantFindings(s.sid, step) === true, "no record");
    eff = effective(s, step);
    F.check(`${step}: a fresh granted record restores ${step} complete`, eff && eff.status === "complete", JSON.stringify(eff));
  }
})));
caseEnd();

caseBegin("next-step routes a stale already-complete clarify_intent to the glossary recovery", "hooks/workflow-state/effective-state.js");
test("next-step routes a stale already-complete clarify_intent to the glossary recovery", () => noNewFailures(F.failureCount, () => guarded("next-step", () => {
  const s = F.setupStep("stale-next", "clarify_intent", F.TERM, { ownStatus: "complete" });
  F.drift(s.sid, "clarify_intent", s.repo);
  F.addDriftingEntry(s.repo);
  const r = F.runNode("bin/workflow/next-step", ["--session", s.sid], { cwd: s.repo, env: { CLAUDE_PROJECT_DIR: s.repo } });
  F.check("next-step: names glossary-check-stale for clarify_intent", /glossary-check-stale: clarify_intent/.test(r.out), `${r.out}${r.err}`);
  F.check("next-step: the hint names check-glossary-drift --step clarify_intent --record", /check-glossary-drift --session \S+ --step clarify_intent --record/.test(r.out), r.out);
  F.check("next-step: does not abort", !/ACTION=abort/.test(r.out), r.out);
})));
caseEnd();

caseBegin("an already-complete plan step without a glossary record is not demoted", "hooks/workflow-state/effective-state.js");
test("an already-complete plan step without a glossary record is not demoted", () => noNewFailures(F.failureCount, () => guarded("legacy complete", () => {
  for (const step of F.RA_STEPS) {
    const s = F.setupStep(`legacy-${step}`, step, F.TERM, { ownStatus: "complete" });
    F.touchGlossary(s.repo);
    const code = glossaryRefusalOfComplete(s.sid, step, F.readState(s.sid), { repoDir: s.repo });
    F.check(`${step}: glossaryRefusalOfComplete is null without a record`, code === null, String(code));
    const eff = effective(s, step);
    F.check(`${step}: ${step} keeps reading complete`, eff && eff.status === "complete", JSON.stringify(eff));
  }
})));
caseEnd();

caseBegin("glossaryRefusalOfComplete leaves R-S steps to the commit gate", "hooks/workflow-state/glossary-check/record.js");
test("glossaryRefusalOfComplete leaves R-S steps to the commit gate", () => noNewFailures(F.failureCount, () => guarded("rs steps", () => {
  for (const step of F.RS_STEPS) {
    const s = F.setupStep(`rs-${step}`, step, F.TERM, { ownStatus: "complete" });
    F.appendRaw(s.sid, [F.stepStatusEvent(step, "complete"),
      F.annotationEvent(step, "glossary_check", { v: 1, step, fingerprint: "0".repeat(64), inputs: {}, findings: [], grants: [], ledger_grants: [] })]);
    const code = glossaryRefusalOfComplete(s.sid, step, F.readState(s.sid), { repoDir: s.repo });
    F.check(`${step}: a stale record on ${step} is not a plan-step demotion`, code === null, String(code));
  }
})));
caseEnd();

caseBegin("an already-complete plan step with unresolved findings reads pending until granted", "hooks/workflow-state/effective-state.js");
test("an already-complete plan step with unresolved findings reads pending until granted", () => noNewFailures(F.failureCount, () => guarded("unresolved complete", () => {
  for (const step of F.RA_STEPS) {
    const s = F.setupStep(`unres-${step}`, step, F.VARIANT, { ownStatus: "complete" });
    const r = F.drift(s.sid, step, s.repo);
    F.check(`${step}: --record reports the open finding (exit 1)`, r.code === 1, `exit=${r.code} ${r.out}${r.err}`);
    let eff = effective(s, step);
    F.check(`${step}: open findings read ${step} pending (glossary-findings-unresolved)`,
      eff && eff.status === "pending" && eff.resolved_from === "glossary-findings-unresolved", JSON.stringify(eff));
    F.check(`${step}: the recorded status stays complete (read-time only)`, F.statusOf(s.sid, step) === "complete", F.statusOf(s.sid, step));
    F.check(`${step}: a grant is recorded for the finding`, F.grantFindings(s.sid, step) === true, "no record");
    eff = effective(s, step);
    F.check(`${step}: the granted record restores ${step} complete`, eff && eff.status === "complete", JSON.stringify(eff));
  }
})));
caseEnd();

caseBegin("next-step routes an unresolved already-complete clarify_intent to the accept-or-fix recovery", "bin/workflow/lib/next-step/approval-reason.js");
test("next-step routes an unresolved already-complete clarify_intent to the accept-or-fix recovery", () => noNewFailures(F.failureCount, () => guarded("next-step unresolved", () => {
  const s = F.setupStep("unres-next", "clarify_intent", F.VARIANT, { ownStatus: "complete" });
  F.drift(s.sid, "clarify_intent", s.repo);
  const r = F.runNode("bin/workflow/next-step", ["--session", s.sid], { cwd: s.repo, env: { CLAUDE_PROJECT_DIR: s.repo } });
  F.check("next-step: names glossary-findings-unresolved for clarify_intent", /glossary-findings-unresolved: clarify_intent/.test(r.out), `${r.out}${r.err}`);
  F.check("next-step: the hint names the open term", r.out.includes(`(${F.TERM})`), r.out);
  F.check("next-step: the hint gives the GLOSSARY_ACCEPTED form with the step",
    /WORKFLOW_GLOSSARY_ACCEPTED: term=<term> step=clarify_intent/.test(r.out), r.out);
  F.check("next-step: the hint says a recorded complete restores itself", /already recorded complete/.test(r.out), r.out);
  F.check("next-step: the NEXT_HINT line carries no inner single quote", /^NEXT_HINT='[^']*'$/m.test(r.out), r.out);
  F.check("next-step: does not abort", !/ACTION=abort/.test(r.out), r.out);
})));
caseEnd();

caseBegin("an already-complete plan step whose glossary inputs became unreadable reads pending", "hooks/workflow-state/effective-state.js");
test("an already-complete plan step whose glossary inputs became unreadable reads pending", () => noNewFailures(F.failureCount, () => guarded("unavailable complete", () => {
  const MISC = "docs/glossary/misc.md";
  for (const step of F.RA_STEPS) {
    const s = F.setupStep(`unavail-${step}`, step, F.TERM, { ownStatus: "complete" });
    const r = F.drift(s.sid, step, s.repo);
    F.check(`${step}: check-glossary-drift --record exits 0`, r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
    F.writeFile(s.repo, MISC, "# Glossary - misc\n");
    const code = glossaryRefusalOfComplete(s.sid, step, F.readState(s.sid), { repoDir: s.repo });
    F.check(`${step}: glossaryRefusalOfComplete is glossary-fingerprint-unavailable (a refusal, not fail-open)`,
      code === "glossary-fingerprint-unavailable", String(code));
    let eff = effective(s, step);
    F.check(`${step}: unreadable inputs read ${step} pending (glossary-fingerprint-unavailable)`,
      eff && eff.status === "pending" && eff.resolved_from === "glossary-fingerprint-unavailable", JSON.stringify(eff));
    if (step === "clarify_intent") {
      const n = F.runNode("bin/workflow/next-step", ["--session", s.sid], { cwd: s.repo, env: { CLAUDE_PROJECT_DIR: s.repo } });
      F.check("next-step: names glossary-fingerprint-unavailable for clarify_intent",
        /glossary-fingerprint-unavailable: clarify_intent/.test(n.out), `${n.out}${n.err}`);
      F.check("next-step: the hint names the unreadable cause and the re-record command",
        n.out.includes("misc.md") && /check-glossary-drift --session \S+ --step clarify_intent --record/.test(n.out), n.out);
    }
    fs.unlinkSync(path.join(s.repo, ...MISC.split("/")));
    eff = effective(s, step);
    F.check(`${step}: readable inputs restore ${step} complete`, eff && eff.status === "complete", JSON.stringify(eff));
  }
})));
caseEnd();
