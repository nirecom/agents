#!/usr/bin/env node
// tests/hooks/feature-2820-receipt-step-boundary.js
// Tests: hooks/lib/presentation-receipt.js, hooks/stop-confirm-plan-guard.js, hooks/confirm-checkpoint.js, hooks/stop-confirm-plan-guard/block-reasons.js, hooks/stop-confirm-plan-guard/undecidable.js, hooks/lib/confirm-continuation.js, hooks/lib/plan-link-turn-check.js, hooks/lib/confirm-sentinel.js, hooks/lib/temporary-migrations/stage-to-step/index.js
// Tags: TL2, hooks, confirm-plan, presentation-receipt, stop-guard, workflow-step, plan-artifact-name, compat-layer, scope:issue-specific, glossary, migration
// TL3 gap: the real host's Stop -> PreToolUse ordering of one presentation and its CONFIRM echo;
// mitigated by bin/check-verification-gate.sh (category: hook-registration).
// #2820: the receipt is keyed by the workflow step, the plan file and its link line by the plan
// artifact name; stepForSuffix / rowFor(step).suffix are the only conversions between the two.
"use strict";

const { after: afterAll, test } = require("node:test");
const assert = require("node:assert/strict");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2820rb-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.PLAN_LANG;
process.chdir(SCRATCH);
afterAll(() => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const R = require("./feature-2729-presentation-receipt/fixture");
const { U, A, T, W, TR, BASH } = R;
const req = (rel) => require(path.join(R.ROOT, rel));
const LOG = (sid) => req("hooks/workflow-state/state-io/control-dir").controlPath(sid, "presentation-receipt-log.jsonl", { forWrite: true });
const legacyFile = (sid) => path.join(R.stateDirOf(sid), `${sid}.confirm-plan-receipt-intent.json`);
const receiptBody = (s) => ({ absPath: s.plan, link: { kind: "url", value: s.url }, contentSha: R.sha256(s.plan), anchorUuid: "a-x" });
// spyGate(answer) -> a gateFor stub recording every key it is asked for.
function spyGate(answer) {
  const seen = [];
  const fn = (k) => { seen.push(k); return answer; };
  fn.seen = seen;
  return fn;
}
// stepKeyed(seen) -> the gate was asked at least once, and only by the intent plan's step.
const stepKeyed = (seen) => seen.length > 0 && seen.every((k) => k === "clarify_intent");

caseBegin("receipt-api-keyed-by-step", "hooks/lib/presentation-receipt.js");
test("receipt-api-keyed-by-step", () => {
  const PR = req("hooks/lib/presentation-receipt");
  assert.deepEqual(PR.RECEIPT_STEPS, ["clarify_intent", "outline", "detail"]);
  assert.equal(PR.STAGES, undefined, "STAGES is retired");
  const s = R.sessionAt("intent", { tag: 7001 });
  const want = path.join(R.stateDirOf(s.sid), `${s.sid}.confirm-plan-receipt-clarify_intent.json`);
  assert.equal(PR.receiptPath(s.sid, "clarify_intent"), want);
  assert.equal(PR.writeReceipt(s.sid, "clarify_intent", receiptBody(s)), true);
  assert.ok(fs.existsSync(want), "the receipt file is named by the step");
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "no receipt file named by the plan artifact");
  assert.equal(PR.readReceipt(s.sid, "clarify_intent").ok, true);
  const lines = PR.readReceiptLog(s.sid);
  const w = lines.find((l) => l.event === "write");
  assert.ok(w && w.step === "clarify_intent" && !("stage" in w) && w.path === want, JSON.stringify(lines));
  assert.equal(PR.consumeReceipt(s.sid, "clarify_intent"), true);
  assert.ok(!fs.existsSync(want));
  const c = PR.readReceiptLog(s.sid).find((l) => l.event === "consume");
  assert.ok(c && c.step === "clarify_intent" && !("stage" in c), "the consume line is keyed by step");
});
test("receipt-api-rejects-a-plan-artifact-name", () => {
  // The artifact name reaching the step-keyed API is the boundary mix-up this guards against.
  const PR = req("hooks/lib/presentation-receipt");
  const s = R.sessionAt("intent", { tag: 7002 });
  assert.equal(PR.writeReceipt(s.sid, "intent", receiptBody(s)), false);
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "writeReceipt(intent) writes nothing");
  assert.ok(!R.receiptExists(s.sid, "clarify_intent"));
  // outline / detail are both an artifact name and a step: they stay accepted.
  const o = R.sessionAt("outline", { tag: 7003 });
  assert.equal(PR.writeReceipt(o.sid, "outline", receiptBody(o)), true);
});
caseEnd();

