"use strict";
// Tests: hooks/workflow-state/cycle-state.js, hooks/lib/wf-init-begun-mark.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/resolve-worktree-path.js, hooks/stop-final-report-guard.js
// Tags: feature-2875, cycle-boundary, reinit, workflow-init, control-dir, final-report, worktree, leftover, scope:issue-specific, TL2, pwsh-not-required
// #2875 root cause 1: a session that merged, closed, and ran /workflow-init again kept the closed
// cycle's control files, worktree cwd, and write-once fields. The regression cases replay that run
// on a real main repo whose linked worktree became a WE-11 leftover (pruned, admin dir reused).
// The cycle boundary is closed at the init entry (markWorkflowInitBegun) and, as a backstop, when a
// declaring gate completes workflow_init. (3b)/(3c) call recordStepVerdict in-process with the gate
// the next-step --advance CLI and the MARK sentinel pass; (4)/(5) spawn next-step and the Stop guard.
// TL3 gap: a real CWD lock on Windows is what makes WE-11 fail; the fixture reproduces its result.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");

const restoreIsolation = isolate();
const SB = F.makeBase("f2875c-");
const TRANSCRIPTS = path.join(SB, "transcripts");
fs.mkdirSync(TRANSCRIPTS);
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const CYCLE = "hooks/workflow-state/cycle-state.js";
const CONTROL = ["final-report-env.json", "session-close-gate.json", "issue-close-outcome.json",
  "finalize-state-1.json", "finalize-binding-1.json"];
const io = () => F.io();
const controlDir = (sid) => require(F.rel("hooks/workflow-state/state-io/control-dir.js")).sessionControlDir(sid, { forWrite: true });
const boundaries = (sid) => (io().readRawState(sid).events || []).filter((e) => e.kind === "cycle_boundary");
const statusOf = (sid, step) => (io().readState(sid).steps[step] || {}).status;
const { markWorkflowInitBegun } = require(F.rel("hooks/lib/wf-init-begun-mark.js"));
const { recordStepVerdict } = require(F.rel("hooks/workflow-state/record-step-verdict.js"));

// A closed cycle: every step settled (merge_to_main and final_report complete), the delivery
// profile and write-once fields pinned, the close procedure's control files present, and the
// session's worktree left behind by a failed WE-11 with its admin dir reused by a later worktree.
function closedCycle(sid, { finished = true } = {}) {
  const base = path.join(SB, sid);
  const main = F.makeRepo(path.join(base, "main"));
  fs.mkdirSync(path.join(base, "other"));
  const wt = F.makeLeftover(main, path.join(base, "wts", "work"), `feature/${sid}`,
    { reuseAt: path.join(base, "other", "work") }).leftover;
  F.seedState(sid, main);
  F.enterWorktree(sid, wt);
  io().recordSessionWorktree(sid, wt);
  return { main, wt, dir: finishCycle(sid, finished) };
}

// Gated steps refuse "complete" without their records, so they go in_progress; other failures throw.
const GATED_COMPLETION_ERRORS = ["UnapprovedCompletionError", "GlossaryCheckIncompleteError"];
const TERMINAL = ["merge_to_main", "final_report"], DECLARED = { provenance: "declared", origin: "fixture" };

// Settle the cycle's steps, pin its write-once fields, and write the close procedure's control files.
function finishCycle(sid, finished = true) {
  for (const step of io().VALID_STEPS) {
    if (!finished && TERMINAL.includes(step)) continue;
    try { io().markStep(sid, step, "complete", {}, DECLARED); } catch (e) {
      if (!GATED_COMPLETION_ERRORS.includes(e && e.name)) throw e;
      io().markStep(sid, step, "in_progress", {}, DECLARED);
    }
  }
  for (const step of io().VALID_STEPS) {
    const open = !finished && TERMINAL.includes(step);
    assert.strictEqual(statusOf(sid, step) === "pending", open, `fixture: ${step} pending must be ${open}`);
  }
  io().setDeliveryProfile(sid, { deliveryPath: "pull_request", autoMergePr: "off", source: "default", origin: "fixture" });
  io().updateTopLevel(sid, (r) => { r.merge_base_baseline = { sha: "0".repeat(40), ref: "main" }; });
  io().setLastPushedSha(sid, "1".repeat(40));
  const dir = controlDir(sid);
  for (const name of CONTROL) {
    const body = name === "session-close-gate.json" ? { gate_action: "proceed" } : { session_id: sid };
    fs.writeFileSync(path.join(dir, name), JSON.stringify(body));
  }
  return dir;
}

