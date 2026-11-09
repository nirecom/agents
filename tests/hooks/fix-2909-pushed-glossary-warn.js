"use strict";
// Tests: hooks/workflow-state/effective-state.js, hooks/workflow-state/effective-state/post-delivery.js, bin/workflow/lib/next-step/glossary-after-push-note.js, bin/workflow/lib/next-step/note-lines.js
// Tags: TL2, hooks, workflow-state, glossary, glossary-check, effective-state, post-delivery, next-step, scope:issue-specific, dup-group-keep:size-hard-limit
// #2909 scenario 3: once push_branch is recorded complete (the PR is open) and the change is not
// delivered yet, a stale glossary no longer demotes the complete plan steps; next-step only warns
// with a GLOSSARY_AFTER_PUSH= line. The approval re-check still demotes, and a push_branch reset
// (#2902) or a session before the push still demotes. Split from fix-2796 for the size limit.
// TL3 gap (what this test does NOT catch):
// - the real Stop hook (C4) of a live session after another merge changes main's glossary post-push.
// Fixture: tests/lib/glossary-check-fixture.js, tests/lib/confirm-env-fixture.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "f2909-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

// The plan CONFIRM flags come from $AGENTS_MAIN_ROOT/.env only: pin every gate on (approval control).
const CE = require("../lib/confirm-env-fixture");
const CFG_BASE = fs.mkdtempSync(path.join(os.tmpdir(), "f2909-cfg-"));
process.env.AGENTS_MAIN_ROOT = CE.confirmEnvRoot(CFG_BASE, { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" });
for (const k of CE.PLAN_KEYS) delete process.env[k];

const F = require("../lib/glossary-check-fixture");
const ES = require(path.join(F.ROOT, "hooks/workflow-state/effective-state.js"));
const { VALID_STEPS } = require(path.join(F.ROOT, "hooks/workflow-state/state-io.js"));
const { resolveCurrentStep } = require(path.join(F.ROOT, "hooks/workflow-state/current-step.js"));
const { resolveSessionProfile } = require(path.join(F.ROOT, "hooks/workflow-state/session-profile.js"));

const RA_STEPS = F.RA_STEPS;
const PLAN_SKILL_RE = /^NEXT_SKILL=(clarify-intent|make-outline-plan|make-detail-plan)$/m;
const NOTE_RE = /^GLOSSARY_AFTER_PUSH=.*$/m;
// Pushed, not delivered: push_branch complete, user_verification and every delivery step unrecorded.
const PUSHED = { user_verification: null, merge_to_main: null, cleanup: null, pre_final_report_gate: null, final_report: null };
const BEFORE_PUSH = Object.assign({}, PUSHED, { push_branch: null });

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}
const verdict = (label, fn) => () => noNewFailures(F.failureCount, () => guarded(label, fn));
after(() => {
  restoreIsolation();
  F.finish();
});

// Appends a raw complete for every unrecorded step; overrides[step] === null leaves it out.
function settleRest(sid, overrides) {
  const o = overrides || {};
  const raw = JSON.parse(fs.readFileSync(F.statePath(sid), "utf8"));
  const recorded = new Set(raw.events.filter((e) => e.kind === "step_status").map((e) => e.step));
  const events = [];
  for (const step of VALID_STEPS) {
    if (recorded.has(step) || (Object.prototype.hasOwnProperty.call(o, step) && o[step] === null)) continue;
    events.push(F.stepStatusEvent(step, o[step] || "complete"));
  }
  F.appendRaw(sid, events);
}

// A WF-CODE session with the plan steps complete, approved and glossary-recorded, then `rest`.
function prepare(tag, rest) {
  const s = F.setupStep(tag, "detail", F.TERM, { ownStatus: "complete" });
  for (const step of RA_STEPS) {
    const r = F.drift(s.sid, step, s.repo);
    F.check(`${tag}: ${step} check-glossary-drift --record exits 0`, r.code === 0, `exit=${r.code} ${r.out}${r.err}`);
  }
  settleRest(s.sid, rest);
  return s;
}

const snapshot = (s) => ES.reconcileEffectiveState(F.readState(s.sid), s.sid, { repoDir: s.repo }).steps;
const nextStep = (s) => F.runNode("bin/workflow/next-step", ["--session", s.sid], { cwd: s.repo, env: { CLAUDE_PROJECT_DIR: s.repo } });
const mod = (rel) => F.mod(rel);
const noteMod = () => mod("bin/workflow/lib/next-step/glossary-after-push-note.js");

function expectDemoted(tag, s, code) {
  const eff = snapshot(s);
  for (const step of RA_STEPS) {
    F.check(`${tag}: ${step} reads pending (${code})`,
      eff[step] && eff[step].status === "pending" && eff[step].resolved_from === code, JSON.stringify(eff[step]));
  }
}

caseBegin("pushed session: a stale glossary keeps the plan steps and next-step only warns", "hooks/workflow-state/effective-state.js");
test("pushed session: a stale glossary keeps the plan steps and next-step only warns", verdict("P", () => {
  const s = prepare("p-pushed", PUSHED);
  F.check("P: push_branch is recorded complete", F.statusOf(s.sid, "push_branch") === "complete", F.statusOf(s.sid, "push_branch"));
  F.addDriftingEntry(s.repo);
  const bytesBefore = fs.readFileSync(F.statePath(s.sid));
  const eff = snapshot(s);
  for (const step of RA_STEPS) {
    F.check(`P: ${step} reads complete from the state`,
      eff[step] && eff[step].status === "complete" && eff[step].resolved_from === "state", JSON.stringify(eff[step]));
    const why = ES.gatedCompleteRefusal(step, "complete", F.readState(s.sid), s.sid, { repoDir: s.repo });
    F.check(`P: gatedCompleteRefusal(${step}) is null`, why === null, String(why));
  }
  const cur = resolveCurrentStep(F.readState(s.sid), { sessionId: s.sid, repoDir: s.repo });
  F.check("P: resolveCurrentStep is not a plan step", !!cur && !RA_STEPS.includes(cur), String(cur));
  const r = nextStep(s);
  const line = (NOTE_RE.exec(r.out) || [""])[0];
  F.check("P: next-step does not invoke a plan skill", r.code === 0 && !PLAN_SKILL_RE.test(r.out), `${r.out}${r.err}`);
  F.check("P: next-step prints the GLOSSARY_AFTER_PUSH line naming each step and glossary-check-stale",
    RA_STEPS.every((step) => line.includes(`${step}:glossary-check-stale`)) && line.includes("warn-only:the PR is open") &&
    line.includes(`check-glossary-drift --session ${s.sid} --step `) && line.endsWith("--record"), `${r.out}${r.err}`);
  F.check("P: the state file is byte-for-byte unchanged", fs.readFileSync(F.statePath(s.sid)).equals(bytesBefore), "state file changed");
  const again = nextStep(s);
  F.check("P: a second next-step prints the same line (idempotent)", (NOTE_RE.exec(again.out) || [""])[0] === line, again.out);

  const N = noteMod();
  const L = mod("bin/workflow/lib/next-step/note-lines.js");
  if (!N || !L) return;
  const state = F.readState(s.sid);
  F.check("P: glossaryAfterPushNoteLine returns the same line", N.glossaryAfterPushNoteLine(state, s.sid, s.repo) === line,
    N.glossaryAfterPushNoteLine(state, s.sid, s.repo));
  const profile = resolveSessionProfile(state, s.sid, { repoDir: s.repo });
  const lines = String(L.noteLinesOf(profile, s.sid, s.repo, state)).split("\n");
  F.check("P: noteLinesOf carries the line and no empty line", lines.includes(line) && !lines.includes(""), JSON.stringify(lines));
}));
caseEnd();

caseBegin("pushed session: an edited plan still demotes through the approval re-check", "hooks/workflow-state/effective-state.js");
test("pushed session: an edited plan still demotes through the approval re-check", verdict("U", () => {
  const s = prepare("u-pushed", PUSHED);
  F.writePlan(s.sid, "detail", F.planBody("detail", F.TERM) + "\nfixture edit\n");
  const why = ES.gatedCompleteRefusal("detail", "complete", F.readState(s.sid), s.sid, { repoDir: s.repo });
  F.check("U: gatedCompleteRefusal(detail) is unapproved-complete", why === "unapproved-complete", String(why));
  const eff = snapshot(s);
  F.check("U: detail reads pending (unapproved-complete)",
    eff.detail && eff.detail.status === "pending" && eff.detail.resolved_from === "unapproved-complete", JSON.stringify(eff.detail));
}));
caseEnd();

caseBegin("push_branch reset to pending demotes the stale plan steps again", "hooks/workflow-state/effective-state/post-delivery.js");
test("push_branch reset to pending demotes the stale plan steps again", verdict("R", () => {
  const s = prepare("r-reset", PUSHED);
  F.addDriftingEntry(s.repo);
  F.appendRaw(s.sid, [F.stepStatusEvent("push_branch", "pending")]);
  F.check("R: push_branch is recorded pending after the reset", F.statusOf(s.sid, "push_branch") === "pending", F.statusOf(s.sid, "push_branch"));
  expectDemoted("R", s, "glossary-check-stale");
  const N = noteMod();
  if (N) F.check("R: no GLOSSARY_AFTER_PUSH line", N.glossaryAfterPushNoteLine(F.readState(s.sid), s.sid, s.repo) === "", "line printed");
}));
caseEnd();

caseBegin("before push_branch a stale glossary still demotes, after delivery no warning", "bin/workflow/lib/next-step/glossary-after-push-note.js");
test("before push_branch a stale glossary still demotes, after delivery no warning", verdict("B", () => {
  const pre = prepare("b-pre", BEFORE_PUSH);
  F.addDriftingEntry(pre.repo);
  expectDemoted("B", pre, "glossary-check-stale");
  const N = noteMod();
  if (N) F.check("B: no line before the push", N.glossaryAfterPushNoteLine(F.readState(pre.sid), pre.sid, pre.repo) === "", "line printed");
  const post = prepare("b-post", {});
  F.addDriftingEntry(post.repo);
  const r = nextStep(post);
  F.check("B: a post-delivery session gets no GLOSSARY_AFTER_PUSH line", r.code === 0 && !NOTE_RE.test(r.out), `${r.out}${r.err}`);
  if (N) F.check("B: glossaryAfterPushNoteLine is empty after delivery", N.glossaryAfterPushNoteLine(F.readState(post.sid), post.sid, post.repo) === "", "line printed");
  const fresh = prepare("b-fresh", PUSHED);
  if (N) F.check("B: a pushed session with a current record gets no line", N.glossaryAfterPushNoteLine(F.readState(fresh.sid), fresh.sid, fresh.repo) === "", "line printed");
}));
caseEnd();

// Removing .git makes the glossary inputs unreadable, so the refusal is glossary-fingerprint-unavailable.
function breakGlossary(repo) {
  fs.rmSync(path.join(repo, ".git"), { recursive: true, force: true });
}

caseBegin("pushed session: an unreadable glossary is warn-only and named by its code", "hooks/workflow-state/effective-state.js");
test("pushed session: an unreadable glossary is warn-only and named by its code", verdict("U2", () => {
  const code = "glossary-fingerprint-unavailable";
  const s = prepare("u2-pushed", PUSHED);
  breakGlossary(s.repo);
  for (const step of RA_STEPS) {
    const why = ES.gatedCompleteRefusal(step, "complete", F.readState(s.sid), s.sid, { repoDir: s.repo });
    F.check(`U2: gatedCompleteRefusal(${step}) is null after the push`, why === null, String(why));
  }
  const r = nextStep(s);
  const line = (NOTE_RE.exec(r.out) || [""])[0];
  F.check(`U2: next-step does not invoke a plan skill`, r.code === 0 && !PLAN_SKILL_RE.test(r.out), `${r.out}${r.err}`);
  F.check(`U2: the GLOSSARY_AFTER_PUSH line names each step with ${code}`,
    RA_STEPS.every((step) => line.includes(`${step}:${code}`)) && !line.includes("glossary-check-stale"), `${r.out}${r.err}`);

  const pre = prepare("u2-pre", BEFORE_PUSH);
  breakGlossary(pre.repo);
  for (const step of RA_STEPS) {
    const why = ES.gatedCompleteRefusal(step, "complete", F.readState(pre.sid), pre.sid, { repoDir: pre.repo });
    F.check(`U2: control - gatedCompleteRefusal(${step}) is ${code} before the push`, why === code, String(why));
  }
  expectDemoted("U2: control", pre, code);
}));
caseEnd();

caseBegin("pushed and user-verified but not merged: still warn-only, not demoted","bin/workflow/lib/next-step/glossary-after-push-note.js");
test("pushed and user-verified but not merged: still warn-only, not demoted", verdict("V", () => {
  // fix-2796's B moved its pre-delivery premise before the push; this pins the state it left behind:
  // push_branch and user_verification complete, merge_to_main unrecorded (not post-delivery yet).
  const s = prepare("v-verified", Object.assign({}, PUSHED, { user_verification: "complete" }));
  F.check("V: user_verification is recorded complete", F.statusOf(s.sid, "user_verification") === "complete", F.statusOf(s.sid, "user_verification"));
  F.check("V: merge_to_main is unrecorded", F.statusOf(s.sid, "merge_to_main") !== "complete", F.statusOf(s.sid, "merge_to_main"));
  F.addDriftingEntry(s.repo);
  const eff = snapshot(s);
  for (const step of RA_STEPS) {
    F.check(`V: ${step} reads complete from the state`,
      eff[step] && eff[step].status === "complete" && eff[step].resolved_from === "state", JSON.stringify(eff[step]));
  }
  const r = nextStep(s);
  const line = (NOTE_RE.exec(r.out) || [""])[0];
  F.check("V: next-step does not invoke a plan skill", r.code === 0 && !PLAN_SKILL_RE.test(r.out), `${r.out}${r.err}`);
  F.check("V: next-step prints the GLOSSARY_AFTER_PUSH line", RA_STEPS.every((step) => line.includes(`${step}:glossary-check-stale`)), `${r.out}${r.err}`);
}));
caseEnd();

caseBegin("glossaryAfterPushNoteLine is advisory: an exception gives an empty line", "bin/workflow/lib/next-step/glossary-after-push-note.js");
test("glossaryAfterPushNoteLine is advisory: an exception gives an empty line", verdict("X", () => {
  const N = noteMod();
  if (!N) return;
  // push_branch reads complete and delivery reads unrecorded, so the plan step read is where it throws.
  const steps = { push_branch: { status: "complete" } };
  for (const step of RA_STEPS) Object.defineProperty(steps, step, { enumerable: true, get() { throw new Error("unreadable step"); } });
  const rows = [
    ["a plan step that throws on read", { steps }, "no-such-session", os.tmpdir()],
    ["a state whose steps getter throws", { get steps() { throw new Error("unreadable"); } }, "no-such-session", os.tmpdir()],
    ["a pushed state with a missing repo dir", { steps: { push_branch: { status: "complete" } } }, "no-such-session", path.join(os.tmpdir(), "f2909-missing-repo")],
  ];
  for (const [name, state, sid, repoDir] of rows) {
    let got;
    try { got = N.glossaryAfterPushNoteLine(state, sid, repoDir); } catch (e) { got = `threw ${e && e.message}`; }
    F.check(`X: glossaryAfterPushNoteLine(${name}) is ""`, got === "", String(got));
  }
}));
caseEnd();

caseBegin("isBranchPushedSession judges the raw recorded push_branch", "hooks/workflow-state/effective-state/post-delivery.js");
test("isBranchPushedSession judges the raw recorded push_branch", verdict("K", () => {
  const PD = mod("hooks/workflow-state/effective-state/post-delivery.js");
  if (!PD) return;
  const st = (steps) => ({ steps: Object.fromEntries(Object.entries(steps).map(([k, v]) => [k, { status: v }])) });
  const rows = [
    ["complete", st({ push_branch: "complete" }), true],
    ["in_progress", st({ push_branch: "in_progress" }), false],
    ["skipped", st({ push_branch: "skipped" }), false],
    ["unrecorded", st({}), false],
    ["empty state", {}, false],
    ["null state", null, false],
    ["unreadable state", { get steps() { throw new Error("unreadable"); } }, false],
  ];
  for (const [name, state, want] of rows) {
    let got;
    try { got = PD.isBranchPushedSession(state); } catch (e) { got = `threw ${e && e.message}`; }
    F.check(`K: isBranchPushedSession(${name}) is ${want}`, got === want, String(got));
  }
}));
caseEnd();