caseBegin("legacy-intent-receipt-consumed-as-clarify-intent", "hooks/lib/temporary-migrations/stage-to-step/index.js");
test("legacy-intent-receipt-consumed-as-clarify-intent", () => {
  const M = req("hooks/lib/temporary-migrations/stage-to-step/index.js");
  const PR = req("hooks/lib/presentation-receipt");
  const s = R.sessionAt("intent", { tag: 7011 });
  assert.equal(M.legacyReceiptPath(s.sid, "clarify_intent"), legacyFile(s.sid));
  fs.mkdirSync(path.dirname(legacyFile(s.sid)), { recursive: true });
  fs.writeFileSync(legacyFile(s.sid), JSON.stringify(Object.assign(receiptBody(s), { writtenAt: new Date().toISOString() })));
  const r = PR.readReceipt(s.sid, "clarify_intent");
  assert.equal(r.ok, true, "an old -intent.json is read as the clarify_intent receipt");
  assert.equal(r.receipt.absPath, s.plan);
  assert.equal(PR.consumeReceipt(s.sid, "clarify_intent"), true);
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "consuming clarify_intent removes the old -intent.json");
});
test("legacy-intent-receipt-discarded-as-clarify-intent", () => {
  const PR = req("hooks/lib/presentation-receipt");
  const s = R.sessionAt("intent", { tag: 7012 });
  fs.mkdirSync(path.dirname(legacyFile(s.sid)), { recursive: true });
  fs.writeFileSync(legacyFile(s.sid), JSON.stringify(Object.assign(receiptBody(s), { writtenAt: new Date().toISOString() })));
  PR.discardReceipt(s.sid, "clarify_intent");
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "discarding clarify_intent removes the old -intent.json");
});
test("legacy-receipt-log-line-normalized", () => {
  const M = req("hooks/lib/temporary-migrations/stage-to-step/index.js");
  const PR = req("hooks/lib/presentation-receipt");
  const old = { event: "write", stage: "intent", path: "fixture-old-intent.json", at: "2026-01-01T00:00:00.000Z" };
  assert.deepEqual(M.normalizeReceiptLogLine(old), { event: "write", step: "clarify_intent", path: old.path, at: old.at });
  const cur = { event: "consume", step: "outline", path: "fixture-o.json", at: old.at };
  assert.deepEqual(M.normalizeReceiptLogLine(cur), cur, "a step-keyed line passes through unchanged");
  const s = R.sessionAt("intent", { tag: 7013 });
  fs.mkdirSync(path.dirname(LOG(s.sid)), { recursive: true });
  fs.writeFileSync(LOG(s.sid), JSON.stringify(old) + "\n" + JSON.stringify(cur) + "\n");
  const lines = PR.readReceiptLog(s.sid);
  assert.deepEqual(lines.map((l) => l.step), ["clarify_intent", "outline"]);
  assert.ok(lines.every((l) => !("stage" in l)), JSON.stringify(lines));
});
test("legacy-intent-receipt-reaches-the-dialog", () => {
  const s = R.sessionAt("intent", { tag: 7014 });
  fs.mkdirSync(path.dirname(legacyFile(s.sid)), { recursive: true });
  fs.writeFileSync(legacyFile(s.sid), JSON.stringify(Object.assign(receiptBody(s), { writtenAt: new Date().toISOString() })));
  const e = R.echo(s.sid, "intent");
  assert.ok(e.dialog, "a receipt left by the old name still lets CONFIRM_INTENT through: " + JSON.stringify(e.json));
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "the pass consumes the old file");
});
test("new-and-legacy-intent-receipts-coexisting", () => {
  // The new file wins, and one consume leaves nothing a later CONFIRM_INTENT could pass on.
  const PR = req("hooks/lib/presentation-receipt");
  const s = R.sessionAt("intent", { tag: 7015 });
  fs.mkdirSync(path.dirname(legacyFile(s.sid)), { recursive: true });
  const stale = path.join(SCRATCH, "stale-intent.md");
  fs.writeFileSync(legacyFile(s.sid), JSON.stringify(Object.assign(receiptBody(s), { absPath: stale, writtenAt: new Date().toISOString() })));
  assert.equal(PR.writeReceipt(s.sid, "clarify_intent", receiptBody(s)), true);
  const r = PR.readReceipt(s.sid, "clarify_intent");
  assert.equal(r.ok, true);
  assert.equal(r.receipt.absPath, s.plan, "the step-named receipt is read, not the old -intent.json");
  assert.equal(PR.consumeReceipt(s.sid, "clarify_intent"), true);
  assert.equal(PR.readReceipt(s.sid, "clarify_intent").ok, false, "no receipt is left to read after one consume");
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "the old -intent.json does not outlive the consume");
});
caseEnd();

