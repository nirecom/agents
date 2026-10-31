"use strict";
// #2828 part of tests/hooks/feat-2529-glossary-accept.js: GLOSSARY_ACCEPTED outside the plain
// "current stage, own session" path — (a) a resumed session whose plans belong to its upstream,
// (b) a finding at a stage other than the current step's, (c) the reason a refusal carries.
// Holds no case markers; the entrypoint wraps each run function in one.
// R-S stages (tests / code) are used for (b): their records cause no read-side refusal, so the
// current step stays where it is and only the commit gate is blocked by an open finding.

const fs = require("node:fs");
const path = require("node:path");

const PLAN = "# Outline\n\n## Approach\n\nMid-line the glossary-drift appears.\n";
const REASON = "user accepted this spelling";
// Same shape as RS_TARGET in tests/bin/feat-2529-glossary-drift/variants.js.
const RS_BODY = (l) => `"use strict";\n// ${l}\nmodule.exports = 1;\n`;
const RS_LINE = "Mid-line the glossary-drift appears.";
const RS_FILES = { tests: "tests/t.js", code: "bin/a.js" };

const grantsOf = (F, sid, stage) => { const r = F.recordOf(sid, stage); return (r && Array.isArray(r.grants)) ? r.grants : []; };
const oneFinding = (rec) => !!rec && Array.isArray(rec.findings) && rec.findings.length === 1;

// A resumed session D at outline whose intent / outline belong to upstream U, with one recorded
// outline finding. → { repo, sid, up, rec }
function resumedOutline(F, tag) {
  const repo = F.mkRepo(tag);
  const up = F.newSid(`${tag}-up`);
  const sid = F.newSid(tag);
  F.writeIntent(up);
  F.writePlan(up, "outline", PLAN);
  F.seedAt(sid, "outline", repo, { firstSid: up });
  const d = F.drift(sid, "outline", repo, true);
  const rec = F.recordOf(sid, "outline");
  F.check(`#2828 [${tag}] precondition: --record wrote D's outline record with one finding (from U's outline)`,
    F.reached(d) && oneFinding(rec), `code=${d.code} ${d.all}`);
  F.check(`#2828 [${tag}] precondition: the current step of D (full state) is outline`,
    F.currentStep(sid) === "outline", F.currentStep(sid));
  return { repo, sid, up, rec };
}

// (a) upstream-bound session.
function resumed(F) {
  const s = resumedOutline(F, "resumed");
  // Symptom 1: the view the handler's builder evaluated in the lock (a bare projection) has no
  // first_session_id, so the clarify_intent approval bound to U does not verify and the current
  // step falls back to clarify_intent. sessionId is passed as the handler did (current-step.js
  // hands it to gatedCompleteRefusal; omitting it is another path).
  const { projectState } = require(path.join(F.ROOT, "hooks/workflow-state/state-io/projection.js"));
  const { resolveCurrentStep } = require(path.join(F.ROOT, "hooks/workflow-state/current-step.js"));
  const { resolveSessionProfile } = require(path.join(F.ROOT, "hooks/workflow-state/session-profile.js"));
  const view = projectState(JSON.parse(F.rawState(s.sid)));
  const bare = resolveCurrentStep(view, { profile: resolveSessionProfile(view, s.sid), sessionId: s.sid });
  F.check("#2828 (a) precondition: a bare projection of D resolves the current step to clarify_intent (symptom 1)",
    bare === "clarify_intent", String(bare));

  const r = F.mark(s.sid, F.accepted(F.TERM, "", REASON), s.repo);
  const g = grantsOf(F, s.sid, "outline");
  F.check("#2828 (a) resumed session: one outline grant whose fingerprint is the record's",
    g.length === 1 && !!s.rec && g[0].fingerprint === s.rec.fingerprint && g[0].reason === REASON, `${JSON.stringify(g)} ${r.all}`);

  const t = resumedOutline(F, "resumed-stage");
  const r2 = F.mark(t.sid, F.accepted(F.TERM, "stage=outline", REASON), t.repo);
  const g2 = grantsOf(F, t.sid, "outline");
  F.check("#2828 (a) resumed session with stage=outline: one outline grant whose fingerprint is the record's",
    g2.length === 1 && !!t.rec && g2[0].fingerprint === t.rec.fingerprint, `${JSON.stringify(g2)} ${r2.all}`);
}

