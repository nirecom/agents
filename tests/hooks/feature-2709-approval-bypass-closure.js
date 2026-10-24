"use strict";
// Tests: hooks/lib/sentinel-patterns.js, hooks/lib/supervisor-block-override.js, hooks/workflow-mark/supervisor-block-override-handler.js, hooks/workflow-mark.js, hooks/workflow-mark/reset-handler.js, hooks/workflow-state/completion-approval.js, hooks/workflow-gate/user-verified-audit.js, settings.json
// Tags: supervisor, block-override, reset-from, plan-approval, sentinel, permissions, scope:issue-specific, TL2
// #2709 — two routes that recorded an approval without the user: the un-gated override CLI (now the ask-gated
// WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel, #2597) and RESET_FROM's synthesised plan approvals (now refused).
// TL3 gap: the real permissions.ask dialog is not exercised; settings.json is checked
// statically and the sentinel is fed to the PostToolUse hook as if the user had allowed it.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2709-"));
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcripts");
fs.mkdirSync(CFG);
fs.mkdirSync(TRANSCRIPTS);
fs.writeFileSync(path.join(CFG, ".env"), "");
// The config FILE is the only CONFIRM_* source isOffWaived reads; process values are cleared
// so a stray export cannot mask a case.
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
for (const k of ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL", "WORKFLOW_SESSION_ID"]) delete process.env[k];
process.on("exit", () => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { make, mod, ROOT, FK, SENT } = require("./feature-2709-approval-bypass-closure/fixture");
const CA = mod("hooks/workflow-state/completion-approval.js");

let passed = 0;
let failed = 0;
function run(name, fn) {
  let why = null;
  try { const r = fn(); if (typeof r === "string") why = r; } catch (e) { why = e && e.message ? e.message : String(e); }
  if (why === null) { passed += 1; console.log(`PASS: ${name}`); } else { failed += 1; console.log(`FAIL: ${name} — ${why}`); }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what}: want=${show(want)} got=${show(got)}`);
}
function ok(cond, what) { if (!cond) throw new Error(what); }

// ── fixtures (sibling module): supervisor state, workflow state, real-hook driver ──
const {
  S, PAF, writer, nextSid, terminalRun, seedSup, supState, overrides, markHook,
  setConfig, statePath, rawState, events, seedWf, reset, resetHook, resetSentinelApprovals, assertRefused,
} = make({ TMP, CFG, eq, ok, show });
const REASON = "verified manually with the reviewer; the BLOCK is a false positive";
const sentinel = (body) => `echo "<<${SENT}: ${body}>>"`;

caseBegin("A1 valid override sentinel records a reviewed override", "hooks/workflow-mark.js");
run("A1 valid override sentinel records a reviewed override", () => {
  const sid = nextSid("a1");
  seedSup(sid, [terminalRun("run-0011", "BLOCK")]);
  const msg = markHook(sid, sentinel(`run-0011 ${REASON}`));
  const bo = overrides(sid);
  eq(bo.length, 1, "block_overrides length");
  eq([bo[0].run_id, bo[0].freshness_key, bo[0].actor, bo[0].reason], ["run-0011", FK, "tester-2709", REASON], "record fields");
  ok(/run-0011/.test(msg), `confirmation names the run id; got ${show(msg)}`);
});
caseEnd();

caseBegin("A2 recorded override releases the TR5 hold for its run and key", "hooks/workflow-gate/user-verified-audit.js");
run("A2 recorded override releases the TR5 hold for its run and key", () => {
  const { acceptanceReleasesNonNull: rel } = mod("hooks/lib/null-freshness.js"); // #2597: a legacy record keeps releasing
  const legacy = [{ run_id: "run-0011", freshness_key: FK, reason: REASON, actor: "t", recorded_at: "2026-01-01T00:00:00Z" }];
  const tr5Run = terminalRun("run-0011", "BLOCK");
  eq(rel({ tr5Run, overrides: legacy, currentFk: FK }), true, "releases at the pinned key");
  eq(rel({ tr5Run, overrides: legacy, currentFk: "fk-moved" }), false, "a moved key does not release");
});
caseEnd();

caseBegin("A3 override finding names the sentinel handler as reporter", "hooks/workflow-mark/supervisor-block-override-handler.js");
run("A3 override finding names the sentinel handler as reporter", () => {
  const sid = nextSid("a3");
  seedSup(sid, [terminalRun("run-0011", "BLOCK")]);
  markHook(sid, sentinel(`run-0011 ${REASON}`));
  const f = ((supState(sid) || {}).layer1 || {}).findings || [];
  const last = f[f.length - 1] || {};
  eq([last.severity, last.reporter], ["warning", "workflow-mark:supervisor-block-override"], "finding");
});
caseEnd();

caseBegin("A4 reason length boundary 19 refused and 20 accepted", "hooks/workflow-mark/supervisor-block-override-handler.js");
run("A4 reason length boundary 19 refused and 20 accepted", () => {
  const sid = nextSid("a4");
  seedSup(sid, [terminalRun("run-0011", "BLOCK")]);
  const short = "abcdefghij klmnopqr"; // 19 chars
  const msg = markHook(sid, sentinel(`run-0011 ${short}`));
  eq(overrides(sid).length, 0, "19-char reason records nothing");
  ok(/20/.test(msg), `refusal states the 20-character minimum; got ${show(msg)}`);
  markHook(sid, sentinel("run-0011 abcdefghij klmnopqrs")); // 20 chars
  eq(overrides(sid).length, 1, "20-char reason is recorded");
});
caseEnd();

caseBegin("A5 run that is not the last terminal run is refused", "hooks/workflow-mark/supervisor-block-override-handler.js");
run("A5 run that is not the last terminal run is refused", () => {
  const sid = nextSid("a5");
  seedSup(sid, [terminalRun("run-0011", "BLOCK"), terminalRun("run-0012", "BLOCK", "TR6")]);
  const msg = markHook(sid, sentinel(`run-0011 ${REASON}`));
  eq(overrides(sid).length, 0, "nothing recorded");
  ok(/run-0012/.test(msg), `refusal names the actual last run; got ${show(msg)}`);
});
caseEnd();

caseBegin("A6 CONTINUE is refused and WARN is accepted", "hooks/workflow-mark/supervisor-block-override-handler.js");
run("A6 CONTINUE is refused and WARN is accepted", () => {
  const sid = nextSid("a6");
  seedSup(sid, [terminalRun("run-0011", "CONTINUE")]);
  const msg = markHook(sid, sentinel(`run-0011 ${REASON}`));
  eq(overrides(sid).length, 0, "CONTINUE: nothing recorded");
  ok(/CONTINUE/.test(msg), `refusal names the CONTINUE verdict; got ${show(msg)}`);
  const warn = nextSid("a6w");
  seedSup(warn, [terminalRun("run-0011", "WARN")]); markHook(warn, sentinel(`run-0011 ${REASON}`));
  eq(overrides(warn).map((b) => [b.run_id, b.verdict]), [["run-0011", "WARN"]], "WARN: one acceptance recorded");
});
caseEnd();

// Command forms shared by the hook-level (A7) and regex-level (A11) tables.
const VALID = sentinel(`run-0011 ${REASON}`);
const FORMS = [
  { name: "valid", cmd: VALID, records: true, formatError: false, isSentinel: true, strict: true },
  { name: "malformed-bare-no-body", cmd: `echo "<<${SENT}>>"`, records: false, formatError: true, isSentinel: true, strict: false },
  // Design (detail plan 3a): LOOKSLIKE = /^echo "<<NAME([: ].*)?>>"$/ is registered in isSentinel() only,
  // so every echo of the override name that is not RE_DQ-strict is a sentinel that reaches the handler
  // and draws a format error. Only forms that are not a single clean echo are plain commands.
  { name: "malformed-run-id-only", cmd: sentinel("run-0011"), records: false, formatError: true, isSentinel: true, strict: false },
  { name: "malformed-run-id-without-prefix", cmd: sentinel(`0011 ${REASON}`), records: false, formatError: true, isSentinel: true, strict: false },
  { name: "concatenated-and-chain", cmd: `${VALID} && rm -rf x`, records: false, formatError: null, isSentinel: false, strict: false },
  { name: "concatenated-semicolon-chain", cmd: `${VALID}; echo done`, records: false, formatError: null, isSentinel: false, strict: false },
  { name: "concatenated-pipe", cmd: `${VALID} | cat`, records: false, formatError: null, isSentinel: false, strict: false },
  { name: "concatenated-leading-command", cmd: `cd /tmp && ${VALID}`, records: false, formatError: null, isSentinel: false, strict: false },
  { name: "quoted-single", cmd: `echo '<<${SENT}: run-0011 ${REASON}>>'`, records: false, formatError: null, isSentinel: false, strict: false },
  { name: "quoted-unterminated-double", cmd: `echo "<<${SENT}: run-0011 ${REASON}>>`, records: false, formatError: null, isSentinel: false, strict: false },
  { name: "wrong-sentinel-name", cmd: `echo "<<${SENT}S: run-0011 ${REASON}>>"`, records: false, formatError: null, isSentinel: false, strict: false },
];

caseBegin("A7 override form table records only the valid form (hook level)", "hooks/workflow-mark/supervisor-block-override-handler.js");
for (const c of FORMS) {
  run(`A7 ${c.name}: hook ${c.records ? "records" : "records nothing"}`, () => {
    const sid = nextSid("a7");
    seedSup(sid, [terminalRun("run-0011", "BLOCK")]);
    const msg = markHook(sid, c.cmd);
    eq(overrides(sid).length, c.records ? 1 : 0, `${c.name}: block_overrides length`);
    // A format error is only possible for a form the classifier hands to the handler.
    if (c.formatError === true) {
      ok(c.isSentinel === true, `${c.name}: table expects a format error from a form the classifier rejects`);
      ok(msg.includes(SENT), `${c.name}: format error names the sentinel; got ${show(msg)}`);
    }
  });
}
caseEnd();

caseBegin("A7b plain-command forms are not handed to the handler", "hooks/lib/sentinel-patterns.js");
for (const c of FORMS.filter((f) => f.isSentinel === false)) {
  run(`A7b ${c.name}: hook emits no override handler output`, () => {
    const sid = nextSid("a7b");
    seedSup(sid, [terminalRun("run-0011", "BLOCK")]);
    const p = writer.getStatePath(sid);
    const before = fs.readFileSync(p, "utf8");
    const msg = markHook(sid, c.cmd);
    ok(!msg.includes("supervisor-block-override"), `${c.name}: handler output for a plain command; got ${show(msg)}`);
    ok(fs.readFileSync(p, "utf8") === before, `${c.name}: supervisor state changed`);
  });
}
caseEnd();

caseBegin("A14 the same valid override sent twice appends two audit records", "hooks/workflow-mark/supervisor-block-override-handler.js");
run("A14 the same valid override sent twice appends two audit records", () => {
  // block_overrides is append-only (appendBlockOverride never dedupes; each send is its own ask-dialog act),
  // so a second valid send gives two records, two findings, and the hold stays released.
  const sid = nextSid("a14");
  seedSup(sid, [terminalRun("run-0011", "BLOCK")]);
  markHook(sid, sentinel(`run-0011 ${REASON}`));
  markHook(sid, sentinel(`run-0011 ${REASON}`));
  const bo = overrides(sid);
  eq(bo.map((b) => [b.run_id, b.freshness_key]), [["run-0011", FK], ["run-0011", FK]], "two override records");
  const f = ((supState(sid) || {}).layer1 || {}).findings || [];
  eq(f.filter((x) => x.reporter === "workflow-mark:supervisor-block-override").length, 2, "two override findings");
  const { acceptanceReleasesNonNull: rel } = mod("hooks/lib/null-freshness.js");
  eq(rel({ tr5Run: terminalRun("run-0011", "BLOCK"), overrides: bo, currentFk: FK }), true, "hold stays released");
});
caseEnd();

caseBegin("A9 lib records directly and a short reason touches no state", "hooks/lib/supervisor-block-override.js");
run("A9 lib records directly and a short reason touches no state", () => {
  const lib = mod("hooks/lib/supervisor-block-override.js");
  const sid = nextSid("a9");
  const AK = { intent: "h-i", outline: null, detail: "h-d" };
  seedSup(sid, [Object.assign(terminalRun("run-0011", "WARN"), { artifact_keys: AK, trigger_input_keys: { TR5: "iv-a9" } })]);
  const good = lib.recordReviewedVerdictAcceptance(sid, { runId: "run-0011", reason: REASON, actor: "lib-actor" });
  eq(good && good.ok, true, `accepted result ${show(good)}`);
  eq(overrides(sid).map((b) => [b.actor, b.run_id, b.verdict, b.freshness_key, b.artifact_keys, b.trigger_key]),
    [["lib-actor", "run-0011", "WARN", FK, AK, "iv-a9"]], "recorded acceptance pins the run id, verdict and snapshot");
  const cont = nextSid("a9c"); seedSup(cont, [terminalRun("run-0011", "CONTINUE")]);
  eq((lib.recordReviewedVerdictAcceptance(cont, { runId: "run-0011", reason: REASON }) || {}).code, "verdict-not-acceptable", "CONTINUE");
  const fresh = nextSid("a9b");
  const bad = lib.recordReviewedVerdictAcceptance(fresh, { runId: "run-0011", reason: "too short", actor: "x" });
  eq(bad && bad.ok, false, `short reason result ${show(bad)}`);
  ok(typeof bad.message === "string" && bad.message.length > 0, "refusal carries a message");
  ok(!fs.existsSync(writer.getStatePath(fresh)), "no supervisor state file materialised");
});
caseEnd();

caseBegin("A10 settings.json asks for the override and no allow rule matches it", "settings.json");
run("A10 settings.json asks for the override and no allow rule matches it", () => {
  const perms = JSON.parse(fs.readFileSync(path.join(ROOT, "settings.json"), "utf8")).permissions || {};
  const want = `Bash(echo "<<${SENT}: *>>")`;
  ok((perms.ask || []).includes(want), `permissions.ask lacks ${want}`);
  const sample = sentinel(`run-0011 ${REASON}`);
  const toRe = (body) => {
    const prefix = /:\*$/.test(body);
    const core = (prefix ? body.slice(0, -2) : body).split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*");
    return new RegExp("^" + core + (prefix ? "" : "$"));
  };
  for (const rule of perms.allow || []) {
    const m = /^Bash\((.*)\)$/.exec(rule);
    if (m && toRe(m[1]).test(sample)) throw new Error(`allow rule ${rule} auto-approves the override`);
  }
});
caseEnd();

caseBegin("A11 sentinel patterns recognise the override form", "hooks/lib/sentinel-patterns.js");
run("A11 sentinel patterns recognise the override form", () => {
  const sp = mod("hooks/lib/sentinel-patterns.js");
  ok(sp.SUPERVISOR_VERDICT_ACCEPTED_RE_DQ instanceof RegExp, "SUPERVISOR_VERDICT_ACCEPTED_RE_DQ exported");
  ok(sp.SUPERVISOR_VERDICT_ACCEPTED_LOOKSLIKE_RE instanceof RegExp, "SUPERVISOR_VERDICT_ACCEPTED_LOOKSLIKE_RE exported");
});
caseEnd();

caseBegin("A11 table: isSentinel and isStrictSentinel verdicts per command form", "hooks/lib/sentinel-patterns.js");
for (const c of FORMS) {
  run(`A11 ${c.name}: isSentinel / isStrictSentinel`, () => {
    const sp = mod("hooks/lib/sentinel-patterns.js");
    if (c.isSentinel !== null) eq(sp.isSentinel(c.cmd), c.isSentinel, `${c.name}: isSentinel(${show(c.cmd)})`);
    eq(sp.isStrictSentinel(c.cmd), c.strict, `${c.name}: isStrictSentinel(${show(c.cmd)})`);
  });
}
caseEnd();

caseBegin("A13 rejected overrides leave the supervisor state byte-identical", "hooks/workflow-mark/supervisor-block-override-handler.js");
for (const c of [
  { name: "short-reason", seed: [terminalRun("run-0011", "BLOCK")], cmd: sentinel("run-0011 too short") },
  { name: "not-last-run", seed: [terminalRun("run-0011", "BLOCK"), terminalRun("run-0012", "BLOCK", "TR6")], cmd: sentinel(`run-0011 ${REASON}`) },
  { name: "non-block-verdict", seed: [terminalRun("run-0011", "CONTINUE")], cmd: sentinel(`run-0011 ${REASON}`) },
  { name: "malformed", seed: [terminalRun("run-0011", "BLOCK")], cmd: sentinel("run-0011") },
]) {
  run(`A13 ${c.name}: supervisor state unchanged`, () => {
    const sid = nextSid("a13");
    seedSup(sid, c.seed);
    const p = writer.getStatePath(sid);
    const before = fs.readFileSync(p, "utf8");
    markHook(sid, c.cmd);
    ok(fs.readFileSync(p, "utf8") === before, `${c.name}: supervisor state file changed after a rejected override`);
  });
}
caseEnd();

caseBegin("A12 the un-gated CLI is gone and the hold reason points at the sentinel", "hooks/workflow-gate/user-verified-audit.js");
run("A12 the un-gated CLI is gone and the hold reason points at the sentinel", () => {
  ok(!fs.existsSync(path.join(ROOT, "bin", "supervisor-record-block-override")), "bin/supervisor-record-block-override still exists");
  const src = fs.readFileSync(path.join(ROOT, "hooks", "workflow-gate", "user-verified-audit.js"), "utf8");
  ok(String(mod("hooks/workflow-gate/user-verified-audit.js").holdReason("run-0011")).includes(SENT), "holdReason does not name the sentinel");
  ok(!src.includes("bin/supervisor-record-block-override"), "holdReason still names the removed CLI");
});
caseEnd();

// ── 3b: RESET_FROM (in-process handler B1-B13, real hooks/workflow-mark.js subprocess B14-B15) ──
caseBegin("B1 reset over an unapproved outline is refused with no write", "hooks/workflow-mark/reset-handler.js");
run("B1 reset over an unapproved outline is refused with no write", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b1", ["clarify_intent", "detail"]);
  const before = rawState(sid);
  const count = events(sid).length;
  const msg = reset(sid, "write_tests");
  assertRefused(sid, "write_tests", "outline", "no-approval-record", msg, before, count);
  ok(msg.includes("CONFIRM_OUTLINE") && msg.includes("WORKFLOW_CONFIRM_OUTLINE"), `recovery names the flag and sentinel; got ${show(msg)}`);
});
caseEnd();