caseBegin("stop-to-checkpoint-intent-round-trip", "hooks/stop-confirm-plan-guard.js");
test("stop-to-checkpoint-intent-round-trip", () => {
  const s = R.sessionAt("intent", { tag: 7021 });
  const st = R.stop(s.sid, R.presentTurn(s, ["intent"], "Here is the plan.\n\n" + s.urlLine), { input: { last_assistant_message: "Here is the plan.\n\n" + s.urlLine } });
  assert.ok(st.continued && st.reason.includes("WORKFLOW_CONFIRM_INTENT"), JSON.stringify({ rc: st.rc, out: st.out }));
  assert.ok(R.receiptExists(s.sid, "clarify_intent"), "settleStop writes the clarify_intent receipt");
  assert.ok(!fs.existsSync(legacyFile(s.sid)), "no receipt named by the plan artifact");
  const e = R.echo(s.sid, "intent");
  assert.ok(e.dialog, "confirm-checkpoint reads the receipt settleStop wrote: " + JSON.stringify(e.json));
  assert.ok(!R.receiptExists(s.sid, "clarify_intent"), "the pass consumes it");
});
caseEnd();

caseBegin("artifact-names-stay-on-the-artifact-side", "hooks/lib/plan-link-turn-check.js");
test("plan-artifact-names-derived-from-the-step-table", () => {
  const PST = req("hooks/workflow-state/plan-step-table");
  assert.deepEqual(PST.PLAN_ARTIFACT_NAMES, Object.values(PST.PLAN_STEP_TABLE).map((r) => r.suffix));
  assert.deepEqual(PST.PLAN_ARTIFACT_NAMES, ["intent", "outline", "detail"]);
});
test("parse-sentinel-returns-the-step", () => {
  const CS = req("hooks/lib/confirm-sentinel");
  assert.deepEqual(CS.parseSentinel(R.echoOf("intent")), { step: "clarify_intent" });
  assert.deepEqual(CS.parseSentinel(R.echoOf("outline")), { step: "outline" });
  assert.deepEqual(CS.parseSentinel(R.echoOf("detail")), { step: "detail" });
  assert.equal(CS.parseSentinel("echo hello"), null);
  assert.ok(Array.isArray(CS.CONFIRM_STEP_PATTERNS) && CS.CONFIRM_STAGE_PATTERNS === undefined);
});
test("stages-to-check-returns-artifact-names", () => {
  const tc = req("hooks/lib/plan-link-turn-check");
  assert.deepEqual(tc.stagesToCheck({ markers: [{ suffix: "outline" }] }), ["outline"]);
  const confirmIntent = [A("a-c", BASH(R.echoOf("intent"), "c1"))];
  assert.deepEqual(tc.stagesToCheck({ markers: [], turnEntries: confirmIntent }), ["intent"]);
  const confirmOutline = [A("a-c", BASH(R.echoOf("outline"), "c1"))];
  assert.deepEqual(tc.stagesToCheck({ markers: [], turnEntries: confirmOutline }), ["outline"]);
});
test("undecidable-marker-artifacts-picks-intent", () => {
  const UD = req("hooks/stop-confirm-plan-guard/undecidable");
  assert.equal(UD.markerStages, undefined, "markerStages is renamed");
  assert.deepEqual(UD.markerArtifacts([{ suffix: "intent" }, { suffix: "intent" }, { suffix: "detail" }, { suffix: "clarify_intent" }]), ["intent", "detail"]);
});
caseEnd();

