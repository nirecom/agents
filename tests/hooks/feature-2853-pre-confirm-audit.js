"use strict";
// tests/hooks/feature-2853-pre-confirm-audit.js
// Tests: hooks/lib/pre-confirm-audit.js, bin/workflow/lib/next-step/gate-mode.js, hooks/lib/audit-triggers.js, hooks/supervisor-guard/collect-audit-triggers.js
// Tags: scope:issue-specific, TL1, TL2, supervisor-audit, pre-confirm-audit, next-step-gate, audit-triggers, confirm-gate
// #2853: TR1-3 leave the step-completion edge table; the plan stage's `next-step --gate` arms the
// stage's audit (audit-wait) and answers from its verdict on the current plan (ask / proceed,
// audit-block) before the CONFIRM dialog. (a)-(j) run the real gate CLI on fixture state (TL2);
// (k)-(n) call decideAuditGate with stubbed deps (TL1); (r)(s) pin that a below-cap acceptance dies on a plan edit.

// TL3 gap (what this test does NOT catch), category: skill-orchestration
// - whether a live model launches the supervisor-audit agent on audit-wait and reruns --gate after it
// - whether the plan skills stop and show the acceptance guidance on audit-block

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const restore = isolate();
const D = require("./feature-2853-pre-confirm-audit/driver");
const { X, S, ROOT, ACCEPT_SENTINEL, check, gate } = D;

const PCA = X.tryRequire("hooks/lib/pre-confirm-audit");
const judge = (sid, step) => {
  if (PCA.__missing || typeof PCA.judgeStage !== "function") return { state: "MISSING:" + (PCA.__missing || "no judgeStage") };
  try { return PCA.judgeStage(sid, step, { cwd: X.TDIR }) || {}; } catch (e) { return { state: "THROW:" + e.message }; }
};
const has = (s, frag) => String(s).includes(frag);
// checked(fn) -> a node:test body that fails when any check() inside fn (sync or async) fails.
const checked = (fn) => async () => {
  const before = D.failureCount();
  await fn();
  assert.strictEqual(D.failureCount() - before, 0, "check(s) failed; see the FAIL lines above");
};
after(() => {
  restore();
  const n = D.failureCount();
  console.log(n === 0 ? "ALL PASS" : `${n} FAIL`);
});

caseBegin("step3 TR1-3 leave the edge table, TR4 stays", "hooks/supervisor-guard/collect-audit-triggers.js");
test("step3 TR1-3 leave the edge table, TR4 stays", checked(() => {
    const CAT = require(path.join(ROOT, "hooks/supervisor-guard/collect-audit-triggers"));
    const proj = { steps: {
      clarify_intent: { status: "complete", updated_seq: 1 }, outline: { status: "complete", updated_seq: 2 },
      detail: { status: "complete", updated_seq: 3 }, write_code: { status: "complete", updated_seq: 4 } } };
    let ids = [];
    try { ids = (CAT.candidatesFromProjection(proj, {}) || []).map((c) => c.tr_id); } catch (e) { ids = ["THROW:" + e.message]; }
    check("S3 no candidate from clarify_intent / outline / detail completion", !ids.some((t) => ["TR1", "TR2", "TR3"].includes(t)), D.show(ids));
    check("S3 TR4 is still a candidate", ids.includes("TR4"), D.show(ids));
    check("S3 candidateFromTranscript is removed", CAT.candidateFromTranscript === undefined, typeof CAT.candidateFromTranscript);
}));
caseEnd();
caseBegin("step3 trigger table keeps TR1-3 ids and sub-checks, adds preConfirmCause", "hooks/lib/audit-triggers.js");
test("step3 trigger table keeps TR1-3 ids and sub-checks, adds preConfirmCause", checked(() => {
    const T = require(path.join(ROOT, "hooks/lib/audit-triggers"));
    check("S3 subChecksForTriggers([TR3]) unchanged", D.show(T.subChecksForTriggers(["TR3"])) === D.show(["outline-detail", "declared-files-snapshot"]),
      D.show(T.subChecksForTriggers(["TR3"])));
    const tr = (id) => T.triggerById(id) || {};
    check("S3 TR1-3 keep their sub-checks", D.show(tr("TR1").sub_checks) === D.show(["intent-internal"]) &&
      D.show(tr("TR2").sub_checks) === D.show(["intent-outline"]), D.show([tr("TR1"), tr("TR2")]));
    check("S3 TR1-3 are no longer edge triggers", ["TR1", "TR2", "TR3"].every((id) => tr(id).kind !== "edge"), D.show(T.TRIGGERS));
    check("S3 preConfirmCause(outline) === pre-confirm:outline",
      typeof T.preConfirmCause === "function" && T.preConfirmCause("outline") === "pre-confirm:outline", typeof T.preConfirmCause);
}));
caseEnd();
caseBegin("step4 pre-confirm-audit exports the judgment and arm API", "hooks/lib/pre-confirm-audit.js");
test("step4 pre-confirm-audit exports the judgment and arm API", checked(() => {
  check("S4 module loads", !PCA.__missing, PCA.__missing);
  for (const fn of ["judgeStage", "acceptedOnError", "armStage", "formatLaunch"]) {
    check(`S4 exports ${fn}`, typeof PCA[fn] === "function", typeof PCA[fn]);
  }
}));
caseEnd();

