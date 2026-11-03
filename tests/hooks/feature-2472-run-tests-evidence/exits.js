"use strict";
// Tests: hooks/workflow-state/record-step-verdict.js
// Tags: TL2, hooks, run-tests, workflow-state, exit-paths, scope:issue-specific
// #2472 T5 (ARP-EXBG): the refusal of a run_tests completion leaves every exit open. A skipped
// transition still writes the run_outcome=null tombstone; the docs-only RUN_TESTS_NOT_NEEDED
// skip and a WORKFLOW_OFF commit both still pass after a refusal.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const F = require("../../lib/run-tests-outcome-fixture");
const { check, eq, show, errText, seedPrefix, seed, status, note, runTests, mod } = F;

const verdict = () => mod("hooks/workflow-state/record-step-verdict.js");
const refuse = (sid) => verdict().recordStepVerdict(sid, "run_tests", "complete", { gate: "sentinel", provenance: "observed", origin: "mark-step", repoDir: F.tmp() });
const hasKey = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function skippedWritesTombstone() {
  const sid = "s-2472-tombstone";
  let res = null;
  let entry = {};
  try {
    seedPrefix(sid);
    seed(sid, [note("run_outcome", "fail"), status("run_tests", "pending")]);
    res = verdict().recordStepVerdict(sid, "run_tests", "skipped", { gate: "mark", provenance: "observed", origin: "next-step-mark", repoDir: F.tmp() });
    entry = runTests(sid);
  } catch (e) {
    res = { error: errText(e) };
  }
  check("T5: a skipped transition records skipped and clears run_outcome (tombstone null)", () => {
    if (res.error) return res.error;
    eq(res.ok, true, `ok (${res.message})`);
    eq(entry.status, "skipped", "status");
    if (hasKey(entry, "run_outcome") && entry.run_outcome !== null) return `run_outcome ${show(entry.run_outcome)}`;
    return undefined;
  });
}

function docsOnlyNotNeededAfterRefusal() {
  const sid = "s-2472-docs-only";
  const msgs = [];
  let first = null;
  let entry = {};
  try {
    seedPrefix(sid);
    first = refuse(sid);
    const repo = F.makeRepo("docs-only", {});
    F.writeFiles(repo, { "docs/guide.md": "# guide\n" });
    F.git(repo, ["add", "docs/guide.md"]);
    mod("hooks/workflow-mark/not-needed-handlers.js").handle({
      cmd: 'echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: docs only change here>>"', sessionId: sid, repoCwd: repo,
      pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(`FATAL ${m}`),
    });
    entry = runTests(sid);
  } catch (e) {
    first = first || { error: errText(e) };
    entry = { error: errText(e) };
  }
  check("T5 ARP-EXBG: precondition — the completion before the skip is refused", () => {
    if (first.error) return first.error;
    eq([first.ok, first.kind], [false, "no-run-evidence"], "ok, kind");
    return undefined;
  });
  check("T5 ARP-EXBG: docs-only RUN_TESTS_NOT_NEEDED after a refusal records run_tests skipped", () => {
    if (entry.error) return entry.error;
    eq(entry.status, "skipped", `status (messages: ${show(msgs)})`);
    if (hasKey(entry, "run_outcome") && entry.run_outcome !== null) return `run_outcome ${show(entry.run_outcome)}`;
    return undefined;
  });
}

// One PreToolUse call of the real workflow-gate over `git commit` in a fixture repo.
function gateCommit(sid, repo) {
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command: "git commit -m x", cwd: repo } };
  const r = spawnSync(process.execPath, [path.join(F.ROOT, "hooks", "workflow-gate.js")], {
    input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env: process.env, cwd: repo,
  });
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "", error: r.error ? r.error.message : null };
}
const blocked = (r) => /"decision"\s*:\s*"block"/.test(r.stdout);

