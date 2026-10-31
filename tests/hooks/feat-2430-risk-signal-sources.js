#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/risk-signal.js, hooks/post-compact.js, hooks/workflow-gate/handoff-record.js, hooks/workflow-mark/reset-handler.js, bin/supervisor-write-audit-verdict, bin/supervisor-write-audit, hooks/lib/supervisor-state-writer/append.js, hooks/workflow-run-tests.js
// Tags: handoff, risk-signal, nudge-trigger, post-compact, gate-block, reset-from, supervisor-verdict, supervisor-finding, run-tests, fail-open, regression-2430, exit-77, scope:issue-specific, pwsh-not-required, TL2, regression-2652
// Issue #2430 — a "risk" is an event after which unrecorded working knowledge is most likely to be lost, so the omission-check nudge restarts its timer and halves its limits. Six producers stamp <WORKFLOW_STATE_DIR>/<sid>.control/risk-signal.json; everything else must leave it alone, or the halved limits become the permanent default. A test failure while tests are expected to be red (write_tests / review_tests / write_code) is the named exception.
// TL3 gap: the real dispatch of each producer (PostCompact, a live workflow-gate block, the PostToolUse run-tests hook after a real suite run) is not driven; each is fed the envelope or call it receives in production. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.
// Every producer and fixture runs in its own node process, so no module cache or env snapshot is shared;
// each observation is taken synchronously in order and only compared inside test().

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const WF = process.env.WORKFLOW_STATE_DIR;
process.env.WORKFLOW_PLANS_DIR = WF;
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "risk-sources-"));
for (const d of ["home", "transcripts"]) fs.mkdirSync(path.join(TMP, d));
process.env.HOME = path.join(TMP, "home");
process.env.USERPROFILE = path.join(TMP, "home");
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
const ROOT = path.join(__dirname, "..", "..");
const AGENTS = path.resolve(ROOT).replace(/\\/g, "/");
process.env.AGENTS = AGENTS;
process.chdir(TMP);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const FIXTURES = {
  "seed.js": `// node seed.js <sid> [currentStep] — active state; with currentStep, every earlier
// step is settled (approval-gated and glossary-gated ones skipped) and the result is verified.
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const { APPROVAL_GATED_STEPS } = require(process.env.AGENTS + '/hooks/workflow-state/completion-approval');
const { STAGE_STEP } = require(process.env.AGENTS + '/hooks/workflow-state/glossary-check/scope');
const { resolveCurrentEffectiveStep } = require(process.env.AGENTS + '/hooks/workflow-state/current-step');
const GATED = APPROVAL_GATED_STEPS.concat(Object.values(STAGE_STEP));
const [sid, target] = process.argv.slice(2);
S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
S.markStep(sid, 'workflow_init', 'complete');
if (target) {
  for (const step of S.VALID_STEPS.slice(1, S.VALID_STEPS.indexOf(target))) {
    S.markStep(sid, step, GATED.includes(step) ? 'skipped' : 'complete');
  }
  const cur = resolveCurrentEffectiveStep(sid);
  if (cur !== target) process.stdout.write('SEEDFAIL:current=' + cur);
}
`,
  "risk.js": `// node risk.js <sid> <sinceMs> — "<source>" when a fresh stamp exists, NONE when absent.
const fs = require('fs');
const [sid, since] = process.argv.slice(2);
let raw;
try { raw = fs.readFileSync(process.env.WORKFLOW_STATE_DIR + '/' + sid + '.control/risk-signal.json', 'utf8'); }
catch (e) { process.stdout.write('NONE'); process.exit(0); }
let j;
try { j = JSON.parse(raw); } catch (e) { process.stdout.write('UNPARSEABLE'); process.exit(0); }
const at = new Date(j.last_risk_at).getTime();
if (!(at >= Number(since) - 1000 && at <= Date.now() + 1000)) { process.stdout.write('STALE:' + JSON.stringify(j)); process.exit(0); }
process.stdout.write(String(j.source));
`,
  "call.js": `// node call.js <what> <sid> [arg] — drive a library producer; prints its return.
const A = process.env.AGENTS;
const [what, sid, arg] = process.argv.slice(2);
let r;
if (what === 'gate') r = require(A + '/hooks/workflow-gate/handoff-record.js').recordGateBlock(sid, 'blocked for the fixture', { command: 'git push' });
if (what === 'finding') r = require(A + '/hooks/lib/supervisor-state-writer').appendFinding(sid, { categories: ['workflow'], severity: arg, detail: 'fixture finding', reporter: 'write-tests' });
if (what === 'reset') {
  const msgs = [];
  require(A + '/hooks/workflow-mark/reset-handler').handle({ cmd: arg, sessionId: sid, pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(m), repoCwd: process.cwd() });
  r = msgs.join(' ');
}
process.stdout.write(typeof r === 'string' ? r : JSON.stringify(r));
`,
  "observed.js": `// node observed.js <sid> — "yes" when the run-tests hook recorded a failed run (non-vacuity guard).
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const st = S.readState(process.argv[2]);
process.stdout.write(JSON.stringify((st && st.steps && st.steps.run_tests) || {}).indexOf('"last_run_failed":true') !== -1 ? 'yes' : 'no');
`,
  "unit.js": `const fs = require('fs');
const W = process.env.WORKFLOW_STATE_DIR;
const R = require(process.env.AGENTS + '/hooks/lib/risk-signal.js');
const bad = [];
const want = ['compaction', 'gate-block', 'reset-from', 'supervisor-verdict', 'supervisor-finding', 'test-failure'];
if (JSON.stringify(R.RISK_SOURCES) !== JSON.stringify(want)) bad.push('RISK_SOURCES:' + JSON.stringify(R.RISK_SOURCES));
if (R.readLastRiskAt('u-none') !== null) bad.push('absent-not-null');
R.recordRiskSignal('u-ok', 'gate-block');
const at = R.readLastRiskAt('u-ok');
if (typeof at !== 'number' || Math.abs(at - Date.now()) > 5000) bad.push('readLastRiskAt:' + String(at));
R.recordRiskSignal('u-bad-source', 'not-a-source');
if (!fs.existsSync(W + '/u-ok.control/risk-signal.json')) bad.push('valid-stamp-not-at-control-path');
if (fs.existsSync(W + '/u-bad-source.control/risk-signal.json')) bad.push('unknown-source-written');
for (const sid of ['../escape', '', null]) { try { R.recordRiskSignal(sid, 'gate-block'); } catch (e) { bad.push('threw:' + e.message); } }
if ([W, W + '/..'].some((d) => fs.readdirSync(d).some((f) => f.indexOf('escape') !== -1))) bad.push('invalid-sid-written');
for (const sid of ['../escape', '', null]) { try { if (R.readLastRiskAt(sid) !== null) bad.push('invalid-sid-read-not-null'); } catch (e) { bad.push('read-threw:' + e.message); } }
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
`,
  "exit77.js": `// node exit77.js <sid> — "<last_run_failed>/<last_exit_code>" of run_tests (non-vacuity guard).
const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
const st = S.readState(process.argv[2]);
const e = (st && st.steps && st.steps.run_tests) || {};
process.stdout.write(String(e.last_run_failed) + '/' + String(e.last_exit_code));
`,
  "rename.js": `// node rename.js <legacy|stamp> <sid> — #2652 rename checks; prints OK or BAD:<reasons>.
const fs = require('fs');
const C = process.env.WORKFLOW_STATE_DIR + '/' + process.argv[3] + '.control';
const R = require(process.env.AGENTS + '/hooks/lib/risk-signal.js');
const bad = [];
if (process.argv[2] === 'legacy') {
  fs.mkdirSync(C, { recursive: true });
  fs.writeFileSync(C + '/handoff-risk.json', JSON.stringify({ last_risk_at: new Date().toISOString(), source: 'gate-block' }));
  if (!fs.existsSync(C + '/handoff-risk.json')) bad.push('legacy-fixture-missing');
  const at = R.readLastRiskAt(process.argv[3]);
  if (at !== null) bad.push('legacy-read:' + String(at));
} else {
  R.recordRiskSignal(process.argv[3], 'gate-block');
  if (!fs.existsSync(C + '/risk-signal.json')) bad.push('risk-signal.json-missing');
  if (fs.existsSync(C + '/handoff-risk.json')) bad.push('handoff-risk.json-written');
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
`,
};
for (const [name, body] of Object.entries(FIXTURES)) fs.writeFileSync(path.join(TMP, name), body);