caseBegin("step4 (a)-(e) outline: wait, settle, warn, block, re-arm on edit", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (a)-(e) outline: wait, settle, warn, block, re-arm on edit", checked(() => {
    const s = X.sessionAt("outline");
    const a = gate(s.sid);
    const runA = (D.audit(s.sid).audit_run_id) || "";
    const entA = D.runEntry(s.sid, runA) || {};
    check("(a) unaudited outline: audit-wait", a.action === "audit-wait", a.out || a.err);
    check("(a) ledger run with cause pre-confirm:outline and TR2", entA.cause === "pre-confirm:outline" && (entA.tr_ids || []).includes("TR2"), D.show(entA));
    check("(a) launch shown (audit_dispatched_at set)", Boolean(D.audit(s.sid).audit_dispatched_at), D.show(D.audit(s.sid)));
    check("(a) GATE_AUDIT_RUN_ID names the armed run", runA !== "" && a.lines.GATE_AUDIT_RUN_ID === runA, a.out);
    check("(a) REASON pre-confirm-audit:unsettled", has(a.reason, "pre-confirm-audit:unsettled"), a.reason);
    check("(a) judgeStage after arm is unsettled", judge(s.sid, "outline").state === "unsettled", D.show(judge(s.sid, "outline")));

    let fin = true;
    try { S.finalize(s.sid, runA, "CONTINUE"); } catch (e) { fin = e.message; }
    check("(b) fixture finalize CONTINUE accepted", fin === true, fin);
    check("(b) judgeStage settled-continue", judge(s.sid, "outline").state === "settled-continue", D.show(judge(s.sid, "outline")));
    const b = gate(s.sid);
    check("(b) CONTINUE: ask", b.action === "ask", b.out || b.err);
    check("(b) GATE_AUDIT_VERDICT=CONTINUE", b.lines.GATE_AUDIT_VERDICT === "CONTINUE", b.out);
    check("(b) REASON pre-confirm-audit:settled-continue", has(b.reason, "pre-confirm-audit:settled-continue"), b.reason);

    const runW = S.settle(s.sid, "outline", "WARN");
    check("(c) judgeStage settled-warn", judge(s.sid, "outline").state === "settled-warn", D.show(judge(s.sid, "outline")));
    const c = gate(s.sid);
    check("(c) WARN: ask", c.action === "ask", c.out || c.err);
    // #2853 (q): the summary moved out of the hint onto its own GATE_AUDIT_SUMMARY line.
    check("(c) hint carries the WARN run id", has(c.hint, runW), c.hint);
    check("(c) GATE_AUDIT_SUMMARY carries the WARN summary", c.lines.GATE_AUDIT_SUMMARY === `fixture WARN summary for ${runW}`, c.out);

    const runB = S.settle(s.sid, "outline", "BLOCK");
    check("(d) judgeStage settled-block", judge(s.sid, "outline").state === "settled-block", D.show(judge(s.sid, "outline")));
    const d = gate(s.sid);
    check("(d) BLOCK: audit-block", d.action === "audit-block", d.out || d.err);
    check("(d) GATE_AUDIT_VERDICT=BLOCK on the BLOCK run", d.lines.GATE_AUDIT_VERDICT === "BLOCK" && d.lines.GATE_AUDIT_RUN_ID === runB, d.out);

    D.editPlan(s.sid, "outline", 1);
    check("(e) edited plan: judgeStage unsettled", judge(s.sid, "outline").state === "unsettled", D.show(judge(s.sid, "outline")));
    const e = gate(s.sid);
    const runE = D.audit(s.sid).audit_run_id;
    check("(e) edited plan: audit-wait again", e.action === "audit-wait", e.out || e.err);
    check("(e) a new run was armed", runE && runE !== runB && e.lines.GATE_AUDIT_RUN_ID === runE, D.show([runB, runE]));
    check("(e) audit_run_counts.TR2 === 2", D.countOf(s.sid, "TR2") === 2, D.show(D.audit(s.sid).audit_run_counts));
}));
caseEnd();