caseBegin("B2 reset over an approved-then-edited outline is refused as a hash mismatch", "hooks/workflow-mark/reset-handler.js");
run("B2 reset over an approved-then-edited outline is refused as a hash mismatch", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b2", ["clarify_intent", "outline", "detail"]);
  fs.appendFileSync(PAF.ensurePlan(sid, "outline"), "\nedited after approval\n");
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "write_tests", "outline", "artifact-hash-mismatch", reset(sid, "write_tests"), before, count);
});
caseEnd();

caseBegin("B2b CONFIRM_OUTLINE=off does not rescue an approved-then-edited outline", "hooks/workflow-mark/reset-handler.js");
run("B2b CONFIRM_OUTLINE=off does not rescue an approved-then-edited outline", () => {
  // The stored record is a confirm-sentinel with a hash, not a confirm-flag-off record, so the off flag has nothing to waive.
  setConfig("on", "off", "on");
  const sid = seedWf("b2b", ["clarify_intent", "outline", "detail"]);
  fs.appendFileSync(PAF.ensurePlan(sid, "outline"), "\nedited after approval\n");
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "write_tests", "outline", "artifact-hash-mismatch", reset(sid, "write_tests"), before, count);
});
caseEnd();

caseBegin("B2d CONFIRM_DETAIL=off does not rescue an approved-then-edited detail", "hooks/workflow-mark/reset-handler.js");
run("B2d CONFIRM_DETAIL=off does not rescue an approved-then-edited detail", () => {
  setConfig("on", "on", "off");
  const sid = seedWf("b2d", ["clarify_intent", "outline", "detail"]);
  fs.appendFileSync(PAF.ensurePlan(sid, "detail"), "\nedited after approval\n");
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "write_tests", "detail", "artifact-hash-mismatch", reset(sid, "write_tests"), before, count);
});
caseEnd();