caseBegin("gate-lookup-receives-the-step", "hooks/stop-confirm-plan-guard/block-reasons.js");
// outline and detail are spelled the same as artifact and step, and intent's gate is ON whether it is
// looked up or not, so only a spy on the lookup key tells a missed conversion apart.
test("plan-link-reason-gate-key", () => {
  const BR = req("hooks/stop-confirm-plan-guard/block-reasons");
  const s = R.sessionAt("intent", { tag: 7031 });
  const gateFor = spyGate("ON");
  // The link line is in the last text block, so planLinkReason passes and its gate lookup is recorded.
  BR.firstBlock({ sid: s.sid, markers: [{ suffix: "intent", absPath: s.plan }], tail: { lastTextBlock: s.urlLine, entries: [] },
    gateFor, linkFor: () => ({ url: s.url }) }, []);
  assert.ok(stepKeyed(gateFor.seen), JSON.stringify(gateFor.seen));
});
test("close-on-link-reason-gate-key", () => {
  const BR = req("hooks/stop-confirm-plan-guard/block-reasons");
  const s = R.sessionAt("intent", { tag: 7032 });
  const gateFor = spyGate("ON");
  // planLinkReason finds the link in the last text block, then closeOnLinkReason judges the prose after it.
  const r = BR.firstBlock({ sid: s.sid, markers: [{ suffix: "intent", absPath: s.plan }],
    tail: { lastTextBlock: s.urlLine + "\n\nDoes this look right?", entries: [] }, gateFor, linkFor: () => ({ url: s.url }) }, []);
  assert.ok(gateFor.seen.length === 2 && stepKeyed(gateFor.seen), JSON.stringify(gateFor.seen));
  assert.ok(r && r.kind === "not-last", "an unapproved intent link followed by prose still blocks: " + JSON.stringify(r));
});
test("presented-artifacts-of-text-gate-key", () => {
  const CC = req("hooks/lib/confirm-continuation");
  const s = R.sessionAt("intent", { tag: 7033 });
  const gateFor = spyGate("ON");
  const out = CC.presentedArtifactsOfText({ sid: s.sid, lastText: "Here.\n\n" + s.urlLine, stages: ["intent"], gateFor, linkFor: () => ({ url: s.url }) });
  assert.ok(stepKeyed(gateFor.seen), JSON.stringify(gateFor.seen));
  assert.equal(out.length, 1);
});
caseEnd();

