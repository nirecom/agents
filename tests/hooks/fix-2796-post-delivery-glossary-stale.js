"use strict";
// Tests: hooks/workflow-state/effective-state.js, hooks/workflow-state/effective-state/post-delivery.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, effective-state, post-delivery, stop-guard, next-step, scope:common
// #2796: a post-delivery session (raw final_report complete or merge_to_main settled) keeps its complete
// plan stages: no glossary-check-stale / unapproved-complete demote, so next-step reports done.
// Pre-delivery and table-skip (WF-META) controls still demote. Fixture: tests/lib/glossary-check-fixture.js.
// TL3 gap (what this test does NOT catch):
// - the real Stop hook (C4) firing in a live session after another merge changes main's glossary.
// - a real delivered session's state file, not the v2 fixture migration.
// Closest-to-action mitigation: at WORKFLOW_USER_VERIFIED preflight, next-step reports ACTION=done.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "f2796-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
process.chdir(os.tmpdir());

// The plan-stage CONFIRM flags are read from $AGENTS_MAIN_ROOT/.env only: pin every gate on, so the
// approval re-check (case G) never depends on the developer's ambient config.
const CE = require("../lib/confirm-env-fixture");
const CFG_BASE = fs.mkdtempSync(path.join(os.tmpdir(), "f2796-cfg-"));
process.env.AGENTS_MAIN_ROOT = CE.confirmEnvRoot(CFG_BASE, { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" });
for (const k of CE.PLAN_KEYS) delete process.env[k];

const F = require("../lib/glossary-check-fixture");
const ES = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
const { VALID_STEPS } = require(path.join(F.ROOT, "hooks/workflow-state/state-io.js"));
const { resolveCurrentStep } = require(path.join(F.ROOT, "hooks/workflow-state/current-step.js"));
const { recordedCompleteRefusalOf } = require(path.join(F.ROOT, "hooks/workflow-state/completion-refusal.js"));
const { resolveSessionProfile } = require(path.join(F.ROOT, "hooks/workflow-state/session-profile.js"));
const { glossaryRefusalOfComplete } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/record.js"));

const RA_STEPS = F.RA_STAGES.map((stage) => F.STAGE_STEP[stage]);
const PRE_DELIVERY = { merge_to_main: null, cleanup: null, pre_final_report_gate: null, final_report: null };

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

// settleRest(sid, overrides): appends a raw step_status for every step the stream has not recorded
// yet — "complete" by default, overrides[step] when given; overrides[step] === null leaves it out.
function settleRest(sid, overrides) {
  const o = overrides || {};
  const raw = JSON.parse(fs.readFileSync(F.statePath(sid), "utf8"));
  const recorded = new Set(raw.events.filter((e) => e.kind === "step_status").map((e) => e.step));
  const events = [];
  for (const step of VALID_STEPS) {
    if (recorded.has(step)) continue;
    if (Object.prototype.hasOwnProperty.call(o, step) && o[step] === null) continue;
    events.push(F.stepStatusEvent(step, o[step] || "complete"));
  }
  F.appendRaw(sid, events);
}

// A WF-CODE session with intent / outline / detail complete, approved and glossary-recorded.
function prepare(tag, rest) {
  const s = F.setupStage(tag, "detail", F.TERM, { ownStatus: "complete" });
  for (const stage of F.RA_STAGES) {
    const r = F.drift(s.sid, stage, s.repo);
    F.check(`${tag}: ${stage} check-glossary-drift --record exits 0`, r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
  }
  settleRest(s.sid, rest);
  return s;
}

// A WF-META session with intent / outline complete, approved and glossary-recorded. The fixture
// writes a v2 file whose workflow_type the v4->v5 migration renames onto deliverable_type, so the
// type is set on workflow_type here (the setupStage option alone reads back as wf-code).
function prepareMeta(tag) {
  const s = F.setupStage(tag, "outline", F.TERM, { ownStatus: "complete", deliverableType: "wf-meta" });
  const raw = JSON.parse(fs.readFileSync(F.statePath(s.sid), "utf8"));
  raw.workflow_type = "wf-meta";
  fs.writeFileSync(F.statePath(s.sid), JSON.stringify(raw, null, 2));
  for (const stage of ["intent", "outline"]) {
    const r = F.drift(s.sid, stage, s.repo);
    F.check(`${tag}: ${stage} check-glossary-drift --record exits 0`, r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
  }
  return s;
}

function snapshot(s, profile) {
  return ES.reconcileEffectiveState(F.readState(s.sid), s.sid, { repoDir: s.repo, profile }).steps;
}

function nextStep(s) {
  return F.runNode("bin/workflow/next-step", ["--session", s.sid], { cwd: s.repo, env: { CLAUDE_PROJECT_DIR: s.repo } });
}

// The keep/demote decision is read-time only, kept or demoted alike: re-reading leaves the state file
// byte-for-byte as it was (no step_status is written) and yields the same snapshot. Returns the snapshot.
function expectReadOnly(tag, s, steps, profile) {
  const bytesBefore = fs.readFileSync(F.statePath(s.sid));
  const statusesBefore = VALID_STEPS.map((st) => F.statusOf(s.sid, st)).join(",");
  const eff = snapshot(s, profile);
  for (const step of steps) ES.gatedCompleteRefusal(step, "complete", F.readState(s.sid), s.sid, { repoDir: s.repo });
  const effAgain = snapshot(s, profile);
  F.check(`${tag}: re-reading yields the same snapshot (idempotent)`, JSON.stringify(effAgain) === JSON.stringify(eff), JSON.stringify(effAgain));
  F.check(`${tag}: the state file is byte-for-byte unchanged by the reads`, fs.readFileSync(F.statePath(s.sid)).equals(bytesBefore), "state file changed");
  F.check(`${tag}: recorded step statuses are unchanged by the reads`,
    VALID_STEPS.map((st) => F.statusOf(s.sid, st)).join(",") === statusesBefore, statusesBefore);
  return eff;
}

// Every reader of gatedCompleteRefusal keeps each of `steps` complete (reads stay read-only).
function expectKept(tag, s, steps, profile) {
  const state = F.readState(s.sid);
  const eff = expectReadOnly(tag, s, steps, profile);
  for (const step of steps) {
    F.check(`${tag}: ${step} reads complete from the state`,
      eff[step] && eff[step].status === "complete" && eff[step].resolved_from === "state", JSON.stringify(eff[step]));
    const why = ES.gatedCompleteRefusal(step, "complete", state, s.sid, { repoDir: s.repo });
    F.check(`${tag}: gatedCompleteRefusal(${step}) is null`, why === null, String(why));
    const refusal = recordedCompleteRefusalOf(s.sid, step, state, { repoDir: s.repo });
    F.check(`${tag}: recordedCompleteRefusalOf(${step}) is null (writer agrees)`, refusal === null, JSON.stringify(refusal));
    F.check(`${tag}: ${step} stays recorded complete`, F.statusOf(s.sid, step) === "complete", F.statusOf(s.sid, step));
  }
  F.check(`${tag}: no step reads glossary-check-stale`,
    !Object.values(eff).some((e) => e && e.resolved_from === "glossary-check-stale"), JSON.stringify(eff));
}

function expectDone(tag, s) {
  const bytesBefore = fs.readFileSync(F.statePath(s.sid));
  const r = nextStep(s);
  F.check(`${tag}: next-step exits 0`, r.code === 0, `${r.code} ${r.err}`);
  F.check(`${tag}: next-step leaves the state file byte-for-byte unchanged`, fs.readFileSync(F.statePath(s.sid)).equals(bytesBefore), "state file changed");
  F.check(`${tag}: next-step reports ACTION=done`, /^ACTION=done$/m.test(r.out), `${r.out}${r.err}`);
  F.check(`${tag}: next-step names neither make-outline-plan nor glossary-check-stale`,
    !/make-outline-plan|glossary-check-stale/.test(r.out), r.out);
}

caseBegin("A: final_report complete keeps every plan stage complete against a stale glossary", "hooks/workflow-state/effective-state.js");
guarded("A", () => {
  const s = prepare("a-final", {});
  F.touchGlossary(s.repo);
  for (const step of RA_STEPS) {
    const code = glossaryRefusalOfComplete(s.sid, step, F.readState(s.sid), { repoDir: s.repo });
    F.check(`A: glossaryRefusalOfComplete(${step}) is still glossary-check-stale (record.js unchanged)`,
      code === "glossary-check-stale", String(code));
  }
  expectKept("A", s, RA_STEPS);
  const cur = resolveCurrentStep(F.readState(s.sid), { sessionId: s.sid, repoDir: s.repo });
  F.check("A: resolveCurrentStep is null", cur === null, String(cur));
  expectDone("A", s);
});
caseEnd();

caseBegin("B: control - before merge_to_main a stale glossary still demotes every plan stage", "hooks/workflow-state/effective-state.js");
guarded("B", () => {
  const s = prepare("b-pre", PRE_DELIVERY);
  F.check("B: push_branch is recorded complete", F.statusOf(s.sid, "push_branch") === "complete", F.statusOf(s.sid, "push_branch"));
  F.touchGlossary(s.repo);
  const eff = expectReadOnly("B", s, RA_STEPS);
  for (const step of RA_STEPS) {
    F.check(`B: ${step} reads pending (glossary-check-stale)`,
      eff[step] && eff[step].status === "pending" && eff[step].resolved_from === "glossary-check-stale", JSON.stringify(eff[step]));
  }
  const cur = resolveCurrentStep(F.readState(s.sid), { sessionId: s.sid, repoDir: s.repo });
  F.check("B: resolveCurrentStep is clarify_intent", cur === "clarify_intent", String(cur));
  const r = nextStep(s);
  F.check("B: next-step reports ACTION=invoke (not done)", /^ACTION=invoke$/m.test(r.out) && !/^ACTION=done$/m.test(r.out), `${r.out}${r.err}`);
});
caseEnd();

// merge_to_main settled but final_report pending: next-step routes to the remaining delivery step (not
// done), never back to a plan stage; the state file stays byte-for-byte unchanged.
function expectNotPlanStage(tag, s) {
  const bytesBefore = fs.readFileSync(F.statePath(s.sid));
  const r = nextStep(s);
  F.check(`${tag}: next-step exits 0`, r.code === 0, `${r.code} ${r.err}`);
  F.check(`${tag}: next-step leaves the state file byte-for-byte unchanged`, fs.readFileSync(F.statePath(s.sid)).equals(bytesBefore), "state file changed");
  F.check(`${tag}: next-step does not return to a plan stage`,
    /^ACTION=invoke$/m.test(r.out) && !/^NEXT_SKILL=(clarify-intent|make-outline-plan|make-detail-plan)$/m.test(r.out) && !/glossary-check-stale/.test(r.out),
    `${r.out}${r.err}`);
}

caseBegin("C: merge_to_main complete without final_report keeps every plan stage complete", "hooks/workflow-state/effective-state.js");
guarded("C", () => {
  const s = prepare("c-merged", { cleanup: null, pre_final_report_gate: null, final_report: null });
  F.touchGlossary(s.repo);
  expectKept("C", s, RA_STEPS);
  const cur = resolveCurrentStep(F.readState(s.sid), { sessionId: s.sid, repoDir: s.repo });
  F.check("C: resolveCurrentStep is cleanup, not a plan stage", cur === "cleanup", String(cur));
  expectNotPlanStage("C", s);
});
caseEnd();

caseBegin("D: merge_to_main recorded skipped counts as post-delivery", "hooks/workflow-state/effective-state.js");
guarded("D", () => {
  const s = prepare("d-skipped", Object.assign({}, PRE_DELIVERY, { merge_to_main: "skipped" }));
  F.check("D: merge_to_main is recorded skipped", F.statusOf(s.sid, "merge_to_main") === "skipped", F.statusOf(s.sid, "merge_to_main"));
  F.touchGlossary(s.repo);
  expectKept("D", s, RA_STEPS);
  const cur = resolveCurrentStep(F.readState(s.sid), { sessionId: s.sid, repoDir: s.repo });
  F.check("D: resolveCurrentStep is cleanup, not a plan stage", cur === "cleanup", String(cur));
  expectNotPlanStage("D", s);
});
caseEnd();

caseBegin("E: control - a WF-META session whose merge_to_main is only table-skipped is still demoted", "hooks/workflow-state/effective-state.js");
guarded("E", () => {
  const s = prepareMeta("e-meta");
  const profile = resolveSessionProfile(F.readState(s.sid), s.sid, { repoDir: s.repo });
  F.check("E: the profile is wf-meta", profile.deliverableType === "wf-meta", JSON.stringify(profile));
  let eff = snapshot(s, profile);
  F.check("E: merge_to_main reads skipped through the step table",
    eff.merge_to_main && eff.merge_to_main.status === "skipped" && eff.merge_to_main.resolved_from === "table-skip",
    JSON.stringify(eff.merge_to_main));
  F.check("E: a current record keeps outline complete", eff.outline && eff.outline.status === "complete", JSON.stringify(eff.outline));
  F.touchGlossary(s.repo);
  eff = expectReadOnly("E", s, ["clarify_intent", "outline"], profile);
  for (const step of ["clarify_intent", "outline"]) {
    F.check(`E: ${step} reads pending (glossary-check-stale)`,
      eff[step] && eff[step].status === "pending" && eff[step].resolved_from === "glossary-check-stale", JSON.stringify(eff[step]));
  }
});
caseEnd();

caseBegin("F: a WF-META session with final_report complete keeps outline complete", "hooks/workflow-state/effective-state.js");
guarded("F", () => {
  const s = prepareMeta("f-meta");
  F.appendRaw(s.sid, ["research", "pre_final_report_gate", "final_report"].map((step) => F.stepStatusEvent(step, "complete")));
  F.touchGlossary(s.repo);
  const profile = resolveSessionProfile(F.readState(s.sid), s.sid, { repoDir: s.repo });
  expectKept("F", s, ["clarify_intent", "outline"], profile);
  expectDone("F", s);
});
caseEnd();

caseBegin("G: a plan artifact edited after delivery does not demote through the approval re-check", "hooks/workflow-state/effective-state.js");
guarded("G", () => {
  const edit = F.planBody("detail", F.TERM) + "\nfixture edit\n";
  const s = prepare("g-final", {});
  F.writePlan(s.sid, "detail", edit);
  F.check("G: isUnapprovedGatedComplete(detail) is true after the edit (approval no longer verifies)",
    ES.isUnapprovedGatedComplete("detail", "complete", F.readState(s.sid), s.sid) === true, "false");
  expectKept("G", s, ["detail"]);

  const c = prepare("g-pre", PRE_DELIVERY);
  F.writePlan(c.sid, "detail", edit);
  const eff = snapshot(c);
  F.check("G control: before delivery the edit reads detail pending (unapproved-complete)",
    eff.detail && eff.detail.status === "pending" && eff.detail.resolved_from === "unapproved-complete", JSON.stringify(eff.detail));
});
caseEnd();

caseBegin("H: a veto annotation on a complete outline after delivery still reports done", "hooks/workflow-state/effective-state.js");
guarded("H", () => {
  const s = prepare("h-veto", {});
  F.appendRaw(s.sid, [F.annotationEvent("outline", "skip_verdict", { verdict: "veto", source: "fixture", recorded_at: new Date().toISOString() })]);
  F.touchGlossary(s.repo);
  const eff = snapshot(s);
  F.check("H: the veto verdict is read on outline", eff.outline && eff.outline.skip_verdict_state === "veto", JSON.stringify(eff.outline));
  expectKept("H", s, ["outline", "detail"]);
  expectDone("H", s);
});
caseEnd();

// Characterization, not a requirement: the veto de-skip / post-veto-reset path stays out of the
// #2796 guard (accepted tradeoff in the intent.md: a verdict change after delivery is not expected,
// and the guard sits only at gatedCompleteRefusal). A future decision to stop the veto path for a
// post-delivery session too should flip these assertions to "outline stays skipped, ACTION=done".
caseBegin("I: a vetoed skipped outline after delivery is still de-skipped (accepted tradeoff)", "hooks/workflow-state/effective-state.js");
guarded("I", () => {
  const s = prepare("i-veto-skip", {});
  F.appendRaw(s.sid, [F.stepStatusEvent("outline", "skipped"),
    F.annotationEvent("outline", "skip_verdict", { verdict: "veto", source: "fixture", recorded_at: new Date().toISOString() })]);
  F.check("I: outline is recorded skipped", F.statusOf(s.sid, "outline") === "skipped", F.statusOf(s.sid, "outline"));
  F.check("I: final_report is recorded complete (post-delivery)", F.statusOf(s.sid, "final_report") === "complete", F.statusOf(s.sid, "final_report"));
  const eff = snapshot(s);
  F.check("I: the veto de-skips outline to pending (skip-verdict-veto)",
    eff.outline && eff.outline.status === "pending" && eff.outline.resolved_from === "skip-verdict-veto", JSON.stringify(eff.outline));
  F.check("I: detail reads pending (post-veto-reset)",
    eff.detail && eff.detail.status === "pending" && eff.detail.resolved_from === "post-veto-reset", JSON.stringify(eff.detail));
  const r = nextStep(s);
  F.check("I: next-step still reports ACTION=invoke make-outline-plan",
    /^ACTION=invoke$/m.test(r.out) && /^NEXT_SKILL=make-outline-plan$/m.test(r.out), `${r.out}${r.err}`);
});
caseEnd();

caseBegin("J: merge_to_main recorded skipped also stops the approval re-check demote", "hooks/workflow-state/effective-state.js");
guarded("J", () => {
  const s = prepare("j-skipped", Object.assign({}, PRE_DELIVERY, { merge_to_main: "skipped" }));
  F.writePlan(s.sid, "detail", F.planBody("detail", F.TERM) + "\nfixture edit\n");
  F.check("J: isUnapprovedGatedComplete(detail) is true after the edit",
    ES.isUnapprovedGatedComplete("detail", "complete", F.readState(s.sid), s.sid) === true, "false");
  expectKept("J", s, ["detail"]);
});
caseEnd();

caseBegin("K: recordedStatusOf and isPostDeliverySession judge the raw recorded status", "hooks/workflow-state/effective-state/post-delivery.js");
guarded("K", () => {
  const PD = F.mod("hooks/workflow-state/effective-state/post-delivery.js");
  if (!PD) return;
  const st = (steps) => ({ steps: Object.fromEntries(Object.entries(steps).map(([k, v]) => [k, { status: v }])) });
  F.check("K: recordedStatusOf reads the recorded status", PD.recordedStatusOf(st({ merge_to_main: "skipped" }), "merge_to_main") === "skipped", "");
  F.check("K: recordedStatusOf reads an unrecorded step as pending", PD.recordedStatusOf(st({}), "merge_to_main") === "pending", "");
  const verdicts = [
    ["final_report complete", st({ final_report: "complete" }), true],
    ["merge_to_main complete", st({ merge_to_main: "complete" }), true],
    ["merge_to_main skipped", st({ merge_to_main: "skipped" }), true],
    ["final_report skipped only", st({ final_report: "skipped" }), false],
    ["merge_to_main in_progress", st({ merge_to_main: "in_progress" }), false],
    ["nothing delivered", st({ push_branch: "complete", user_verification: "complete" }), false],
    ["WF-META, merge_to_main unrecorded", Object.assign(st({ outline: "complete" }), { deliverable_type: "wf-meta" }), false],
    ["empty state", {}, false],
    ["null state", null, false],
  ];
  for (const [name, state, want] of verdicts) {
    let got;
    try { got = PD.isPostDeliverySession(state); } catch (e) { got = `threw ${e && e.message}`; }
    F.check(`K: isPostDeliverySession(${name}) is ${want}`, got === want, String(got));
  }
  const hostile = { get steps() { throw new Error("unreadable"); } };
  let got;
  try { got = PD.isPostDeliverySession(hostile); } catch (e) { got = `threw ${e && e.message}`; }
  F.check("K: isPostDeliverySession fails toward false on an unreadable state", got === false, String(got));
});
caseEnd();

// No-behavior-change pin for evaluateResumability S1 (effective-state.js): only merge_to_main
// recorded complete reads as delivered; skipped / unrecorded fall through S1 to S3, which keeps them
// eligible here because clarify_intent's intent.md exists. Green before and after the S1 refactor.
caseBegin("L: evaluateResumability S1 treats only merge_to_main complete as delivered", "hooks/workflow-state/effective-state.js");
guarded("L", () => {
  const rows = [
    ["merge_to_main complete", { merge_to_main: "complete", cleanup: null, pre_final_report_gate: null, final_report: null }, { eligible: false, reason: "delivered" }],
    ["merge_to_main skipped", { merge_to_main: "skipped", cleanup: null, pre_final_report_gate: null, final_report: null }, { eligible: true, reason: null }],
    ["merge_to_main unrecorded", PRE_DELIVERY, { eligible: true, reason: null }],
    // The fixture's v2 file passes the v4->v5 migration, which backfills merge_to_main complete
    // (provenance "backfilled") under a recorded final_report complete: S1 reads that as delivered.
    ["final_report complete alone", Object.assign({}, PRE_DELIVERY, { final_report: "complete" }), { eligible: false, reason: "delivered" }],
  ];
  rows.forEach(([name, rest, want], i) => {
    const s = F.setupStage(`l-resume-${i}`, "detail", F.TERM, { ownStatus: "complete" });
    settleRest(s.sid, rest);
    const state = F.readState(s.sid);
    const got = ES.evaluateResumability(state);
    const m2m = state.steps && state.steps.merge_to_main;
    if (i === 3) {
      F.check("L: the migration backfilled merge_to_main complete for final_report complete alone",
        (state.events || []).some((e) => e.kind === "step_status" && e.step === "merge_to_main" && e.status === "complete" && e.provenance === "backfilled"),
        JSON.stringify(m2m));
    }
    F.check(`L: evaluateResumability(${name}) is ${JSON.stringify(want)}`,
      got && got.eligible === want.eligible && got.reason === want.reason,
      `${JSON.stringify(got)} raw-events=${JSON.stringify((state.events || []).filter((e) => e.step === "merge_to_main"))} projected=${JSON.stringify(m2m)}`);
  });
});
caseEnd();

// Main's glossary cannot be located after the record (the fixture repo loses its .git, so
// `git worktree list` fails): the sibling code glossary-fingerprint-unavailable goes through the same
// guard, so delivered keeps, pre-delivery demotes.
function breakGlossary(repo) {
  fs.rmSync(path.join(repo, ".git"), { recursive: true, force: true });
}

caseBegin("M: an unreadable glossary after delivery is kept, before delivery it still demotes", "hooks/workflow-state/effective-state.js");
guarded("M", () => {
  const pre = prepare("m-pre", PRE_DELIVERY);
  breakGlossary(pre.repo);
  const effPre = expectReadOnly("M", pre, RA_STEPS);
  for (const step of RA_STEPS) {
    F.check(`M: control - ${step} reads pending before delivery`, effPre[step] && effPre[step].status === "pending", JSON.stringify(effPre[step]));
  }
  const code = glossaryRefusalOfComplete(pre.sid, "detail", F.readState(pre.sid), { repoDir: pre.repo });
  F.check("M: control - the refusal is glossary-fingerprint-unavailable", code === "glossary-fingerprint-unavailable", String(code));
  const post = prepare("m-post", {});
  breakGlossary(post.repo);
  expectKept("M", post, RA_STEPS);
  expectDone("M", post);
});
caseEnd();

restoreIsolation();
F.finish();