caseBegin("B2c a deleted approved outline artifact makes the reset unverifiable", "hooks/workflow-mark/reset-handler.js");
run("B2c a deleted approved outline artifact makes the reset unverifiable", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b2c", ["clarify_intent", "outline", "detail"]);
  fs.rmSync(PAF.ensurePlan(sid, "outline"), { force: true });
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "write_tests", "outline", "artifact-hash-unverifiable", reset(sid, "write_tests"), before, count);
});
caseEnd();

caseBegin("B3 CONFIRM_INTENT=off in the file does not waive clarify_intent for a reset", "hooks/workflow-mark/reset-handler.js");
run("B3 CONFIRM_INTENT=off in the file does not waive clarify_intent for a reset", () => {
  setConfig("off", "on", "on");
  const sid = seedWf("b3", ["outline"]);
  const before = rawState(sid);
  const count = events(sid).length;
  const msg = reset(sid, "detail");
  assertRefused(sid, "detail", "clarify_intent", "no-approval-record", msg, before, count);
  ok(/no off waiver/.test(msg), `recovery says the gate has no off waiver; got ${show(msg)}`);
});
caseEnd();

caseBegin("B4 reset with every prior gate approved synthesises no approval", "hooks/workflow-mark/reset-handler.js");
run("B4 reset with every prior gate approved synthesises no approval", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b4", ["clarify_intent", "outline", "detail"]);
  const approvalsBefore = events(sid, "plan_approval").length;
  const msg = reset(sid, "write_tests");
  eq(events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  eq(events(sid, "reset")[0].origin, "reset-sentinel", "reset anchor keeps its origin");
  eq(resetSentinelApprovals(sid), 0, "reset-sentinel plan_approval events");
  eq(events(sid, "plan_approval").length, approvalsBefore, "no new plan_approval events");
  const st = S.readState(sid);
  eq(CA.APPROVAL_GATED_STEPS.map((s) => CA.evaluateCompletionApproval(sid, s, st).approved), [true, true, true], "gates still verified");
});
caseEnd();