caseBegin("step4 (f) cap: the fourth unsettled gate arms nothing and blocks", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (f) cap: the fourth unsettled gate arms nothing and blocks", checked(() => {
    const s = X.sessionAt("outline");
    for (let i = 1; i <= 3; i += 1) {
      const g = gate(s.sid);
      check(`(f) round ${i}: audit-wait`, g.action === "audit-wait", g.out || g.err);
      const id = D.audit(s.sid).audit_run_id;
      try { S.finalize(s.sid, id, "BLOCK"); } catch (e) { check(`(f) round ${i}: finalize`, false, e.message); }
      D.editPlan(s.sid, "outline", 10 + i);
    }
    const before = D.ledgerOf(s.sid).length;
    check("(f) judgeStage cap-reached", judge(s.sid, "outline").state === "cap-reached", D.show(judge(s.sid, "outline")));
    const f = gate(s.sid);
    check("(f) cap: audit-block", f.action === "audit-block", f.out || f.err);
    check("(f) cap: no new run armed", before > 0 && D.ledgerOf(s.sid).length === before, `${before} -> ${D.ledgerOf(s.sid).length}`);
    check("(f) cap: count stays 3", D.countOf(s.sid, "TR2") === 3, D.show(D.audit(s.sid).audit_run_counts));
    check("(f) cap: hint carries the acceptance guidance", has(f.hint, ACCEPT_SENTINEL), f.hint);
    check("(f) cap: REASON pre-confirm-audit:cap-reached", has(f.reason, "pre-confirm-audit:cap-reached"), f.reason);
    const last = D.audit(s.sid).last_terminal_run_id;
    const acc = D.accept(s.sid, last) || {};
    check("(f) accepting the last run is recorded", acc.ok === true, D.show(acc));
    check("(f) judgeStage accepted", judge(s.sid, "outline").state === "accepted", D.show(judge(s.sid, "outline")));
    const g = gate(s.sid);
    check("(f) after acceptance past the cap: ask", g.action === "ask", g.out || g.err);
}));
caseEnd();

caseBegin("step4 (g) every plan stage x CONFIRM ON/OFF waits for the audit, then answers", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (g) every plan stage x CONFIRM ON/OFF waits for the audit, then answers", checked(() => require("./feature-2853-pre-confirm-audit/stage-matrix").run(check)));
caseEnd();

caseBegin("step4 (h)(i) approved stage and write_code arm nothing", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (h)(i) approved stage and write_code arm nothing", checked(() => {
    const s = X.sessionAt("outline", { approved: true });
    const h = gate(s.sid);
    check("(h) approved outline: proceed", h.action === "proceed", h.out || h.err);
    check("(h) approved outline: no run armed", D.ledgerOf(s.sid).length === 0, D.show(D.ledgerOf(s.sid)));

    const sid = X.uuidSid(9);
    for (const st of ["intent", "outline", "detail"]) X.F.writePlan(sid, st);
    const steps = {};
    for (const st of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "review_tests"]) steps[st] = "complete";
    steps.write_code = "pending";
    X.F.writeState(sid, steps, [{ step: "clarify_intent" }, { step: "outline" }, { step: "detail" }]);
    const i = gate(sid, { CONFIRM_CODE: "on" });
    check("(i) write_code ON: ask, as before", i.action === "ask" && i.lines.GATE_CONFIRM_CODE === "ON", i.out || i.err);
    check("(i) write_code: no run armed", D.ledgerOf(sid).length === 0, D.show(D.ledgerOf(sid)));
    check("(i) write_code: no audit lines", i.lines.GATE_AUDIT_RUN_ID === undefined && !has(i.reason, "pre-confirm-audit"), i.out);
}));
caseEnd();