caseBegin("confirm-outline-off-stop-verdicts", "hooks/stop-confirm-plan-guard.js");
// The OFF verdict and its ON counterpart for both Stop block reasons that read the gate.
function earlierLinkTurn(s) {
  R.turnMarker(s.sid, "outline", s.plan);
  return R.writeTranscript(s.sid, [U("write the plan", "u-p"), A("a-w", W(s.plan, "w1")), TR("w1", "u-tr"),
    A("a-early", T("Here is the plan.\n\n" + s.urlLine)), A("a-last", T("Done for now."))]);
}
for (const gate of ["off", "on"]) {
test(`plan-link-turn-scope-confirm-outline-${gate}`, () => {
  const s = R.sessionAt("outline", { tag: gate === "off" ? 7041 : 7042 });
  const st = R.stop(s.sid, earlierLinkTurn(s), { cfg: R.cfg({ CONFIRM_OUTLINE: gate }), input: { last_assistant_message: "Done for now." } });
  if (gate === "off") assert.ok(!st.blocked && st.rc === 0, "OFF needs the link line once in the turn: " + st.out);
  else assert.ok(st.blocked && st.reason.includes("plan-link"), "ON needs it in the last text block: " + st.out);
});
test(`close-on-link-confirm-outline-${gate}`, () => {
  const s = R.sessionAt("outline", { tag: gate === "off" ? 7043 : 7044 });
  const last = "Here is the plan.\n\n" + s.urlLine + "\n\nDoes this look right?";
  const st = R.stop(s.sid, R.presentTurn(s, ["outline"], last), { cfg: R.cfg({ CONFIRM_OUTLINE: gate }), input: { last_assistant_message: last } });
  if (gate === "off") assert.ok(!st.blocked && st.rc === 0, "OFF: prose after the link line does not block: " + st.out);
  else assert.ok(st.blocked && /not.last|close/i.test(st.reason), "ON: prose after the link line blocks: " + st.out);
});
}
caseEnd();

// The stage -> step compat layer: legacy glossary stage values, legacy glossary_check records and
// each CLI's legacy --stage value map onto workflow step names.
const COMPAT = "hooks/lib/temporary-migrations/stage-to-step/index.js";
const LEGACY = {
  intent: "clarify_intent", outline: "outline", detail: "detail",
  tests: "review_tests", code: "review_security", docs: "review_docs",
};
// Swallows stderr while fn runs and returns what was written.
function captureStderr(fn) {
  const orig = process.stderr.write;
  let text = "";
  process.stderr.write = (chunk) => { text += String(chunk); return true; };
  try {
    return { value: fn(), stderr: text };
  } finally {
    process.stderr.write = orig;
  }
}

caseBegin("legacy glossary stage map covers every old value", "hooks/lib/temporary-migrations/stage-to-step/index.js");
test("LEGACY_GLOSSARY_STAGE_TO_STEP maps the six legacy values and nothing else", () => {
  assert.deepEqual(Object.assign({}, req(COMPAT).LEGACY_GLOSSARY_STAGE_TO_STEP), LEGACY);
});
test("stepOfLegacyGlossaryStage: legacy value -> step, anything else -> null", () => {
  const M = req(COMPAT);
  for (const [stage, step] of Object.entries(LEGACY)) assert.equal(M.stepOfLegacyGlossaryStage(stage), step, stage);
  for (const v of ["review_tests", "clarify_intent", "write_code", "bogus", "", undefined, null, "constructor", "__proto__", "toString", "Tests"]) {
    assert.equal(M.stepOfLegacyGlossaryStage(v), null, String(v));
  }
});
caseEnd();

caseBegin("normalizeGlossaryRecord rewrites a legacy record to step", "hooks/lib/temporary-migrations/stage-to-step/index.js");
test("normalizeGlossaryRecord: stage without step becomes step, stage dropped, other fields kept", () => {
  const M = req(COMPAT);
  const legacy = { v: 1, stage: "tests", fingerprint: "f".repeat(64), findings: [], grants: [], ledger_grants: [{ norm: "a", discrim: "d1" }] };
  const copy = JSON.parse(JSON.stringify(legacy));
  const got = M.normalizeGlossaryRecord(legacy);
  assert.deepEqual(got, { v: 1, step: "review_tests", fingerprint: "f".repeat(64), findings: [], grants: [], ledger_grants: [{ norm: "a", discrim: "d1" }] });
  assert.equal("stage" in got, false);
  assert.deepEqual(legacy, copy, "the input record is not mutated");
  for (const [stage, step] of Object.entries(LEGACY)) assert.equal(M.normalizeGlossaryRecord({ v: 1, stage }).step, step, stage);
});
test("normalizeGlossaryRecord: a record that already has step is left as it is, and is idempotent", () => {
  const M = req(COMPAT);
  assert.deepEqual(M.normalizeGlossaryRecord({ v: 1, step: "review_docs", grants: [] }), { v: 1, step: "review_docs", grants: [] });
  for (const rec of [{ v: 1, stage: "code", grants: [] }, { v: 1, step: "outline" }]) {
    const once = M.normalizeGlossaryRecord(rec);
    assert.deepEqual(M.normalizeGlossaryRecord(once), once, JSON.stringify(rec));
  }
});
test("normalizeReceiptLogLine maps outline and detail stage lines onto the same-named step", () => {
  const M = req(COMPAT);
  for (const st of ["outline", "detail"]) {
    const old = { event: "consume", stage: st, path: `/x/${st}.json`, at: "2026-01-01T00:00:00.000Z" };
    assert.deepEqual(M.normalizeReceiptLogLine(old), { event: "consume", step: st, path: old.path, at: old.at }, st);
  }
});
caseEnd();