caseBegin("B5 CONFIRM_OUTLINE=off waives an unapproved outline as a confirm-flag-off record", "hooks/workflow-mark/reset-handler.js");
run("B5 CONFIRM_OUTLINE=off waives an unapproved outline as a confirm-flag-off record", () => {
  setConfig("on", "off", "on");
  const sid = seedWf("b5", ["clarify_intent"]);
  const msg = reset(sid, "detail");
  eq(events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  eq(events(sid, "plan_approval").filter((e) => e.step === "outline").map((e) => e.source), ["confirm-flag-off"], "outline approval sources");
  eq(resetSentinelApprovals(sid), 0, "reset-sentinel plan_approval events");
});
caseEnd();

caseBegin("B6 the same reset with CONFIRM_OUTLINE=on is refused", "hooks/workflow-mark/reset-handler.js");
run("B6 the same reset with CONFIRM_OUTLINE=on is refused", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b6", ["clarify_intent"]);
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "detail", "outline", "no-approval-record", reset(sid, "detail"), before, count);
});
caseEnd();

caseBegin("B7 RESET_FROM_outline needs only clarify_intent approved", "hooks/workflow-mark/reset-handler.js");
run("B7 RESET_FROM_outline needs only clarify_intent approved", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b7", ["clarify_intent"]);
  const msg = reset(sid, "outline");
  eq(events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  eq(resetSentinelApprovals(sid), 0, "reset-sentinel plan_approval events");
});
caseEnd();

