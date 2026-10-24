#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/run-contract.js, hooks/lib/worker-outcome-contract.js, bin/worker-dispatch/emit.js, bin/workflow/lib/run-tests-baseline-evidence.js, hooks/workflow-mark/run-tests-baseline-accept-handler.js, hooks/workflow-run-tests/outcome.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests/demotion.js
// Tags: TL2, hooks, run-tests, run-contract, hit-attribution, baseline, demotion, system-message-contract, conv-lang, scope:issue-specific
// #2669: the optional HITS field of RUN_CONTRACT (old 4- and 6-field lines still read as hits=0),
// its outcome-file and YAML carriers, and every judge that must treat a run with HITS>0 as failing:
// the run outcome, green, the UNRUNNABLE-only reading, the baseline grant and the evidence CLI.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TRANSCRIPTS = fs.mkdtempSync(path.join(os.tmpdir(), "f2669-transcripts-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
process.on("exit", () => {
  restore();
  fs.rmSync(TRANSCRIPTS, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
let passed = 0;
let failed = 0;

// check(name, fn) — fn returns nothing on success and throws (or returns a message) on failure.
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const mod = (rel) => require(path.join(ROOT, rel));

const LEGACY = "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1";
const CURRENT = "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0";
const WITH_HITS = "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=2";

caseBegin("run-contract-reads-and-writes-hits", "hooks/lib/run-contract.js");
{
  const rc = () => mod("hooks/lib/run-contract.js");
  check("T6: a 4-field line reads as legacy with hits=0", () => {
    const c = rc().parseContractLine(LEGACY);
    eq(c && c.shape, "legacy", "shape");
    eq(c && c.hits, 0, "hits");
  });
  check("T6: a 6-field line reads as current with hits=0", () => {
    const c = rc().parseContractLine(CURRENT);
    eq(c && c.shape, "current", "shape");
    eq(c && c.hits, 0, "hits");
  });
  check("T6: a 7-field line reads its HITS", () => {
    const c = rc().parseContractLine(WITH_HITS);
    eq(c && [c.shape, c.fail, c.executed, c.hits], ["current", 1, 1, 2], "shape/fail/executed/hits");
  });
  check("T6: a 7-field line round-trips through formatContract", () => {
    eq(rc().formatContract(rc().parseContractLine(WITH_HITS)), WITH_HITS, "line");
  });
  check("T6: a 6-field line round-trips without a HITS field", () => {
    eq(rc().formatContract(rc().parseContractLine(CURRENT)), CURRENT, "line");
  });
  check("T6: HITS=0 is never written", () => {
    const line = rc().formatContract({ shape: "current", pass: 1, fail: 0, skip: 0, executed: 1, unrunnable: 0, timeout: 0, hits: 0 });
    eq(line, CURRENT, "line");
  });
  check("T6: HITS=x is invalid", () => eq(rc().parseContractLine(CURRENT + " HITS=x"), null, "parse"));
  check("T6: an empty HITS= is invalid", () => eq(rc().parseContractLine(CURRENT + " HITS="), null, "parse"));
  check("T6: HITS after a legacy 4-field head is invalid", () => eq(rc().parseContractLine(LEGACY + " HITS=1"), null, "parse"));
  check("T6: findSingleContract carries hits from the one contract line", () => {
    const c = rc().findSingleContract(["PASS: a", "HIT: worktree-change x", WITH_HITS]);
    eq(c && c.hits, 2, "hits");
  });
}
caseEnd();

// HITS=0 is the absent field spelled out; malformed values follow the parser's existing rule for
// every count (digits only, a safe integer, the line exactly once well-formed) and read as null.
caseBegin("run-contract-hits-edge-values", "hooks/lib/run-contract.js");
{
  const rc = () => mod("hooks/lib/run-contract.js");
  check("T6: an explicit HITS=0 reads the same as no HITS field", () => {
    eq(rc().parseContractLine(CURRENT + " HITS=0"), rc().parseContractLine(CURRENT), "parsed contract");
    eq(rc().parseContractLine(CURRENT + " HITS=0") !== null, true, "parses at all");
  });
  check("T6: an explicit HITS=0 is formatted back without the field", () => {
    eq(rc().formatContract(rc().parseContractLine(CURRENT + " HITS=0")), CURRENT, "line");
  });
  check("T6: the largest safe integer is read as hits", () => {
    const c = rc().parseContractLine(CURRENT + ` HITS=${Number.MAX_SAFE_INTEGER}`);
    eq(c && c.hits, Number.MAX_SAFE_INTEGER, "hits");
  });
  for (const [label, line] of [
    ["a negative HITS", CURRENT + " HITS=-1"], ["a non-numeric HITS", CURRENT + " HITS=abc"],
    ["a fractional HITS", CURRENT + " HITS=1.5"], ["a HITS past the safe-integer range", CURRENT + " HITS=99999999999999999999"],
    ["two HITS fields", CURRENT + " HITS=1 HITS=2"],
    ["HITS before UNRUNNABLE", "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 HITS=1 UNRUNNABLE=0 TIMEOUT=0"],
  ]) {
    check(`T6: ${label} is invalid`, () => eq(rc().parseContractLine(line), null, `parse ${show(line)}`));
  }
  check("T6: control — findSingleContract calls a line with two HITS fields invalid", () => {
    eq(rc().findSingleContract(["PASS: a", CURRENT + " HITS=1 HITS=2"]), { reason: "invalid" }, "result");
  });
}
caseEnd();

const SHA = "a".repeat(64);
function outcome(wr) {
  return {
    schema_version: 1, worker: "test-runner", stem: "worker-test-runner", session_id: "s-2669",
    payload_sha256: SHA, cwd: "", status: "fail", exit_code: 1, duration_ms: 10,
    worker_result: Object.assign({
      run_contract: { pass: 0, fail: 1, skip: 0, executed: 1, unrunnable: 0, timeout: 0 },
      failing_tests: ["tests/a.sh"], log_tail: ["FAIL: tests/a.sh"], summary: "fail",
    }, wr),
  };
}
const CURRENT_RC = { pass: 0, fail: 1, skip: 0, executed: 1, unrunnable: 0, timeout: 0 };

caseBegin("worker-outcome-validates-hits", "hooks/lib/worker-outcome-contract.js");
{
  const v = (wr) => mod("hooks/lib/worker-outcome-contract.js").validateOutcome(outcome(wr));
  check("T6: run_contract.hits as a non-negative integer is valid and kept", () => {
    const r = v({ run_contract: Object.assign({}, CURRENT_RC, { hits: 2 }) });
    eq(r.ok, true, `ok (${r.reason})`);
    eq(r.outcome.worker_result.run_contract.hits, 2, "kept hits");
  });
  for (const [label, bad] of [["negative", -1], ["fractional", 1.5], ["a string", "2"]]) {
    check(`T6: run_contract.hits as ${label} is rejected`, () => {
      eq(v({ run_contract: Object.assign({}, CURRENT_RC, { hits: bad }) }).ok, false, "ok");
    });
  }
  check("T6: run_contract.hits on a legacy contract is rejected", () => {
    eq(v({ run_contract: { pass: 0, fail: 1, skip: 0, executed: 1, hits: 1 } }).ok, false, "ok");
  });
  check("T6: a run_contract without hits stays valid and gains no hits key", () => {
    const r = v({});
    eq(r.ok, true, `ok (${r.reason})`);
    eq("hits" in r.outcome.worker_result.run_contract, false, "hits key present");
  });
  check("T6: worker_result.hits as a list of strings is valid and kept", () => {
    const r = v({ hits: ["command-guard (no test id) gh", "worktree-change t tree=x kind=tracked paths=a"] });
    eq(r.ok, true, `ok (${r.reason})`);
    eq(r.outcome.worker_result.hits, ["command-guard (no test id) gh", "worktree-change t tree=x kind=tracked paths=a"], "kept hits");
  });
  check("T6: worker_result.hits holding a number is rejected", () => eq(v({ hits: [1] }).ok, false, "ok"));
  check("T6: worker_result.hits as a string is rejected", () => eq(v({ hits: "x" }).ok, false, "ok"));
}
caseEnd();

caseBegin("emit-renders-and-restores-hits", "bin/worker-dispatch/emit.js");
{
  const emit = () => mod("bin/worker-dispatch/emit.js");
  const HITS = ["command-guard (no test id) gh --version", "worktree-change tests/a.sh tree=/x kind=tracked paths=a.txt"];
  const result = (over) => Object.assign({
    status: "fail", exitCode: 1, durationSeconds: 2, summary: "1 failed",
    failingTests: ["tests/a.sh"], logTail: ["FAIL: tests/a.sh"],
    runContract: Object.assign({}, CURRENT_RC, { hits: 2 }), hits: HITS,
  }, over);
  check("T6: the YAML's first line is the contract with HITS=2", () => {
    eq(emit().renderTestRunnerYaml(result({})).split("\n")[0], "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=2", "line 1");
  });
  check("T6: the YAML lists hits after failing_tests and before log_tail", () => {
    const lines = emit().renderTestRunnerYaml(result({})).split("\n");
    const at = lines.indexOf("hits:");
    const ft = lines.findIndex((l) => l.startsWith("failing_tests"));
    const lt = lines.indexOf("log_tail: |");
    if (at < 0) return `no hits: line in ${show(lines)}`;
    if (!(ft < at && at < lt)) return `order failing_tests=${ft} hits=${at} log_tail=${lt}`;
    const items = lines.slice(at + 1, lt);
    eq(items.length, 2, "item count");
    if (!items[0].startsWith("  - ") || !items[0].includes(HITS[0])) return `item 1: ${items[0]}`;
    if (!items[1].includes(HITS[1])) return `item 2: ${items[1]}`;
    return undefined;
  });
  check("T6: an empty hits list writes no hits: line", () => {
    const lines = emit().renderTestRunnerYaml(result({ hits: [], runContract: CURRENT_RC })).split("\n");
    eq(lines.includes("hits:"), false, "hits: line");
    if (lines[0].includes("HITS=")) return `contract carries HITS: ${lines[0]}`;
    return undefined;
  });
  check("T6: outcomeFields keeps run_contract.hits and the hits list", () => {
    const f = emit().outcomeFields({ renderer: "test-runner-yaml" }, result({}));
    eq(f.worker_result.run_contract && f.worker_result.run_contract.hits, 2, "run_contract.hits");
    eq(f.worker_result.hits, HITS, "worker_result.hits");
  });
  check("T6: outcomeFields writes no hits key for a contract without hits", () => {
    const f = emit().outcomeFields({ renderer: "test-runner-yaml" }, result({ hits: [], runContract: CURRENT_RC }));
    eq("hits" in (f.worker_result.run_contract || {}), false, "run_contract hits key");
  });
  check("T6: an outcome record re-renders to the same YAML (reverse)", () => {
    const e = emit();
    const original = e.renderTestRunnerYaml(result({}));
    const back = e.resultFromOutcome(e.outcomeFields({ renderer: "test-runner-yaml" }, result({})));
    eq(back.hits, HITS, "restored hits");
    eq(e.renderTestRunnerYaml(back), original, "re-render");
  });
}
caseEnd();

// A pending failing entry as the hook records it; `over` replaces fields.
const entry = (over) => Object.assign({
  status: "pending", run_outcome: "fail", failing_tests: null, unrunnable_count: 0, updated_seq: 3,
}, over);
const evidence = () => mod("bin/workflow/lib/run-tests-baseline-evidence.js");
const undeterminedCls = { base: "abc", entries: [{ path: "tests/a.sh", class: "undetermined", detail: "x" }] };

caseBegin("evidence-refuses-a-run-with-hits", "bin/workflow/lib/run-tests-baseline-evidence.js");
{
  check("T7: EXIT.HITS is 7", () => eq(evidence().EXIT.HITS, 7, "EXIT.HITS"));
  check("T7: control — a listless run without hits grants failing-list-unrecorded", () => {
    eq(evidence().grantKind(entry({})), "failing-list-unrecorded", "kind");
  });
  check("T7: the listless grant is blocked when hit_count>0", () => {
    eq(evidence().grantKind(entry({ hit_count: 1 })), null, "kind");
  });
  check("T7: control — an undetermined classification grants without hits", () => {
    eq(evidence().grantKind(entry({ failing_tests: ["tests/a.sh"], baseline_classification: undeterminedCls })), "undetermined", "kind");
  });
  check("T7: the undetermined grant is blocked when hit_count>0", () => {
    const e = entry({ failing_tests: ["tests/a.sh"], baseline_classification: undeterminedCls, hit_count: 2 });
    eq(evidence().grantKind(e), null, "kind");
  });
  for (const [label, value, want] of [["3", 3, 3], ["0", 0, 0], ["the string 3", "3", 0], ["1.5", 1.5, 0], ["-1", -1, 0], ["absent", undefined, 0], ["null", null, 0]]) {
    check(`T7: hitCount reads ${label} as ${want}`, () => {
      if (typeof evidence().hitCount !== "function") return "hitCount is not exported";
      eq(evidence().hitCount(entry({ hit_count: value })), want, "hitCount");
      return undefined;
    });
  }
}
caseEnd();

caseBegin("accept-handler-names-the-hits", "hooks/workflow-mark/run-tests-baseline-accept-handler.js");
{
  const rejection = (e) => mod("hooks/workflow-mark/run-tests-baseline-accept-handler.js").rejection(e);
  check("T7: control — a listless run without hits is grantable", () => eq(rejection(entry({})), null, "rejection"));
  check("T7: a run with hit_count=1 is refused with the hits reason", () => {
    eq(rejection(entry({ hit_count: 1 })), "1 unattributed hit(s) — a run with HITS>0 cannot be accepted", "rejection");
  });
  check("T7: a run with hit_count=3 and a classification is refused with the hits reason", () => {
    const e = entry({ hit_count: 3, failing_tests: ["tests/a.sh"], baseline_classification: undeterminedCls });
    eq(rejection(e), "3 unattributed hit(s) — a run with HITS>0 cannot be accepted", "rejection");
  });
}
caseEnd();

const contract = (over) => Object.assign({ shape: "current", pass: 1, fail: 0, skip: 0, executed: 1, unrunnable: 0, timeout: 0 }, over);

caseBegin("outcome-fails-a-run-with-hits", "hooks/workflow-run-tests/outcome.js");
{
  const resolve = (i) => mod("hooks/workflow-run-tests/outcome.js").resolveRunOutcome(Object.assign({ attributed: true }, i));
  check("T9: a passing contract with hits=1 resolves to fail", () => eq(resolve({ contract: contract({ hits: 1 }) }), "fail", "outcome"));
  check("T9: hits>0 wins over unrunnable>0", () => {
    eq(resolve({ contract: contract({ unrunnable: 2, hits: 1 }) }), "fail", "outcome");
  });
  check("T9: hits>0 wins when nothing ran and every test was unrunnable", () => {
    eq(resolve({ contract: contract({ pass: 0, executed: 0, unrunnable: 2, hits: 1 }) }), "fail", "outcome");
  });
  check("T9: control — hits=0 still resolves to pass", () => eq(resolve({ contract: contract({ hits: 0 }) }), "pass", "outcome"));
  check("T9: control — no hits field still resolves to pass", () => eq(resolve({ contract: contract({}) }), "pass", "outcome"));
  check("T9: control — unrunnable without hits still resolves to unrunnable", () => {
    eq(resolve({ contract: contract({ unrunnable: 2 }) }), "unrunnable", "outcome");
  });
  check("T9: control — an ambiguous contract with hits is still no observation", () => {
    eq(resolve({ ambiguous: true, contract: contract({ hits: 1 }) }), null, "outcome");
  });
}
caseEnd();

caseBegin("demotion-is-not-unrunnable-only-with-hits", "hooks/workflow-run-tests/demotion.js");
{
  const only = (c) => mod("hooks/workflow-run-tests/demotion.js").isUnrunnableOnly(c, false, null);
  check("T9: an unrunnable run with hits=1 is not UNRUNNABLE-only", () => eq(only(contract({ pass: 0, executed: 0, unrunnable: 2, hits: 1 })), false, "isUnrunnableOnly"));
  check("T9: control — an unrunnable run without hits is UNRUNNABLE-only", () => eq(only(contract({ pass: 0, executed: 0, unrunnable: 2 })), true, "isUnrunnableOnly"));
}
caseEnd();

// seedPrefix(sid) — every step before run_tests complete, so a green run may complete run_tests.
function seedPrefix(sid) {
  const wf = mod("hooks/workflow-state");
  const approval = mod("hooks/workflow-state/completion-approval.js");
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "review_tests", "write_code"]) {
    if (approval.isApprovalGatedStep(s)) mod("tests/lib/plan-approval-fixture.js").approveLive(sid, s);
    wf.markStep(sid, s, "complete");
  }
}
const runTests = (sid) => {
  const s = mod("hooks/workflow-state").readState(sid);
  return (s && s.steps && s.steps.run_tests) || {};
};
const SUMMARY = ["command-guard (no test id) gh --version", "worktree-change tests/a.sh tree=/x kind=tracked paths=a.txt"];
function record(sid, exitCode, c, hitSummary) {
  seedPrefix(sid);
  mod("hooks/workflow-run-tests/record-run.js").recordRun({
    sessionId: sid, exitCode, triggerCommand: "bash tests/run-all.sh", failingTests: null,
    outcomeInput: { attributed: true, contract: c }, hitSummary,
  });
  return runTests(sid);
}

caseBegin("record-run-holds-a-green-run-with-hits", "hooks/workflow-run-tests/record-run.js");
{
  check("T9: control — an exit-0 green run without hits completes run_tests", () => {
    const e = record("f2669-green", 0, contract({}), []);
    eq([e.status, e.run_outcome], ["complete", "pass"], "status/run_outcome");
  });
  check("T9: an exit-0 run whose contract has hits=1 is not green and stays pending as fail", () => {
    const e = record("f2669-green-hits", 0, contract({ hits: 1 }), SUMMARY.slice(0, 1));
    eq([e.status, e.run_outcome], ["pending", "fail"], "status/run_outcome");
  });
  check("T9: an unrunnable run with hits is recorded as fail, not unrunnable", () => {
    const e = record("f2669-unrunnable-hits", 1, contract({ pass: 0, executed: 0, unrunnable: 2, hits: 1 }), SUMMARY.slice(0, 1));
    eq(e.run_outcome, "fail", "run_outcome");
  });
  check("T10: a failing exit records hit_count and hit_summary", () => {
    const e = record("f2669-failed-hits", 1, contract({ pass: 1, executed: 1, hits: 2 }), SUMMARY);
    eq([e.hit_count, e.hit_summary], [2, SUMMARY], "hit_count/hit_summary");
  });
}
caseEnd();

caseBegin("evidence-failing-reports-the-hits", "bin/workflow/lib/run-tests-baseline-evidence.js");
{
  check("T7: failing() on a recorded run with hits exits HITS and prints HIT_COUNT then the summary", () => {
    try { record("f2669-evidence-hits", 1, contract({ pass: 1, executed: 1, hits: 2 }), SUMMARY); } catch (e) { return `seed: ${e.message}`; }
    const r = evidence().failing("f2669-evidence-hits");
    eq(r.code, 7, `code (stderr=${r.stderr})`);
    const lines = String(r.stdout || "").split("\n").filter((l) => l !== "");
    eq(lines[0], "HIT_COUNT=2", "first stdout line");
    for (const s of SUMMARY) if (!lines.slice(1).some((l) => l.includes(s))) return `no line with ${s} in ${show(lines)}`;
    return undefined;
  });
  check("T7: control — failing() on a listless run without hits is a state error", () => {
    record("f2669-evidence-nohits", 1, contract({ pass: 0, fail: 1, executed: 1 }), []);
    eq(evidence().failing("f2669-evidence-nohits").code, evidence().EXIT.STATE, "code");
  });
  check("T7: the recorded entry with hits grants nothing", () => {
    eq(evidence().grantKind(runTests("f2669-evidence-hits")), null, "kind");
  });
}
caseEnd();

// #2731 S3-5: demotionMessage splits into { head, detail }; done() shows only the fact line
// [run_tests] pending (<reason>) and sends the detail to additionalContext via withConvLang.
const SMC = require("../lib/system-message-contract");
caseBegin("demotion-message-head-detail", "hooks/workflow-run-tests/demotion.js");
{
  const D = mod("hooks/workflow-run-tests/demotion.js");
  const SHAPES = [
    ["contract-unrunnable", { unrunnable: 3 }, (d) => d.includes(D.UNRUNNABLE_ACCEPT_SENTINEL_FORM) && d.includes("3")],
    ["contract-legacy-shape", null, (d) => /legacy/i.test(d) && /rebase/i.test(d)],
    ["contract-absent", null, (d) => d.includes("RUN_CONTRACT")],
  ];
  for (const [reason, c, detailOk] of SHAPES) {
    check(`D1: demotionMessage(${reason}) returns { head, detail }`, () => {
      const m = D.demotionMessage(reason, c);
      if (!m || typeof m !== "object") return `an object, got ${show(m)}`;
      eq([typeof m.head, typeof m.detail], ["string", "string"], "head/detail types");
      if (!m.head.includes(reason)) return `head does not name the reason: ${m.head}`;
      return detailOk(m.detail) ? undefined : `detail lacks the explanation: ${m.detail}`;
    });
  }
}
caseEnd();

caseBegin("run-tests-done-fact-line", "hooks/workflow-run-tests/record-run.js");
{
  const { spawnSync } = require("child_process");
  const REPO = path.resolve(ROOT).replace(/\\/g, "/");
  const wf = mod("hooks/workflow-state");
  const drive = (sid, lang) => {
    wf.markStep(sid, "write_tests", "complete");
    const input = { session_id: sid, tool_name: "Bash", tool_input: { command: `bash ${REPO}/tests/run-all.sh`, cwd: REPO },
      tool_response: { exit_code: 0, stdout: "no contract here" } };
    const r = spawnSync(process.execPath, [path.join(ROOT, "hooks", "workflow-run-tests.js")],
      { input: JSON.stringify(input), env: { ...process.env, CONV_LANG: lang }, encoding: "utf8", timeout: 60000 });
    if (r.status !== 0) throw new Error(`hook exit ${r.status}: ${r.stderr}`);
    eq(wf.readState(sid).steps.run_tests.status, "pending", "fixture: the run is demoted");
    const j = JSON.parse(String(r.stdout).trim() || "{}");
    return { msg: j.systemMessage || "", ctx: (j.hookSpecificOutput || {}).additionalContext || "" };
  };
  check("D2: japanese — systemMessage is exactly [run_tests] pending (contract-absent); detail prefixed once", () => {
    const r = drive("f2731-demote-ja", "japanese");
    eq(r.msg, "[run_tests] pending (contract-absent)", "systemMessage");
    SMC.assertSystemMessageContract(r.msg);
    if (!SMC.prefixedOnce(r.ctx, "japanese")) return `additionalContext not prefixed once: ${show(r.ctx)}`;
    return r.ctx.includes("RUN_CONTRACT") ? undefined : "the explanation is not in additionalContext";
  });
  check("D3: english — additionalContext carries the detail without the directive", () => {
    const r = drive("f2731-demote-en", "english");
    eq(r.msg, "[run_tests] pending (contract-absent)", "systemMessage");
    if (!r.ctx.includes("RUN_CONTRACT")) return `the explanation is not in additionalContext: ${show(r.ctx)}`;
    eq(SMC.countDirective(r.ctx), 0, "directive count");
    return undefined;
  });
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
process.exitCode = failed === 0 ? 0 : 1;