const trimEnd = (s) => String(s || "").replace(/\n+$/, "");
function runNode(args, input) {
  return spawnSync(process.execPath, args, { cwd: TMP, input, encoding: "utf8", timeout: 60000 });
}
// nj(fixture, ...args) -> stdout and stderr together, like the shell's 2>&1 capture.
function nj(name, ...args) {
  const r = runNode([path.join(TMP, name), ...args]);
  return trimEnd(String(r.stdout || "") + String(r.stderr || ""));
}
function expect(name, got, want) {
  test(name, () => assert.strictEqual(got, want, `want=${want} got=${String(got).slice(0, 300)}`));
}
function seed(sid, target) {
  const o = nj("seed.js", ...(target ? [sid, target] : [sid]));
  if (o !== "") test(`fixture seed for ${sid}`, () => assert.fail(o));
}
const risk = (sid, since) => nj("risk.js", sid, String(since));
const compact = (sid) => trimEnd(runNode([path.join(ROOT, "hooks", "post-compact.js")], JSON.stringify({ session_id: sid })).stdout);
function verdictCli(sid, verdict) {
  const r = runNode([path.join(ROOT, "bin", "supervisor-write-audit-verdict"), "--session-id", sid, "--verdict", verdict, "--verdict-summary", "fixture"]);
  return { out: trimEnd(r.stdout), rc: String(r.status) };
}
// runTestsHook(sid, exit, contract) -> exit code of the PostToolUse hook fed the envelope after tests/run-all.sh.
function runTestsHook(sid, exit, contract) {
  const c = contract || (exit === 0 ? "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0" : "RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5");
  const envelope = { tool_name: "Bash", tool_input: { command: `bash ${AGENTS}/tests/run-all.sh`, cwd: AGENTS }, tool_response: { exit_code: exit, stdout: `${c}\n` }, session_id: sid };
  return String(runNode([path.join(ROOT, "hooks", "workflow-run-tests.js")], JSON.stringify(envelope)).status);
}
const injected = (s) => (s.includes('"additionalContext"') ? "yes" : `no:${s.slice(0, 120)}`);
const blockRiskFile = (sid) => fs.mkdirSync(path.join(WF, `${sid}.control`, "risk-signal.json"), { recursive: true });
const RESET_OK = 'echo "<<WORKFLOW_RESET_FROM_clarify_intent: redo the intent check>>"';