caseBegin("B8 RESET_FROM_outline with clarify_intent unapproved is refused", "hooks/workflow-mark/reset-handler.js");
run("B8 RESET_FROM_outline with clarify_intent unapproved is refused", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b8", []);
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "outline", "clarify_intent", "no-approval-record", reset(sid, "outline"), before, count);
});
caseEnd();

caseBegin("B9 resets before any gate need no approval", "hooks/workflow-mark/reset-handler.js");
run("B9 resets before any gate need no approval", () => {
  setConfig("on", "on", "on");
  for (const step of ["clarify_intent", "workflow_init"]) {
    const sid = seedWf("b9", []);
    const msg = reset(sid, step);
    eq(events(sid, "reset").length, 1, `RESET_FROM_${step} applied (msg ${show(msg)})`);
  }
});
caseEnd();

caseBegin("B10 a legacy reset-sentinel record still approves and carries a reset", "hooks/workflow-state/completion-approval.js");
run("B10 a legacy reset-sentinel record still approves and carries a reset", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b10", ["clarify_intent", "detail"]);
  const st = JSON.parse(rawState(sid));
  const last = st.events[st.events.length - 1];
  st.events.push({ kind: "plan_approval", step: "outline", source: "reset-sentinel", reason: "legacy reset", artifact_sha256: null,
    artifact_session_id: null, artifact_hash_status: "not-applicable", at: last.at, seq: last.seq + 1, provenance: "declared", origin: "reset-sentinel" });
  fs.writeFileSync(statePath(sid), JSON.stringify(st, null, 2));
  eq(CA.evaluateCompletionApproval(sid, "outline", S.readState(sid)).approved, true, "legacy record approves");
  const msg = reset(sid, "write_tests");
  eq(events(sid, "reset").length, 1, `reset relying on the legacy record applied (msg ${show(msg)})`);
});
caseEnd();