caseBegin("step4 (j) a Stop-hook Phase A after the gate arm mints no second run", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (j) a Stop-hook Phase A after the gate arm mints no second run", checked(() => {
    const s = X.sessionAt("outline");
    const g = gate(s.sid);
    check("(j) gate armed", g.action === "audit-wait", g.out || g.err);
    try { S.finalize(s.sid, D.audit(s.sid).audit_run_id, "CONTINUE"); } catch (e) { check("(j) finalize", false, e.message); }
    const before = D.ledgerOf(s.sid).length;
    const { evaluatePhaseA } = require(path.join(ROOT, "hooks/supervisor-guard/audit-arm"));
    const st = require(path.join(ROOT, "hooks/lib/supervisor-state-writer")).readState(s.sid);
    const prev = process.env.WORKFLOW_SESSION_ID;
    process.env.WORKFLOW_SESSION_ID = s.sid;
    let res = null;
    try {
      res = evaluatePhaseA(s.sid, st, { auditPhase: (st && st.audit && st.audit.audit_phase) || null, cwd: X.TDIR, meta: {},
        workflowProjection: { steps: { clarify_intent: { status: "complete", updated_seq: 2 }, outline: { status: "pending" } } } });
    } catch (e) { res = { threw: e.message }; } finally {
      if (prev === undefined) delete process.env.WORKFLOW_SESSION_ID; else process.env.WORKFLOW_SESSION_ID = prev;
    }
    check("(j) Phase A arms no run", D.ledgerOf(s.sid).length === before, `${before} -> ${D.ledgerOf(s.sid).length} ${D.show(res && res.armInfo)}`);
}));
caseEnd();