function workflowOffCommitAfterRefusal() {
  const sid = "s-2472-wf-off";
  let first = null;
  let control = null;
  let off = null;
  try {
    seedPrefix(sid);
    first = refuse(sid);
    const repo = F.makeRepo("wf-off", {});
    F.writeFiles(repo, { "src.txt": "x\n" });
    F.git(repo, ["add", "src.txt"]);
    control = gateCommit(sid, repo);
    fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.workflow-off`), "reason: fixture\n");
    off = gateCommit(sid, repo);
  } catch (e) {
    first = first || { error: errText(e) };
    off = off || { error: errText(e) };
  }
  check("T5 ARP-EXBG: control — without WORKFLOW_OFF the commit is blocked while run_tests is not complete", () => {
    if (!control) return (off && off.error) || "gate did not run";
    if (control.error) return control.error;
    if (!blocked(control)) return `not blocked: ${control.stdout.slice(0, 300)}`;
    return undefined;
  });
  check("T5 ARP-EXBG: after a refused completion, WORKFLOW_OFF still lets the commit through", () => {
    if (first.error) return first.error;
    if (off.error) return off.error;
    if (blocked(off)) return `blocked: ${off.stdout.slice(0, 300)}`;
    return undefined;
  });
}

// A pending run_tests whose only obstacle is UNRUNNABLE (FAIL=0), recorded by the real writer.
function seedUnrunnablePending(sid) {
  const { parseContractLine } = mod("hooks/lib/run-contract.js");
  mod("hooks/workflow-run-tests/record-run.js").recordRun({
    sessionId: sid, exitCode: 77, triggerCommand: "bash tests/run-all.sh", failingTests: null, hitSummary: [],
    unrunnableRuntimes: "pwsh", reason: "contract-unrunnable",
    outcomeInput: { attributed: true, contract: parseContractLine("RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=1 TIMEOUT=0") },
  });
}

function unrunnableAcceptedAfterRefusal() {
  const sid = "s-2472-unrunnable-accept";
  const msgs = [];
  const seen = {};
  try {
    seedPrefix(sid);
    seedUnrunnablePending(sid);
    seen.pre = runTests(sid);
    seen.first = refuse(sid);
    mod("hooks/workflow-mark/run-tests-accept-handler.js").handle({
      cmd: 'echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: pwsh is not installed on this host>>"', sessionId: sid, repoCwd: F.tmp(),
      pushMessage: (m) => msgs.push(m), signalFatal: (m) => msgs.push(`FATAL ${m}`),
    });
    seen.accepted = runTests(sid);
    seen.beforeLater = F.eventCount(sid);
    seen.cli = F.advance(sid, "run_tests", "--complete");
    seen.advance = verdict().recordStepVerdict(sid, "run_tests", "complete", { gate: "advance", provenance: "declared", origin: "next-step-advance", repoDir: F.tmp() });
    const markMsgs = [];
    mod("hooks/workflow-mark/mark-step-handler.js").handle({
      cmd: 'echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"', sessionId: sid, repoCwd: F.tmp(),
      pushMessage: (m) => markMsgs.push(m), signalFatal: (m) => markMsgs.push(`FATAL ${m}`),
    });
    seen.markMsgs = markMsgs;
    seen.mark = verdict().recordStepVerdict(sid, "run_tests", "complete", gateOptsMark());
    seen.afterLater = F.eventCount(sid);
    seen.final = runTests(sid);
  } catch (e) {
    seen.error = errText(e);
  }
  check("T5 ARP-EXBG: precondition — run_tests is pending on unrunnable and the completion is refused", () => {
    if (!seen.first) return seen.error || "flow stopped early";
    eq([seen.pre.status, seen.pre.run_outcome], ["pending", "unrunnable"], "seeded status, run_outcome");
    eq([seen.first.ok, seen.first.kind], [false, "no-run-evidence"], "ok, kind");
    return undefined;
  });
  check("T5 ARP-EXBG: RUN_TESTS_UNRUNNABLE_ACCEPTED after a refusal records run_tests complete", () => {
    if (!seen.accepted) return seen.error || "accept handler did not run";
    eq(seen.accepted.status, "complete", `status (messages: ${show(msgs)})`);
    eq(seen.accepted.run_outcome, "unrunnable", "run_outcome");
    return undefined;
  });
  check("T5 ARP-EXBG: after the accept, advance answers already (CLI exit 0) and writes nothing", () => {
    if (!seen.advance) return seen.error || "advance did not run";
    eq(seen.cli.status, 0, `next-step --advance exit (stdout: ${seen.cli.stdout.slice(0, 200)})`);
    eq([seen.advance.ok, seen.advance.already], [true, true], "ok, already");
    return undefined;
  });
  check("T5 ARP-EXBG: after the accept, MARK_STEP run_tests answers already and status stays complete", () => {
    if (!seen.mark) return seen.error || "MARK_STEP did not run";
    eq([seen.mark.ok, seen.mark.already], [true, true], "mark gate: ok, already");
    const m = seen.markMsgs.join("\n");
    if (/no-run-evidence|ingest-pending|failed to write state|FATAL/.test(m)) return `MARK_STEP refused: ${m}`;
    eq(seen.afterLater, seen.beforeLater, "event count across advance and MARK_STEP");
    eq(seen.final.status, "complete", "final status");
    return undefined;
  });
}
const gateOptsMark = () => ({ gate: "mark", provenance: "observed", origin: "next-step-mark", repoDir: F.tmp() });

module.exports = { skippedWritesTombstone, docsOnlyNotNeededAfterRefusal, workflowOffCommitAfterRefusal, unrunnableAcceptedAfterRefusal };