caseBegin("B11 reset-sentinel is no longer a sanctioned source", "hooks/workflow-state/completion-approval.js");
run("B11 reset-sentinel is no longer a sanctioned source", () => {
  const throwsCode = (fn) => { try { fn(); return null; } catch (e) { return e.code || e.message; } };
  eq(throwsCode(() => CA.assertSanctionedSource("reset-sentinel")), "unknown-sanctioned-token", "assertSanctionedSource(reset-sentinel)");
  const sid = seedWf("b11", []);
  PAF.ensurePlan(sid, "outline");
  ok(throwsCode(() => CA.recordPlanApproval(sid, "outline", { source: "reset-sentinel", reason: "forged" })) !== null,
    "recordPlanApproval accepted source reset-sentinel");
  eq(throwsCode(() => CA.assertSanctionedSource("confirm-sentinel")), null, "confirm-sentinel stays sanctioned");
});
caseEnd();

caseBegin("B12 CONFIRM_DETAIL=off waives an unapproved detail as a confirm-flag-off record", "hooks/workflow-mark/reset-handler.js");
run("B12 CONFIRM_DETAIL=off waives an unapproved detail as a confirm-flag-off record", () => {
  setConfig("on", "on", "off");
  const sid = seedWf("b12", ["clarify_intent", "outline"]);
  const msg = reset(sid, "write_tests");
  eq(events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  eq(events(sid, "plan_approval").filter((e) => e.step === "detail").map((e) => e.source), ["confirm-flag-off"], "detail approval sources");
  eq(resetSentinelApprovals(sid), 0, "reset-sentinel plan_approval events");
});
caseEnd();

caseBegin("B12b the same reset with CONFIRM_DETAIL=on and detail unapproved is refused", "hooks/workflow-mark/reset-handler.js");
run("B12b the same reset with CONFIRM_DETAIL=on and detail unapproved is refused", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b12b", ["clarify_intent", "outline"]);
  const before = rawState(sid);
  const count = events(sid).length;
  assertRefused(sid, "write_tests", "detail", "no-approval-record", reset(sid, "write_tests"), before, count);
});
caseEnd();

