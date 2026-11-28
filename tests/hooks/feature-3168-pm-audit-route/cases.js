"use strict";
// Case bodies for #3168 (entry: tests/hooks/feature-3168-pm-audit-route.js). The entry wraps them in caseBegin / caseEnd
// and calls the register* functions here. The gate runs in a child process (loads owner-stub-preload via NODE_OPTIONS); the write
// judgments and askHint run in-process (the entry has already called the preload's install()). Fixtures: pm-route-cases (2853) and 3144's fixture.
const path = require("path");

// sentinel-patterns is the SSOT for the name. The test holds the new name's literal as an expected value in exactly one place.
const NAME = "WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN";
// norm(s) -> keeps only alphanumerics, lowercased, so sentences still compare equal when gate-line escaping changes symbols.
const norm = (s) => String(s == null ? "" : s).replace(/[^A-Za-z0-9]/g, "").toLowerCase();
const FORGE_CLASSES = ["timeout", "budget-exhausted", "spawn-failed"];
// Wording that hands the conventional-audit echo to the user (the pre-#3168 misdirection, any phrasing).
const USER_RUNS_ECHO = /(ask|tell|have) the user to (run|execute|type|paste)|the user (runs|should run|must run|types|pastes)|user to run (the )?`?echo/i;

function ctxOf(t) {
  const { PR, D } = t;
  const F = PR.fx();
  const FF = () => require(path.join(D.ROOT, "bin", "lib", "forge-failure.js"));
  const AR = () => require(path.join(D.ROOT, "bin", "workflow", "lib", "next-step", "pm-audit-route.js"));
  const W = () => require(path.join(D.ROOT, "hooks", "lib", "pm-review-writer.js"));
  return Object.assign({ F, FF, AR, W }, t);
}

// T1 / T2: the gate's owner lookup carries every issue in one ownersOf call, capped by the gate's GATE_OWNER_TIMEOUT_MS (4000).
const GATE_MS = 4000;
function registerGate(t) {
  const { test, assert, PR, D, F, AR } = ctxOf(t);
  test("T1 3 issues with the same PM: --audit-route pm arms, ownersOf called once (3 ns, timeoutMs is the gate cap)", () => {
    const A = F.pm("pm-a");
    F.setOwners({ 3931: A, 3932: A, 3933: A });
    const sid = PR.session([3931, 3932, 3933]);
    F.clearLog();
    const g = PR.gateAt(sid, ["--audit-route", "pm"]);
    assert.ok(PR.runOf(g) !== "" && PR.destNames(sid, PR.runOf(g), A), `pm run with destination A: ${g.out || g.err}`);
    const calls = F.batchCalls();
    assert.strictEqual(calls.length, 1, `one ownersOf call: ${D.show(F.ownerCalls())}`);
    assert.deepStrictEqual([...calls[0].ns].sort(), ["3931", "3932", "3933"], D.show(calls));
    assert.strictEqual(Number(calls[0].timeoutMs), GATE_MS, `gate timeoutMs: ${D.show(calls)}`);
    assert.strictEqual(AR().GATE_OWNER_TIMEOUT_MS, GATE_MS, "pm-audit-route exports GATE_OWNER_TIMEOUT_MS = 4000");
  });
  test("T2 4 issues with 2 PMs: the PM named by --audit-route pm:<tag> becomes the destination, ownersOf called once", () => {
    const A = F.pm("pm-a");
    const B = F.pm("pm-b");
    F.setOwners({ 3934: A, 3935: A, 3936: B, 3937: B });
    const sid = PR.session([3934, 3935, 3936, 3937]);
    F.clearLog();
    const g = PR.gateAt(sid, ["--audit-route", `pm:${B.tag}`]);
    const run = PR.runOf(g);
    assert.ok(run !== "" && PR.destNames(sid, run, B) && !PR.destNames(sid, run, A), `destination B: ${g.out || g.err}`);
    const calls = F.batchCalls();
    assert.strictEqual(calls.length, 1, `one ownersOf call: ${D.show(F.ownerCalls())}`);
    assert.deepStrictEqual([...calls[0].ns].sort(), ["3934", "3935", "3936", "3937"], D.show(calls));
  });
}

// T3 / T4: a partial failure keeps the decided candidates as ask choices; a whole failure puts the class and next action in the hint.
function registerAsk(t) {
  const { test, assert, PR, D, F, FF, W } = ctxOf(t);
  const noRun = (sid, g) => PR.runOf(g) === "" && PR.ledgerLen(sid) === 0 && PR.tr2(sid) === 0;
  test("T3 partial failure (X / timeout / unset-held): ask offers X as a choice, not the holder; pmCandidatesOf gives cands [X]", () => {
    const Xp = F.pm("pm-x");
    const H = F.pm("pm-held");
    F.setOwners({ 3941: Xp, 3942: "timeout", 3943: null }, { 3943: [H] });
    const sid = PR.session([3941, 3942, 3943]);
    const g = PR.gateAt(sid);
    assert.ok(g.reason.includes("pm-route:ask") && noRun(sid, g), `ask with nothing armed: ${g.out || g.err}`);
    assert.ok(norm(g.hint).includes(norm(`--audit-route pm:${Xp.tag}`)), `the hint offers pm:${Xp.tag}: ${g.hint}`);
    assert.ok(!g.hint.includes(H.tag) && !g.hint.includes(H.session_id), `the local holder is offered: ${g.hint}`);
    assert.ok(norm(g.hint).includes(norm(NAME)), `the conventional audit is offered: ${g.hint}`);
    const target = F.target([3941, 3942, 3943]);
    const pc = W().pmCandidatesOf(target);
    assert.strictEqual(pc.decided, false, D.show(pc));
    assert.deepStrictEqual((pc.cands || []).map((c) => c.session_id), [Xp.session_id], D.show(pc));
    assert.ok(Array.isArray(pc.undecided) && pc.undecided.length === 2, `undecided carries the two refs: ${D.show(pc)}`);
    // A partial failure's reason has the form owner-undecidable: <ref>=<reason>,... carrying the reason per undecided ref.
    const why = String(pc.reason);
    assert.match(why, /^owner-undecidable: /, why);
    assert.ok(why.includes("3942=timeout") && why.includes("3943=pm-field-unset-held"), `the per-ref summary: ${why}`);
  });
  for (const code of FORGE_CLASSES) {
    test(`T4 whole failure ${code}: ask arms nothing; hint has the class name, next action, gate rerun, new name and step name`, () => {
      const A = F.pm("pm-a");
      F.setOwners({ 3944: A, 3945: A });
      F.setBatchFailure(code);
      const sid = PR.session([3944, 3945]);
      const g = PR.gateAt(sid);
      assert.ok(g.reason.includes("pm-route:ask") && noRun(sid, g), `ask with nothing armed: ${g.out || g.err}`);
      const h = norm(g.hint);
      assert.ok(h.includes(norm(code)), `the hint names ${code}: ${g.hint}`);
      assert.ok(h.includes(norm(FF().nextActionOf(code))), `the hint carries nextActionOf(${code}): ${g.hint}`);
      assert.ok(h.includes("nextstepgate"), `the hint offers rerunning next-step --gate: ${g.hint}`);
      assert.ok(h.includes(norm(`<<${NAME}: outline`)), `the hint carries the new sentinel with the step name: ${g.hint}`);
      assert.ok(!h.includes(norm("--audit-route pm:")), `no PM choice on a whole failure: ${g.hint}`);
    });
  }
  // A whole failure outside forge-failure's 3 classes (gh_exec_failed / parse_failed / owner-error) shows only the reason code.
  for (const code of ["gh_exec_failed", "parse_failed", "owner-error"]) {
    test(`T4d whole failure ${code}: the hint carries only the reason code, no next-action sentence`, () => {
      const A = F.pm("pm-a");
      F.setOwners({ 3946: A });
      F.setBatchFailure(code);
      const sid = PR.session([3946]);
      const g = PR.gateAt(sid);
      assert.ok(g.reason.includes("pm-route:ask") && noRun(sid, g), `ask with nothing armed: ${g.out || g.err}`);
      const h = norm(g.hint);
      assert.ok(h.includes(norm(code)), `the hint names ${code}: ${g.hint}`);
      assert.ok(h.includes(norm(`<<${NAME}: outline`)), `the hint carries the new sentinel: ${g.hint}`);
      for (const c of FORGE_CLASSES.concat(["gh_exec_failed", "parse_failed"])) {
        assert.ok(!h.includes(norm(FF().nextActionOf(c))), `the hint carries the ${c} action: ${g.hint}`);
      }
    });
  }
}

// T5-T7: the write judgment accepts only runs that recorded a PM route; candidacy is decided by membership in cands, not by decided.
function registerWrite(t) {
  const { test, assert, PR, D, F, W } = ctxOf(t);
  const audit = (caller, sid, runId) => W().judgePmWrite({ callerSid: caller, targetSid: sid, kind: "audit", runId });
  test("T5 a PM writing a verdict to a fallback run armed by the sentinel is refused with fallback-run", () => {
    const A = F.pm("pm-a");
    F.setOwners({ 3951: A });
    const sid = PR.session([3951]);
    const r1 = PR.runOf(PR.gateAt(sid));
    const out = PR.mark(sid, `echo "<<${NAME}: outline r>>"`);
    const runNow = D.audit(sid).audit_run_id || "";
    assert.ok(runNow !== "" && runNow !== r1, `the sentinel armed a new run: ${D.show([r1, runNow, out])}`);
    const r = audit(A.session_id, sid, runNow);
    assert.ok(r && !r.ok && /^fallback-run/.test(String(r.reason)), D.show(r));
  });
  test("T6 a PM writing to a run whose ask is unresolved (no destination finding) is refused with no-destination", () => {
    const A = F.pm("pm-a");
    F.setOwners({ 3952: A });
    const sid = F.target([3952]);
    const runId = F.arm(sid);
    const r = audit(A.session_id, sid, runId);
    assert.ok(r && !r.ok && /^no-destination/.test(String(r.reason)), D.show(r));
  });
  test("T7 run with partial candidates (X / timeout): destination X can write, Y is refused with a per-path reason code", () => {
    const Xp = F.pm("pm-x");
    const Y = F.pm("pm-y");
    F.setOwners({ 3953: Xp, 3954: "timeout" });
    const sid = F.target([3953, 3954]);
    const runId = F.arm(sid);
    F.dest(sid, runId, Xp.session_id);
    const okX = audit(Xp.session_id, sid, runId);
    assert.ok(okX && okX.ok, `the destination X writes: ${D.show(okX)}`);
    const noY = audit(Y.session_id, sid, runId);
    assert.ok(noY && !noY.ok && /^not-destination/.test(String(noY.reason)), D.show(noY));
    const req = (pmSid) => W().judgeRequestWrite({ callerSid: sid, targetSid: sid, pmSid });
    const reqX = req(Xp.session_id);
    assert.ok(reqX && reqX.ok, `a request to the decided X: ${D.show(reqX)}`);
    const reqY = req(Y.session_id);
    assert.ok(reqY && !reqY.ok && /^pm-not-candidate/.test(String(reqY.reason)), D.show(reqY));
    F.addRows(sid, [F.reqRow(1, Y.session_id, 12, t.FP.a)]);
    const rv = W().judgePmWrite({ callerSid: Y.session_id, targetSid: sid, kind: "pm-review", target: { round: 1, fingerprint: t.FP.a, pr: 12 } });
    assert.ok(rv && !rv.ok && /^caller-not-candidate/.test(String(rv.reason)), D.show(rv));
    // The refusal text ends with the undecided summary (ref=reason).
    for (const r of [reqY, rv]) assert.ok(String(r.reason).includes("3954=timeout"), `the undecided summary: ${D.show(r)}`);
  });
  test("T7b target with partial candidates (X / timeout): the requested X can write pm-review (candidateRefusal path)", () => {
    const Xp = F.pm("pm-x");
    F.setOwners({ 3955: Xp, 3956: "timeout" });
    const sid = F.target([3955, 3956]);
    F.addRows(sid, [F.reqRow(1, Xp.session_id, 12, t.FP.a)]);
    const rv = W().judgePmWrite({ callerSid: Xp.session_id, targetSid: sid, kind: "pm-review", target: { round: 1, fingerprint: t.FP.a, pr: 12 } });
    assert.ok(rv && rv.ok, `the decided candidate X writes its review: ${D.show(rv)}`);
  });
}

// T3b-T3e: after a partial-failure ask, rerunning the gate with the user's chosen route arms the decided candidate X, and
// a rerun without arguments reuses that run (pickRequested / decideArm handle partial candidates as-is). A whole failure arms nothing.
function registerPick(t) {
  const { test, assert, PR, D, F, W } = ctxOf(t);
  const audit = (caller, sid, runId) => W().judgePmWrite({ callerSid: caller, targetSid: sid, kind: "audit", runId });
  // partial(base) -> {Xp, H, sid}: the same fixture as T3 (X / timeout / holder H of unset-held).
  function partial(base) {
    const Xp = F.pm("pm-x");
    const H = F.pm("pm-held");
    F.setOwners({ [base]: Xp, [base + 1]: "timeout", [base + 2]: null }, { [base + 2]: [H] });
    return { Xp, H, sid: PR.session([base, base + 1, base + 2]) };
  }
  for (const [label, route] of [["pm:<X>", (Xp) => `pm:${Xp.tag}`], ["pm", () => "pm"]]) {
    test(`T3${label === "pm" ? "c" : "b"} partial failure with --audit-route ${label}: arms X, X can write the audit, the holder is refused`, () => {
      const { Xp, H, sid } = partial(label === "pm" ? 3974 : 3971);
      const g = PR.gateAt(sid, ["--audit-route", route(Xp)]);
      const run = PR.runOf(g);
      assert.ok(run !== "" && PR.destNames(sid, run, Xp), `armed for X: ${g.out || g.err}`);
      assert.ok(g.reason.includes("pm-route:pm"), g.reason);
      const okX = audit(Xp.session_id, sid, run);
      assert.ok(okX && okX.ok, `X writes the audit: ${D.show(okX)}`);
      const noH = audit(H.session_id, sid, run);
      assert.ok(noH && !noH.ok, `the holder of the undecided ref writes: ${D.show(noH)}`);
    });
  }
  test("T3e partial failure, armed for pm:<X>, then gate rerun without arguments: reuses the in-flight run, does not return to ask", () => {
    const { Xp, sid } = partial(3979);
    const r1 = PR.runOf(PR.gateAt(sid, ["--audit-route", `pm:${Xp.tag}`]));
    assert.ok(r1 !== "" && PR.destNames(sid, r1, Xp), `armed for X: ${r1}`);
    const g = PR.gateAt(sid);
    assert.strictEqual(PR.runOf(g), r1, `the rerun reuses the in-flight run: ${g.out || g.err}`);
    assert.ok(g.reason.includes("pm-route:pm"), g.reason);
    assert.strictEqual(PR.ledgerLen(sid), 1, D.show(D.audit(sid)));
    assert.strictEqual(PR.tr2(sid), 1, D.show(D.audit(sid).audit_run_counts));
  });
  test("T3d whole failure (timeout) with --audit-route pm: arms nothing, the ask hint shows the class code", () => {
    const A = F.pm("pm-a");
    F.setOwners({ 3977: A, 3978: A });
    F.setBatchFailure("timeout");
    const sid = PR.session([3977, 3978]);
    const g = PR.gateAt(sid, ["--audit-route", "pm"]);
    assert.ok(PR.runOf(g) === "" && PR.ledgerLen(sid) === 0 && PR.tr2(sid) === 0, `nothing armed: ${g.out || g.err}`);
    assert.ok(g.reason.includes("pm-route:ask"), g.reason);
    assert.ok(norm(g.hint).includes(norm("(timeout)")), `the ask names the class timeout: ${g.hint}`);
    assert.ok(norm(g.hint).includes(norm(`<<${NAME}: outline`)), `the conventional audit is offered: ${g.hint}`);
  });
}

// T11: askHint shows the new name and step name at every step, in the form where the model echoes and the user permits in the dialog.
function registerHint(t) {
  const { test, assert, AR, FF } = ctxOf(t);
  const P1 = { tag: "pm-one", session_id: "11111111-2222-4333-8444-555555555555" };
  const P2 = { tag: "pm-two", session_id: "66666666-7777-4888-8999-aaaaaaaaaaaa" };
  const combos = [
    { name: "several-assigned-pms", reason: "several-assigned-pms", pms: [P1, P2], failure: null, later: false },
    { name: "owner-undecidable with one pm", reason: "owner-undecidable", pms: [P1], failure: null, later: true },
    { name: "timeout failure", reason: "timeout", pms: [], failure: "timeout", later: true },
    { name: "gh_exec_failed", reason: "gh_exec_failed", pms: [], failure: "gh_exec_failed", later: true },
  ];
  test("T11 askHint(step, reason, pms, failure): new name and step name at every step, model runs the echo via Bash and the user only approves it, choices vary by case", () => {
    assert.match('ask the user to run echo "<<X: outline r>>" in the permission dialog', USER_RUNS_ECHO, "the guard regex catches the old wording");
    for (const step of ["clarify_intent", "outline", "detail"]) {
      for (const c of combos) {
        const h = String(AR().askHint(step, c.reason, c.pms, c.failure));
        const tag = `${step} / ${c.name}`;
        assert.ok(h.includes(`<<${NAME}: ${step} `), `${tag}: sentinel with the step: ${h}`);
        assert.doesNotMatch(h, USER_RUNS_ECHO, `${tag}: the echo is handed to the user: ${h}`);
        // Roles: the model runs the echo via Bash; the user only approves it in the permission dialog.
        const role = `you run echo "<<${NAME}: ${step} <reason>>>" via Bash and the user approves it in the permission dialog`;
        assert.ok(norm(h).includes(norm(role)), `${tag}: model runs the echo, user approves it: ${h}`);
        for (const p of c.pms) assert.ok(h.includes(`--audit-route pm:${p.tag}`), `${tag}: offers pm:${p.tag}: ${h}`);
        if (c.pms.length === 0) assert.ok(!h.includes("--audit-route pm:"), `${tag}: no PM choice: ${h}`);
        assert.strictEqual(/\blater\b/i.test(h), c.later, `${tag}: the rerun-later choice ${c.later ? "missing" : "offered"}: ${h}`);
        if (c.later) assert.ok(h.includes("next-step --gate"), `${tag}: rerun next-step --gate: ${h}`);
        const actions = FORGE_CLASSES.concat(["gh_exec_failed"]).map((x) => FF().nextActionOf(x));
        if (c.failure === "timeout") assert.ok(h.includes(FF().nextActionOf("timeout")), `${tag}: the timeout action: ${h}`);
        if (c.failure === "gh_exec_failed") {
          assert.ok(h.includes("gh_exec_failed"), `${tag}: the reason code: ${h}`);
          for (const a of actions) assert.ok(!h.includes(a), `${tag}: an action sentence on gh_exec_failed: ${h}`);
        }
      }
    }
  });
}

// T13: owner lookups on the hook path (write judgment and the USER_VERIFIED pm-review judgment) run with a cap of 2000 or less.
function registerHookLimit(t) {
  const { test, assert, D, F, W } = ctxOf(t);
  test("T13 judgePmWrite / judgeRequestWrite / checkUserVerifiedPmReview call ownersOf with timeoutMs <= 2000", () => {
    const A = F.pm("pm-a");
    F.setOwners({ 3961: A, 3962: A, 3963: A });
    const sid = F.target([3961, 3962, 3963]);
    const runId = F.arm(sid);
    F.dest(sid, runId, A.session_id);
    F.clearLog();
    W().judgePmWrite({ callerSid: A.session_id, targetSid: sid, kind: "audit", runId });
    W().judgeRequestWrite({ callerSid: sid, targetSid: sid, pmSid: A.session_id });
    const saved = process.env.PM3144_PR_STUB;
    process.env.PM3144_PR_STUB = JSON.stringify({ state: "OPEN", number: "12" });
    try {
      const fn = require(path.join(D.ROOT, "hooks", "workflow-gate", "user-verified-pm-review.js")).checkUserVerifiedPmReview;
      const STOP = {};
      try { fn(sid, D.X.TDIR, { blockFn: () => { throw STOP; }, approveFn: () => { throw STOP; } }); } catch (e) { if (e !== STOP) throw e; }
    } finally {
      if (saved === undefined) delete process.env.PM3144_PR_STUB; else process.env.PM3144_PR_STUB = saved;
    }
    const calls = F.batchCalls();
    assert.ok(calls.length >= 3, `every judgment asks through ownersOf: ${D.show(F.ownerCalls())}`);
    for (const c of calls) assert.ok(Number(c.timeoutMs) > 0 && Number(c.timeoutMs) <= 2000, `hook-path timeoutMs ${c.timeoutMs}: ${D.show(calls)}`);
  });
}

module.exports = { registerGate, registerAsk, registerPick, registerWrite, registerHint, registerHookLimit, NAME, norm };