caseBegin("stepOfLegacyStageArg maps each CLI's legacy --stage values", "hooks/lib/temporary-migrations/stage-to-step/index.js");
test("stepOfLegacyStageArg: per-CLI value sets, null outside them, deprecation on stderr", () => {
  const M = req(COMPAT);
  const plan = { intent: "clarify_intent", outline: "outline", detail: "detail" };
  const table = { "check-glossary-drift": LEGACY, "plan-artifact-path": plan, "plan-link": plan };
  for (const [cli, map] of Object.entries(table)) {
    for (const [v, step] of Object.entries(map)) {
      const r = captureStderr(() => M.stepOfLegacyStageArg(cli, v));
      assert.equal(r.value, step, `${cli} ${v}`);
      assert.match(r.stderr, /--stage is deprecated; use --step/, `${cli} ${v}`);
    }
    for (const v of ["constructor", "__proto__", "", undefined]) {
      assert.equal(captureStderr(() => M.stepOfLegacyStageArg(cli, v)).value, null, `${cli} ${String(v)}`);
    }
  }
  for (const [cli, v] of [["plan-link", "tests"], ["plan-artifact-path", "docs"], ["check-glossary-drift", "review_tests"],
    ["plan-link", "clarify_intent"], ["plan-link", "bogus"], ["unknown-cli", "intent"], ["constructor", "intent"]]) {
    assert.equal(captureStderr(() => M.stepOfLegacyStageArg(cli, v)).value, null, `${cli} ${v}`);
  }
});
caseEnd();

caseBegin("the compat module sits inside one temporary migration block", "hooks/lib/temporary-migrations/stage-to-step/index.js");
test("the module is wrapped in the stage -> step BEGIN / deletion-condition / END block", () => {
  const lines = fs.readFileSync(path.join(R.ROOT, COMPAT), "utf8").split(/\r?\n/);
  const begin = lines.findIndex((l) => /^\/\/ --- BEGIN temporary: workflow stage -> workflow step migration added \d{4}-\d{2}-\d{2} ---$/.test(l));
  assert.ok(begin >= 0, "BEGIN line");
  assert.match(lines[begin + 1] || "", /^\/\/ deletion-condition: \S/);
  const end = lines.findIndex((l) => /^\/\/ --- END temporary: workflow stage -> workflow step migration ---$/.test(l));
  assert.ok(end > begin, "END line after BEGIN");
  const code = (from, to) => lines.slice(from, to).filter((l) => l.trim() && !/^\s*(\/\/|"use strict";)/.test(l));
  assert.deepEqual(code(0, begin), [], "no code before BEGIN");
  assert.deepEqual(code(end + 1, lines.length), [], "no code after END");
});
caseEnd();