caseBegin("B13 a refused reset retried stays refused and leaves state byte-identical", "hooks/workflow-mark/reset-handler.js");
run("B13 a refused reset retried stays refused and leaves state byte-identical", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b13", ["clarify_intent", "detail"]);
  const before = rawState(sid);
  const count = events(sid).length;
  for (let i = 0; i < 2; i++) assertRefused(sid, "write_tests", "outline", "no-approval-record", reset(sid, "write_tests"), before, count);
});
caseEnd();

// The same refusals driven through the PostToolUse entrypoint: the dispatch order, session
// resolution and message relay of hooks/workflow-mark.js must not lose or bypass the refusal.
caseBegin("B14 RESET_FROM refusals hold through the real workflow-mark.js hook", "hooks/workflow-mark.js");
for (const c of [
  { name: "outline-unapproved", cfg: ["on", "on", "on"], approved: ["clarify_intent", "detail"], step: "write_tests", gated: "outline", code: "no-approval-record", extra: ["CONFIRM_OUTLINE", "WORKFLOW_CONFIRM_OUTLINE"] },
  { name: "outline-edited", cfg: ["on", "on", "on"], approved: ["clarify_intent", "outline", "detail"], edit: "outline", step: "write_tests", gated: "outline", code: "artifact-hash-mismatch", extra: [] },
  { name: "intent-off-no-waiver", cfg: ["off", "on", "on"], approved: ["outline"], step: "detail", gated: "clarify_intent", code: "no-approval-record", extra: ["no off waiver"] },
  { name: "outline-target-intent-unapproved", cfg: ["on", "on", "on"], approved: [], step: "outline", gated: "clarify_intent", code: "no-approval-record", extra: [] },
]) {
  run(`B14 ${c.name}: hook refuses RESET_FROM_${c.step} with no write`, () => {
    setConfig(...c.cfg);
    const sid = seedWf("b14", c.approved);
    if (c.edit) fs.appendFileSync(PAF.ensurePlan(sid, c.edit), "\nedited after approval\n");
    const before = rawState(sid);
    const count = events(sid).length;
    const msg = resetHook(sid, c.step);
    assertRefused(sid, c.step, c.gated, c.code, msg, before, count);
    for (const s of c.extra) ok(msg.includes(s), `${c.name}: refusal mentions ${show(s)}; got ${show(msg)}`);
  });
}
caseEnd();

caseBegin("B15 an approved RESET_FROM applies through the real hook and synthesises no approval", "hooks/workflow-mark.js");
run("B15 an approved RESET_FROM applies through the real hook and synthesises no approval", () => {
  setConfig("on", "on", "on");
  const sid = seedWf("b15", ["clarify_intent", "outline", "detail"]);
  const approvalsBefore = events(sid, "plan_approval").length;
  const msg = resetHook(sid, "write_tests");
  eq(events(sid, "reset").length, 1, `reset applied (msg ${show(msg)})`);
  eq(resetSentinelApprovals(sid), 0, "reset-sentinel plan_approval events");
  eq(events(sid, "plan_approval").length, approvalsBefore, "no new plan_approval events");
});
caseEnd();

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exitCode = failed === 0 ? 0 : 1;