caseBegin("risk-module-contract", "hooks/lib/risk-signal.js");
expect("U1: RISK_SOURCES is the six-source list; unknown sources and invalid sids write nothing and read back null; the stamp reads back as ms", nj("unit.js"), "OK");
caseEnd();

caseBegin("compaction-stamps-risk", "hooks/post-compact.js");
{
  seed("rk-compact");
  const t = Date.now();
  compact("rk-compact");
  expect("RS1: a compaction stamps source compaction", risk("rk-compact", t), "compaction");
}
caseEnd();

caseBegin("gate-block-stamps-risk", "hooks/workflow-gate/handoff-record.js");
{
  seed("rk-gate");
  const t = Date.now();
  nj("call.js", "gate", "rk-gate");
  expect("RS2: a gate block stamps source gate-block", risk("rk-gate", t), "gate-block");
}
caseEnd();

caseBegin("reset-from-stamps-risk-only-on-success", "hooks/workflow-mark/reset-handler.js");
{
  seed("rk-reset");
  const t = Date.now();
  expect("RS3: the reset is applied", nj("call.js", "reset", "rk-reset", RESET_OK), "");
  expect("RS3: a successful RESET_FROM stamps source reset-from", risk("rk-reset", t), "reset-from");
  seed("rk-reset-rej");
  nj("call.js", "reset", "rk-reset-rej", 'echo "<<WORKFLOW_RESET_FROM_no_such_step: a valid reason>>"');
  expect("N3: a rejected RESET_FROM stamps nothing", risk("rk-reset-rej", 0), "NONE");
}
caseEnd();

caseBegin("verdict-stamps-risk-for-warn-block", "bin/supervisor-write-audit-verdict");
{
  for (const v of ["WARN", "BLOCK"]) {
    seed(`rk-verdict-${v}`);
    const t = Date.now();
    verdictCli(`rk-verdict-${v}`, v);
    expect(`RS4: verdict ${v} stamps source supervisor-verdict`, risk(`rk-verdict-${v}`, t), "supervisor-verdict");
  }
  seed("rk-verdict-continue");
  verdictCli("rk-verdict-continue", "CONTINUE");
  expect("N1: verdict CONTINUE stamps nothing", risk("rk-verdict-continue", 0), "NONE");
}
caseEnd();

caseBegin("set-audit-verdict-stamps-risk", "bin/supervisor-write-audit");
{
  seed("rk-wa-block");
  const t = Date.now();
  runNode([path.join(ROOT, "bin", "supervisor-write-audit"), "--session-id", "rk-wa-block", "--set-audit-verdict", "BLOCK", "--set-audit-verdict-summary", "fixture"]);
  expect("RS4b: --set-audit-verdict BLOCK stamps source supervisor-verdict", risk("rk-wa-block", t), "supervisor-verdict");
}
caseEnd();