// The boundary moved every control file into cycle-archive/1 and pointed the session home.
function assertCycleClosed(sid, fx) {
  for (const name of CONTROL) {
    assert.ok(!fs.existsSync(path.join(fx.dir, name)), `${name} must leave the live control dir`);
    assert.ok(fs.existsSync(path.join(fx.dir, "cycle-archive", "1", name)), `${name} must be archived under cycle-archive/1`);
  }
  const state = io().readState(sid);
  assert.ok(F.samePath(state.cwd, fx.main), `state.cwd must return to the start cwd, got ${state.cwd}`);
  assert.strictEqual(state.session_worktree, null);
  assert.strictEqual(state.worktree_entered_at, null);
  assert.strictEqual(boundaries(sid).length, 1);
}

caseBegin("previous-cycle-closed-after-merge", "hooks/workflow-state/cycle-state.js");
test("previous-cycle-closed-after-merge", () => {
  const isClosed = F.need(CYCLE, "isPreviousCycleClosed");
  closedCycle("cyc-closed");
  closedCycle("cyc-open", { finished: false });
  assert.strictEqual(isClosed(io().readState("cyc-closed")), true);
  assert.strictEqual(isClosed(io().readState("cyc-open")), false);
});
caseEnd();

caseBegin("previous-cycle-closed-by-either-terminal-step", "hooks/workflow-state/cycle-state.js");
test("previous-cycle-closed-by-either-terminal-step", () => {
  const isClosed = F.need(CYCLE, "isPreviousCycleClosed");
  for (const step of TERMINAL) {
    const sid = `cyc-only-${step}`;
    F.seedState(sid, path.join(SB, sid));
    io().markStep(sid, step, "complete", {}, DECLARED);
    assert.strictEqual(statusOf(sid, TERMINAL.find((s) => s !== step)), "pending", "fixture: the other terminal step stays pending");
    assert.strictEqual(isClosed(io().readState(sid)), true, `${step} alone must close the cycle`);
    io().appendEvents(sid, [Object.assign({ kind: "cycle_boundary", closed_cycle: 1, reason: "reinit-entry" }, DECLARED)]);
    assert.strictEqual(isClosed(io().readState(sid)), false, `a ${step} before the last boundary must not count`);
  }
});
caseEnd();

caseBegin("fixture-reproduces-we11-leftover","hooks/workflow-state/resolve-worktree-path.js");
test("fixture-reproduces-we11-leftover", () => {
  const fx = closedCycle("cyc-fixture");
  assert.ok(fs.statSync(path.join(fx.wt, ".git")).isFile(), "the leftover keeps its gitlink");
  assert.ok(fs.existsSync(F.gitlinkTarget(fx.wt)), "its admin dir is reused by another worktree");
  const list = F.git(["-C", fx.main, "worktree", "list", "--porcelain"], fx.main);
  assert.ok(!list.replace(/\\/g, "/").includes(fx.wt.replace(/\\/g, "/")), "git no longer lists the leftover");
});
caseEnd();

caseBegin("reset-from-path-entry-closes-cycle", "hooks/lib/wf-init-begun-mark.js");
test("reset-from-path-entry-closes-cycle", () => {
  const fx = closedCycle("cyc-3a");
  io().markStep("cyc-3a", "workflow_init", "pending", {}, { provenance: "declared", origin: "reset-from" });
  markWorkflowInitBegun("cyc-3a");
  assertCycleClosed("cyc-3a", fx);
  assert.strictEqual(statusOf("cyc-3a", "workflow_init"), "in_progress");
});
caseEnd();