// A session at write_code with one recorded finding at tests (review_tests) and one at code
// (review_security), from staged tests/t.js and bin/a.js. → { repo, sid }
function rsSession(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.seedAt(sid, "write_code", repo);
  for (const rel of Object.values(RS_FILES)) F.stageFile(repo, rel, RS_BODY(RS_LINE));
  for (const stage of Object.keys(RS_FILES)) {
    const d = F.drift(sid, stage, repo, true);
    F.check(`#2828 [${tag}] precondition: --stage ${stage} --record wrote one finding`,
      F.reached(d) && oneFinding(F.recordOf(sid, stage)), `code=${d.code} ${d.all}`);
  }
  F.check(`#2828 [${tag}] precondition: the current step stays write_code (R-S records cause no read-side refusal)`,
    F.currentStep(sid) === "write_code", F.currentStep(sid));
  return { repo, sid };
}

function commitEval(F, s, stage) {
  const R = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/record.js"));
  return R.evaluateGlossaryCheck(s.sid, F.STAGE_STEP[stage], F.readState(s.sid), { mode: "commit", repoDir: s.repo });
}

// (b) a finding at a stage other than the current step's.
function otherStage(F) {
  const s = rsSession(F, "rs-stage");
  const before = commitEval(F, s, "tests");
  F.check("#2828 (b) precondition: the tests commit gate is glossary-findings-unresolved",
    !!before && before.ok === false && before.code === "glossary-findings-unresolved", JSON.stringify(before));
  const r = F.mark(s.sid, F.accepted(F.TERM, "stage=tests", REASON), s.repo);
  F.check("#2828 (b) stage=tests at write_code: one grant on the tests record",
    grantsOf(F, s.sid, "tests").length === 1, `${JSON.stringify(F.recordOf(s.sid, "tests"))} ${r.all}`);
  F.check("#2828 (b) stage=tests at write_code: the code record gets no grant",
    grantsOf(F, s.sid, "code").length === 0, JSON.stringify(F.recordOf(s.sid, "code")));
  const after = commitEval(F, s, "tests");
  F.check("#2828 (b) after the grant the tests commit gate is ok (the ARP-EXBG exit works)",
    !!after && after.ok === true, JSON.stringify(after));
  F.check("#2828 (b) the current step stays write_code after the grant",
    F.currentStep(s.sid) === "write_code", F.currentStep(s.sid));

  const b = rsSession(F, "rs-all");
  const rb = F.mark(b.sid, F.accepted(F.TERM, "", REASON), b.repo);
  F.check("#2828 (b) no discriminator at write_code: tests and code records each get one grant",
    grantsOf(F, b.sid, "tests").length === 1 && grantsOf(F, b.sid, "code").length === 1,
    `${JSON.stringify([F.recordOf(b.sid, "tests"), F.recordOf(b.sid, "code")])} ${rb.all}`);
  F.check("#2828 (b) no discriminator: the notice names finding at tests and finding at code",
    /finding at tests/.test(rb.all) && /finding at code/.test(rb.all), rb.all);

  // R-A control: an open outline finding refuses outline's recorded complete on the read side,
  // so the current step stays outline until the grant lifts it.
  const repo = F.mkRepo("ra-ctl");
  const sid = F.newSid("ra-ctl");
  F.writeIntent(sid);
  F.writePlan(sid, "outline", PLAN);
  F.seedAt(sid, "outline", repo);
  const d = F.drift(sid, "outline", repo, true);
  F.appendRaw(sid, [F.statusEvent("outline", "complete"), F.approvalEvent(sid, "outline")]);
  // repoDir: a complete R-A stage's glossary fingerprint is read from the fixture repo, not the cwd.
  const { resolveCurrentStep } = require(path.join(F.ROOT, "hooks/workflow-state/current-step.js"));
  const cur = () => String(resolveCurrentStep(F.readState(sid), { sessionId: sid, repoDir: repo }));
  F.check("#2828 (b) R-A control precondition: outline complete with an open finding still reads as the current step",
    F.reached(d) && oneFinding(F.recordOf(sid, "outline")) && cur() === "outline", `${cur()} ${d.all}`);
  const rc = F.mark(sid, F.accepted(F.TERM, "", REASON), repo);
  F.check("#2828 (b) R-A control: the outline finding is granted", grantsOf(F, sid, "outline").length === 1,
    `${JSON.stringify(F.recordOf(sid, "outline"))} ${rc.all}`);
  F.check("#2828 (b) R-A control: the current step moves on to detail", cur() === "detail", cur());

  // Tagged ledger concerns at a stage other than the current step's.
  const pair = [
    { id: "C1", discrim: "d1", text: F.tagged(F.TERM) },
    { id: "C2", discrim: "d2", text: F.tagged("Glossary-Drift", "second spelling of the same term") },
  ];
  const ledgerAt = (tag, step, format) => {
    const lr = F.mkRepo(tag);
    const ls = F.newSid(tag);
    F.writeIntent(ls);
    F.seedAt(ls, step, lr);
    F.writeLedger(ls, format, pair);
    return { repo: lr, sid: ls };
  };
  const lg = (sid, stage) => { const r = F.recordOf(sid, stage); return (r && Array.isArray(r.ledger_grants)) ? r.ledger_grants : []; };
  const ld = ledgerAt("lg-detail-at-outline", "outline", "detail-plan");
  F.mark(ld.sid, F.accepted(F.TERM, "stage=detail", REASON), ld.repo);
  F.check("#2828 (b) stage=detail at outline: both detail-plan ledger concerns are granted",
    lg(ld.sid, "detail").map((x) => x.discrim).sort().join(",") === "d1,d2", JSON.stringify(F.recordOf(ld.sid, "detail")));
  const lt = ledgerAt("lg-tests-at-write-code", "write_code", "test-review");
  F.mark(lt.sid, F.accepted(F.TERM, "stage=tests", REASON), lt.repo);
  F.check("#2828 (b) stage=tests at write_code: both test-review ledger concerns are granted",
    lg(lt.sid, "tests").map((x) => x.discrim).sort().join(",") === "d1,d2", JSON.stringify(F.recordOf(lt.sid, "tests")));
}