const DC = require("./feature-2853-pre-confirm-audit/decide-cases");
caseBegin("step4 (k) judgeStage throws without acceptance: audit-block error", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (k) judgeStage throws without acceptance: audit-block error", checked(() => DC.k(check)));
caseEnd();
caseBegin("step4 (l) judgeStage throws with an accepted last run: original action", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (l) judgeStage throws with an accepted last run: original action", checked(() => DC.l(check)));
caseEnd();
caseBegin("step4 (m) armStage throws: audit-block", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (m) armStage throws: audit-block", checked(() => DC.m(check)));
caseEnd();
caseBegin("step4 (n) every judgeStage state maps to its gate action", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (n) every judgeStage state maps to its gate action", checked(() => DC.n(check)));
caseEnd();
caseBegin("step4 (v) cap-reached terminal WARN or CONTINUE asks at the CONFIRM", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (v) cap-reached terminal WARN or CONTINUE asks at the CONFIRM", checked(() => DC.v(check)));
caseEnd();

caseBegin("step4 (o) WORKFLOW_OFF skips only the audit judgment: original action, nothing armed or counted", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (o) WORKFLOW_OFF skips only the audit judgment: original action, nothing armed or counted", checked(() => {
    const s = X.sessionAt("outline");
    const { getSessionStateDir } = require(path.join(ROOT, "hooks/workflow-state"));
    require("node:fs").writeFileSync(path.join(getSessionStateDir(s.sid), `${s.sid}.workflow-off`), "fixture\n");
    const o = gate(s.sid);
    check("(o) WORKFLOW_OFF: REASON pre-confirm-audit:skipped-workflow-off", has(o.reason, "pre-confirm-audit:skipped-workflow-off"), o.reason || o.out);
    check("(o) WORKFLOW_OFF: the original action (ask), not audit-wait", o.action === "ask", o.out || o.err);
    check("(o) WORKFLOW_OFF: no run armed", D.ledgerOf(s.sid).length === 0, D.show(D.ledgerOf(s.sid)));
    check("(o) WORKFLOW_OFF: audit_run_counts.TR2 not incremented", !D.countOf(s.sid, "TR2"), D.show(D.audit(s.sid).audit_run_counts));
    check("(o) WORKFLOW_OFF: no GATE_AUDIT_RUN_ID", o.lines.GATE_AUDIT_RUN_ID === undefined || o.lines.GATE_AUDIT_RUN_ID === "", o.out);
}));
caseEnd();

// TR3 has two sub-checks (outline-detail, declared-files-snapshot). ledgerRuns writes terminal runs that each
// judged one sub-check at its current key, so the stage verdict is built from separate runs.
caseBegin("step4 (p) judgeStage takes the heaviest of each sub-check's newest terminal verdict", "hooks/lib/pre-confirm-audit.js");
test("step4 (p) judgeStage takes the heaviest of each sub-check's newest terminal verdict", checked(() => {
    const fs = require("node:fs");
    const SH = require(path.join(ROOT, "hooks/lib/supervisor-state-writer/shared"));
    const s = X.sessionAt("detail");
    S.settle(s.sid, "detail", "CONTINUE");
    const base = D.ledgerOf(s.sid).slice(-1)[0] || {};
    const ledgerRuns = (rows) => {
      const st = JSON.parse(fs.readFileSync(SH.getStatePath(s.sid), "utf8"));
      st.audit.ledger = rows.map(([n, sc, verdict]) => Object.assign({}, base, { id: `run-01${n}`, outcome: "terminal", verdict,
        sub_checks: [sc], input_key: { [sc]: (base.input_key || {})[sc] } }));
      fs.writeFileSync(SH.getStatePath(s.sid), JSON.stringify(st));
      return judge(s.sid, "detail");
    };
    const OD = "outline-detail";
    const DF = "declared-files-snapshot";
    check("(p) fixture: the settled run carries both sub-check keys", Boolean(base.input_key && base.input_key[OD] && base.input_key[DF]), D.show(base));
    let j = ledgerRuns([["01", OD, "CONTINUE"], ["02", DF, "WARN"]]);
    check("(p) CONTINUE + WARN -> settled-warn on the WARN run", j.state === "settled-warn" && j.runId === "run-0102", D.show(j));
    j = ledgerRuns([["01", OD, "WARN"], ["02", DF, "BLOCK"]]);
    check("(p) WARN + BLOCK -> settled-block on the BLOCK run", j.state === "settled-block" && j.runId === "run-0102", D.show(j));
    j = ledgerRuns([["01", OD, "BLOCK"], ["02", DF, "WARN"]]);
    check("(p) an older BLOCK on another sub-check still outweighs a newer WARN", j.state === "settled-block" && j.runId === "run-0101", D.show(j));
    j = ledgerRuns([["01", OD, "CONTINUE"], ["02", DF, "CONTINUE"]]);
    check("(p) CONTINUE + CONTINUE -> settled-continue", j.state === "settled-continue", D.show(j));
    j = ledgerRuns([["01", OD, "BLOCK"], ["02", DF, "CONTINUE"], ["03", OD, "CONTINUE"]]);
    check("(p) a sub-check's newer run replaces its older BLOCK -> settled-continue", j.state === "settled-continue", D.show(j));
    j = ledgerRuns([["01", OD, "CONTINUE"], ["02", DF, "CONTINUE"], ["03", OD, "BLOCK"]]);
    check("(p) a sub-check's newer BLOCK replaces its older CONTINUE -> settled-block", j.state === "settled-block" && j.runId === "run-0103", D.show(j));
}));
caseEnd();

caseBegin("step4 (q) the audit summary is a display-only GATE_AUDIT_SUMMARY line, never hint text", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (q) the audit summary is a display-only GATE_AUDIT_SUMMARY line, never hint text", checked(() => require("./feature-2853-pre-confirm-audit/summary-cases").run(check)));
caseEnd();

const AE = require("./feature-2853-pre-confirm-audit/accept-edit-cases");
caseBegin("step4 (r) a below-cap BLOCK acceptance does not carry over a plan edit: judgeStage unsettled", "hooks/lib/pre-confirm-audit.js");
test("step4 (r) a below-cap BLOCK acceptance does not carry over a plan edit: judgeStage unsettled", checked(() => AE.r(check)));
caseEnd();
caseBegin("step4 (s) a below-cap BLOCK acceptance does not carry over a plan edit: the gate re-arms", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (s) a below-cap BLOCK acceptance does not carry over a plan edit: the gate re-arms", checked(() => AE.s(check)));
caseEnd();

const IF = require("./feature-2853-pre-confirm-audit/inflight-cases");
caseBegin("step4 (t) an armed, unsettled run on the current plan: judgeStage unsettled + inFlight", "hooks/lib/pre-confirm-audit.js");
test("step4 (t) an armed, unsettled run on the current plan: judgeStage unsettled + inFlight", checked(() => IF.t(check)));
caseEnd();
caseBegin("step4 (u) rerunning the gate on an in-flight run reuses it: same run id, nothing armed or counted", "bin/workflow/lib/next-step/gate-mode.js");
test("step4 (u) rerunning the gate on an in-flight run reuses it: same run id, nothing armed or counted", checked(() => IF.u(check)));
caseEnd();