caseBegin("recordUndecidable asks the gate by step key", "hooks/stop-confirm-plan-guard.js");
test("recordUndecidable: every gateFor key is a step key, never the plan artifact name", () => {
  const { recordUndecidable } = req("hooks/stop-confirm-plan-guard.js");
  const s = R.sessionAt("intent", { tag: 7051 });
  const gateFor = spyGate("ON");
  const text = "Here is the plan.\n\n" + s.urlLine;
  const r = recordUndecidable({ sid: s.sid, input: { last_assistant_message: text }, tail: {}, markers: [{ suffix: "intent", absPath: s.plan }],
    deadline: Date.now() + 600000, active: false, probes: { gateFor, linkFor: () => ({ url: s.url }) } });
  assert.ok(stepKeyed(gateFor.seen), "gateFor keys: " + JSON.stringify(gateFor.seen));
  assert.ok(!gateFor.seen.includes("intent"), "the artifact name must not reach gateFor");
  assert.ok(Array.isArray(r.unrecorded) && Array.isArray(r.written));
});
caseEnd();

caseBegin("compat layer edge cases", "hooks/lib/temporary-migrations/stage-to-step/index.js");
test("a record / log line holding both stage and step is returned unchanged", () => {
  const M = req(COMPAT);
  const rec = { v: 1, stage: "tests", step: "outline", grants: [] };
  assert.equal(M.normalizeGlossaryRecord(rec), rec, "same object, stage kept");
  const line = { event: "write", stage: "intent", step: "outline", path: "/x", at: "t" };
  assert.equal(M.normalizeReceiptLogLine(line), line, "same object, stage kept");
  assert.deepEqual(line, { event: "write", stage: "intent", step: "outline", path: "/x", at: "t" });
});
test("normalizeReceiptLogLine: null / non-object pass through, an unknown stage is kept as the step value", () => {
  const M = req(COMPAT);
  for (const v of [null, undefined, "str", 5, true]) assert.equal(M.normalizeReceiptLogLine(v), v, String(v));
  const arr = [];
  assert.equal(M.normalizeReceiptLogLine(arr), arr);
  const noStage = { event: "write" };
  assert.equal(M.normalizeReceiptLogLine(noStage), noStage);
  assert.deepEqual(M.normalizeReceiptLogLine({ event: "write", stage: "zzz", path: "p" }), { event: "write", step: "zzz", path: "p" });
  // a glossary-only legacy value is not a plan artifact name, so a log line keeps it as it is
  assert.deepEqual(M.normalizeReceiptLogLine({ event: "write", stage: "tests" }), { event: "write", step: "tests" });
  assert.deepEqual(M.normalizeReceiptLogLine({ event: "write", stage: "constructor" }), { event: "write", step: "constructor" });
});
test("readReceiptLog skips corrupt lines and keeps the valid ones", () => {
  const PR = req("hooks/lib/presentation-receipt");
  const s = R.sessionAt("intent", { tag: 7052 });
  const ok1 = { event: "write", stage: "intent", path: "fixture-a.json", at: "t1" };
  const ok2 = { event: "consume", step: "detail", path: "fixture-d.json", at: "t2" };
  fs.mkdirSync(path.dirname(LOG(s.sid)), { recursive: true });
  fs.writeFileSync(LOG(s.sid), ["{broken json", JSON.stringify(ok1), "", "not json at all", "null", JSON.stringify(ok2), '{"event":"wri'].join("\n") + "\n");
  const lines = PR.readReceiptLog(s.sid);
  assert.deepEqual(lines, [{ event: "write", step: "clarify_intent", path: "fixture-a.json", at: "t1" }, ok2]);
});
test("stepOfLegacyStageArg writes nothing to stderr when it returns null", () => {
  const M = req(COMPAT);
  for (const [cli, v] of [["plan-link", "tests"], ["plan-link", "bogus"], ["plan-link", undefined], ["unknown-cli", "intent"],
    ["check-glossary-drift", "review_tests"], ["plan-artifact-path", "constructor"], [undefined, "intent"]]) {
    const r = captureStderr(() => M.stepOfLegacyStageArg(cli, v));
    assert.equal(r.value, null, `${cli} ${String(v)}`);
    assert.equal(r.stderr, "", `${cli} ${String(v)}: no deprecation warning`);
  }
});
caseEnd();