caseBegin("rerun-without-reset-from-closes-cycle-and-resets-downstream", "hooks/lib/wf-init-begun-mark.js");
test("rerun-without-reset-from-closes-cycle-and-resets-downstream", () => {
  const sid = "cyc-3b";
  const fx = closedCycle(sid);
  assert.strictEqual(statusOf(sid, "workflow_init"), "complete");
  markWorkflowInitBegun(sid);
  assertCycleClosed(sid, fx);
  const state = io().readState(sid);
  for (const k of ["delivery_path", "auto_merge_pr", "merge_base_baseline", "last_pushed_sha"]) {
    assert.ok(state[k] == null, `${k} must be cleared at the boundary, got ${JSON.stringify(state[k])}`);
  }
  assert.strictEqual(statusOf(sid, "workflow_init"), "in_progress", "the entry reopens workflow_init");
  const r = recordStepVerdict(sid, "workflow_init", "complete", { gate: "advance" });
  assert.strictEqual(r.ok, true, r.message);
  assert.strictEqual(r.already, false, "the advance must not stop at the idempotent-repeat return");
  for (const step of io().VALID_STEPS.filter((s) => s !== "workflow_init")) {
    assert.strictEqual(statusOf(sid, step), "pending", `${step} must be reset for the new cycle`);
  }
  assert.strictEqual(boundaries(sid).length, 1, "the backstop must not add a second boundary");
});
caseEnd();

caseBegin("sentinel-completion-backstop-closes-cycle", "hooks/workflow-state/record-step-verdict.js");
test("sentinel-completion-backstop-closes-cycle", () => {
  const sid = "cyc-3c";
  const fx = closedCycle(sid);
  const r = recordStepVerdict(sid, "workflow_init", "complete", { gate: "sentinel" });
  assert.strictEqual(r.ok, true, r.message);
  assertCycleClosed(sid, fx);
  assert.strictEqual(boundaries(sid)[0].reason, "workflow-init-complete");
  assert.strictEqual(statusOf(sid, "workflow_init"), "complete", "the backstop keeps the completion it follows");
  assert.strictEqual(statusOf(sid, "final_report"), "pending");
});
caseEnd();

caseBegin("next-step-after-boundary-sees-no-leftover", "hooks/workflow-state/resolve-worktree-path.js");
test("next-step-after-boundary-sees-no-leftover", () => {
  const sid = "cyc-4";
  const fx = closedCycle(sid);
  markWorkflowInitBegun(sid);
  const { resolveSessionWorktreePath } = require(F.rel("hooks/workflow-state/resolve-worktree-path.js"));
  assert.strictEqual(resolveSessionWorktreePath(sid), null, "the resolver must not return the leftover");
  const env = Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: fx.main, CLAUDE_TRANSCRIPT_BASE_DIR: TRANSCRIPTS });
  const r = F.runNode([F.rel("bin/workflow/next-step"), "--session", sid], { cwd: fx.main, env, timeout: 60000 });
  const out = r.out + r.err;
  assert.strictEqual(r.error, undefined, `next-step did not run to completion: ${r.error}\n${out}`);
  const action = /^ACTION=(\S*)/m.exec(r.out);
  assert.ok(action, `next-step printed no ACTION= line:\n${out}`);
  assert.ok(!["abort", "blocked"].includes(action[1]), `next-step returned ACTION=${action[1]}:\n${out}`);
  assert.ok(!/glossary-check-stale/.test(out), `next-step reported glossary-check-stale:\n${out}`);
  assert.ok(!/repo-dir-mismatch/.test(out), `next-step reported repo-dir-mismatch:\n${out}`);
});
caseEnd();

caseBegin("stop-guard-after-boundary-does-not-block", "hooks/stop-final-report-guard.js");
test("stop-guard-after-boundary-does-not-block", () => {
  const sid = "cyc-5";
  const fx = closedCycle(sid);
  markWorkflowInitBegun(sid);
  const transcript = path.join(TRANSCRIPTS, `${sid}.jsonl`);
  fs.writeFileSync(transcript, [
    JSON.stringify({ type: "user", message: { role: "user", content: "start the next task" } }),
    JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "Starting the new cycle." }] } }),
  ].join("\n") + "\n");
  const env = Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: fx.main, CLAUDE_TRANSCRIPT_BASE_DIR: TRANSCRIPTS });
  const r = F.runNode([F.rel("hooks/stop-final-report-guard.js")], {
    cwd: fx.main, env, input: JSON.stringify({ session_id: sid, transcript_path: transcript }),
  });
  assert.strictEqual(r.rc, 0, `the guard blocked a new cycle:\n${r.out}`);
  assert.ok(!/"decision":"block"/.test(r.out), r.out);
});
caseEnd();

caseBegin("close-cycle-is-idempotent", "hooks/workflow-state/cycle-state.js");
test("close-cycle-is-idempotent", () => {
  const close = F.need(CYCLE, "closeCycleIfFinished");
  const fx = closedCycle("cyc-idem");
  close("cyc-idem", "reinit-entry");
  close("cyc-idem", "reinit-entry");
  assertCycleClosed("cyc-idem", fx);
  assert.deepStrictEqual(boundaries("cyc-idem").map((e) => e.closed_cycle), [1]);
});
caseEnd();