caseBegin("finding-stamps-risk_at_warning_and_above", "hooks/lib/supervisor-state-writer/append.js");
{
  for (const sev of ["warning", "error"]) {
    seed(`rk-finding-${sev}`);
    const t = Date.now();
    expect(`RS5: a ${sev} finding is still accepted`, nj("call.js", "finding", `rk-finding-${sev}`, sev), "true");
    expect(`RS5: a ${sev} finding stamps source supervisor-finding`, risk(`rk-finding-${sev}`, t), "supervisor-finding");
  }
  seed("rk-finding-notice");
  nj("call.js", "finding", "rk-finding-notice", "notice");
  expect("N2: a notice finding stamps nothing", risk("rk-finding-notice", 0), "NONE");
}
caseEnd();

caseBegin("test-failure-stamps-risk_after_implementation", "hooks/workflow-run-tests.js");
{
  seed("rk-tests-run", "run_tests");
  const t = Date.now();
  runTestsHook("rk-tests-run", 1);
  expect("RS6: the hook did observe the failing run", nj("observed.js", "rk-tests-run"), "yes");
  expect("RS6: a failing suite at run_tests stamps source test-failure", risk("rk-tests-run", t), "test-failure");
  for (const step of ["write_tests", "review_tests", "write_code"]) {
    seed(`rk-tests-${step}`, step);
    runTestsHook(`rk-tests-${step}`, 1);
    expect(`N4: the hook did observe the failing run during ${step}`, nj("observed.js", `rk-tests-${step}`), "yes");
    expect(`N4: a failing suite during ${step} (red expected) stamps nothing`, risk(`rk-tests-${step}`, 0), "NONE");
  }
  seed("rk-tests-green", "run_tests");
  runTestsHook("rk-tests-green", 0);
  expect("N5: a green suite stamps nothing", risk("rk-tests-green", 0), "NONE");
}
caseEnd();

// An unwritable risk file (a directory at its path) must cost nothing but the
// stamp: every producer's own output and exit code stay what they were.
caseBegin("risk_write_failure_changes_no_producer", "bin/supervisor-write-audit-verdict");
{
  for (const sid of ["rk-io-compact", "rk-io-gate", "rk-io-reset", "rk-io-verdict", "rk-io-finding"]) {
    seed(sid);
    blockRiskFile(sid);
  }
  expect("I1: PostCompact still re-injects", injected(compact("rk-io-compact")), "yes");
  expect("I1: recordGateBlock still writes its entry", nj("call.js", "gate", "rk-io-gate"), '{"written":true,"reason":"ok"}');
  expect("I1: the reset is still applied", nj("call.js", "reset", "rk-io-reset", RESET_OK), "");
  const v = verdictCli("rk-io-verdict", "WARN");
  expect("I1: the verdict CLI keeps exit 0", v.rc, "0");
  expect("I1: the verdict CLI keeps its stdout", v.out, '{"accepted":true,"audit_run_id":null}');
  expect("I1: appendFinding still returns true", nj("call.js", "finding", "rk-io-finding", "warning"), "true");
  seed("rk-io-tests", "run_tests");
  blockRiskFile("rk-io-tests");
  expect("I1: the run-tests hook keeps exit 0", runTestsHook("rk-io-tests", 1), "0");
  expect("I1: the run-tests hook still records the failed run", nj("observed.js", "rk-io-tests"), "yes");
}
caseEnd();

// #2501 C1: run-all exit 77 means nothing ran (all SKIP / none selected), not a red suite.
caseBegin("exit-77-stamps-no-risk", "hooks/workflow-run-tests.js");
{
  seed("rk-tests-77", "run_tests");
  runTestsHook("rk-tests-77", 77, "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=2 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0");
  expect("N6: the hook recorded exit 77 as a not-failed run", nj("exit77.js", "rk-tests-77"), "false/77");
  expect("N6: an exit-77 run at run_tests stamps nothing", risk("rk-tests-77", 0), "NONE");
}
caseEnd();

// #2652: the pre-rename handoff-risk.json is not migrated, so a lone one reads back as no risk.
caseBegin("risk-signal-renamed", "hooks/lib/risk-signal.js");
{
  expect("L1: a lone legacy handoff-risk.json reads back as null", nj("rename.js", "legacy", "rk-rename-legacy"), "OK");
  expect("L2: a stamp lands at risk-signal.json and never at handoff-risk.json", nj("rename.js", "stamp", "rk-rename-new"), "OK");
  expect("L3: the retired module hooks/lib/handoff-risk-signal.js is gone", fs.existsSync(path.join(ROOT, "hooks", "lib", "handoff-risk-signal.js")), false);
}
caseEnd();