// (c) every refusal names its reason; the state file is unchanged.
function reasons(F) {
  const st = rsSession(F, "why-stale");
  F.stageFile(st.repo, RS_FILES.tests, RS_BODY(RS_LINE) + "// one more line\n");
  F.expectRejected("#2828 (c) R-S tests record older than the staged file", st.sid, F.accepted(F.TERM, "stage=tests", REASON), st.repo,
    /--stage tests --record/);

  const at = (tag, record) => {
    const repo = F.mkRepo(tag);
    const sid = F.newSid(tag);
    F.writeIntent(sid);
    F.writePlan(sid, "outline", PLAN);
    F.seedAt(sid, "outline", repo);
    if (record) {
      const d = F.drift(sid, "outline", repo, true);
      F.check(`#2828 [${tag}] precondition: outline record with one finding`, F.reached(d) && oneFinding(F.recordOf(sid, "outline")), d.all);
    }
    return { repo, sid };
  };
  const n = at("why-detail", false);
  F.expectRejected("#2828 (c) stage=detail with nothing pending there (current outline)", n.sid,
    F.accepted(F.TERM, "stage=detail", REASON), n.repo, /stage=detail has no open finding/);

  const p = at("why-pre", true);
  F.expectRejected("#2828 (c) a term with no finding anywhere (preemptive)", p.sid, F.accepted(F.TERM2, "", REASON), p.repo,
    /no stage holds an open finding/);
  F.expectRejected("#2828 (c) op=add with no matching provenance block", p.sid, F.accepted(F.TERM, "op=add", REASON), p.repo,
    /no glossary_provenance block matches/);

  const u = at("why-inputs", true);
  fs.rmSync(F.planPath(u.sid, "outline"));
  F.expectRejected("#2828 (c) outline inputs unreadable (plan deleted after --record)", u.sid, F.accepted(F.TERM, "", REASON), u.repo,
    /inputs could not be read/);
}

module.exports = { resumed, otherStage, reasons };