caseBegin("second-cycle-archives-under-cycle-archive-2", "hooks/workflow-state/cycle-state.js");
test("second-cycle-archives-under-cycle-archive-2", () => {
  const sid = "cyc-second";
  const fx = closedCycle(sid);
  markWorkflowInitBegun(sid);
  assertCycleClosed(sid, fx);
  finishCycle(sid);
  markWorkflowInitBegun(sid);
  for (const name of CONTROL) {
    assert.ok(!fs.existsSync(path.join(fx.dir, name)), `${name} must leave the live control dir`);
    assert.ok(fs.existsSync(path.join(fx.dir, "cycle-archive", "2", name)), `${name} must be archived under cycle-archive/2`);
    assert.ok(fs.existsSync(path.join(fx.dir, "cycle-archive", "1", name)), `${name} of cycle 1 must stay archived`);
  }
  assert.deepStrictEqual(boundaries(sid).map((e) => e.closed_cycle), [1, 2]);
});
caseEnd();

// CONTROL_FILES is an allowlist: a name it does not list (including near-misses of a listed name)
// must stay in the live control dir, so widening the match to every file fails here.
caseBegin("boundary-archives-only-listed-control-files", "hooks/workflow-state/cycle-state.js");
test("boundary-archives-only-listed-control-files", () => {
  const sid = "cyc-allowlist";
  const fx = closedCycle(sid);
  const KEEP = ["supervisor-state.json", "wi-checkpoint.json", "foo.dispatched", "finalize-state.json", "final-report-env.json.bak"];
  const MOVE = ["finalize-state-1.json", "finalize-binding-7.json"];
  for (const name of [...KEEP, ...MOVE]) fs.writeFileSync(path.join(fx.dir, name), JSON.stringify({ session_id: sid }));
  markWorkflowInitBegun(sid);
  assert.strictEqual(boundaries(sid).length, 1, "fixture: the re-init must cross the cycle boundary");
  for (const name of KEEP) {
    assert.ok(fs.existsSync(path.join(fx.dir, name)), `${name} is not a control file and must stay in the live control dir`);
    assert.ok(!fs.existsSync(path.join(fx.dir, "cycle-archive", "1", name)), `${name} must not be archived under cycle-archive/1`);
  }
  for (const name of MOVE) {
    assert.ok(!fs.existsSync(path.join(fx.dir, name)), `${name} must leave the live control dir`);
    assert.ok(fs.existsSync(path.join(fx.dir, "cycle-archive", "1", name)), `${name} must be archived under cycle-archive/1`);
  }
});
caseEnd();

caseBegin("unfinished-cycle-entry-changes-nothing","hooks/lib/wf-init-begun-mark.js");
test("unfinished-cycle-entry-changes-nothing", () => {
  const sid = "cyc-unfinished";
  const fx = closedCycle(sid, { finished: false });
  markWorkflowInitBegun(sid);
  for (const name of CONTROL) assert.ok(fs.existsSync(path.join(fx.dir, name)), `${name} must stay`);
  assert.strictEqual(boundaries(sid).length, 0);
  assert.strictEqual(statusOf(sid, "workflow_init"), "complete", "an unfinished cycle keeps today's re-init behavior");
  assert.ok(F.samePath(io().readState(sid).session_worktree, fx.wt));
});
caseEnd();

caseBegin("unfinished-cycle-close-is-noop", "hooks/workflow-state/cycle-state.js");
test("unfinished-cycle-close-is-noop", () => {
  const close = F.need(CYCLE, "closeCycleIfFinished");
  const fx = closedCycle("cyc-noop", { finished: false });
  close("cyc-noop", "reinit-entry");
  for (const name of CONTROL) assert.ok(fs.existsSync(path.join(fx.dir, name)), `${name} must stay`);
  assert.strictEqual(boundaries("cyc-noop").length, 0);
});
caseEnd();

caseBegin("new-session-close-is-noop", "hooks/workflow-state/cycle-state.js");
test("new-session-close-is-noop", () => {
  const close = F.need(CYCLE, "closeCycleIfFinished");
  close("cyc-new", "reinit-entry");
  assert.ok(!fs.existsSync(io().getStatePath("cyc-new")), "no state file may be created");
  markWorkflowInitBegun("cyc-new");
  assert.strictEqual(boundaries("cyc-new").length, 0);
  assert.strictEqual(statusOf("cyc-new", "workflow_init"), "in_progress");
});
caseEnd();

caseBegin("cycle-boundary-event-is-validated", "hooks/workflow-state/state-io/events.js");
test("cycle-boundary-event-is-validated", () => {
  const ev = require(F.rel("hooks/workflow-state/state-io/events.js"));
  const good = { kind: "cycle_boundary", closed_cycle: 1, reason: "reinit-entry", provenance: "declared", origin: "cycle-boundary" };
  assert.doesNotThrow(() => ev.validateEvent(good));
  assert.strictEqual(ev.EVENT_KINDS.includes("cycle_boundary"), true);
  for (const field of ["closed_cycle", "reason"]) {
    const bad = Object.assign({}, good);
    delete bad[field];
    assert.throws(() => ev.validateEvent(bad), ev.InvalidEventError, `missing ${field} must be refused`);
  }
});
caseEnd();

caseBegin("cycle-boundary-event-refuses-bad-values", "hooks/workflow-state/state-io/events.js");
test("cycle-boundary-event-refuses-bad-values", () => {
  const ev = require(F.rel("hooks/workflow-state/state-io/events.js"));
  const good = { kind: "cycle_boundary", closed_cycle: 1, reason: "reinit-entry", provenance: "declared", origin: "cycle-boundary" };
  for (const reason of ["reinit-entry", "workflow-init-complete"]) {
    assert.doesNotThrow(() => ev.validateEvent(Object.assign({}, good, { reason, closed_cycle: 7 })), reason);
  }
  for (const closed_cycle of [0, -1, "1", 1.5, null]) {
    assert.throws(() => ev.validateEvent(Object.assign({}, good, { closed_cycle })), /closed_cycle/,
      `closed_cycle ${JSON.stringify(closed_cycle)} must be refused`);
  }
  for (const reason of ["", "merge", "REINIT-ENTRY"]) {
    assert.throws(() => ev.validateEvent(Object.assign({}, good, { reason })), /reason/,
      `reason ${JSON.stringify(reason)} must be refused`);
  }
});
caseEnd();

// cycle-state moves the files before it appends the event; a run killed between the two left the
// files archived (some or all) and no boundary, and the next call must finish the job once.
caseBegin("close-cycle-converges-after-interrupted-run", "hooks/workflow-state/cycle-state.js");
test("close-cycle-converges-after-interrupted-run", () => {
  const close = F.need(CYCLE, "closeCycleIfFinished");
  const sid = "cyc-interrupted";
  const fx = closedCycle(sid);
  const archive = path.join(fx.dir, "cycle-archive", "1");
  fs.mkdirSync(archive, { recursive: true });
  for (const name of CONTROL.slice(0, 2)) fs.renameSync(path.join(fx.dir, name), path.join(archive, name));
  assert.strictEqual(boundaries(sid).length, 0, "fixture: the interrupted run wrote no boundary");
  assert.strictEqual(close(sid, "reinit-entry"), true);
  assertCycleClosed(sid, fx);
  assert.deepStrictEqual(boundaries(sid).map((e) => e.closed_cycle), [1]);
  assert.strictEqual(close(sid, "reinit-entry"), false, "a second call after convergence is a no-op");
  assert.strictEqual(boundaries(sid).length, 1);
});
caseEnd();

caseBegin("cycle-boundary-fold-returns-cwd-home", "hooks/workflow-state/state-io/projection.js");
test("cycle-boundary-fold-returns-cwd-home", () => {
  const sid = "cyc-fold";
  const home = path.join(SB, "fold-home");
  const wt = path.join(SB, "fold-wt");
  F.seedState(sid, home);
  F.enterWorktree(sid, wt);
  assert.ok(F.samePath(io().readState(sid).cwd, wt), "fixture: the worktree event moves cwd");
  io().appendEvents(sid, [{ kind: "cycle_boundary", closed_cycle: 1, reason: "reinit-entry", provenance: "declared", origin: "cycle-boundary" }]);
  const state = io().readState(sid);
  assert.ok(F.samePath(state.cwd, home), `cwd must return to the start cwd, got ${state.cwd}`);
  assert.strictEqual(state.worktree_entered_at, null);
  assert.strictEqual(state.worktree_exited_at, null);
});
caseEnd();
