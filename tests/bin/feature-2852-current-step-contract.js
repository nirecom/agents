#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/next-step, hooks/workflow-state/reconciled-current-step.js
// Tags: TL2, next-step, current-step, reconcile, reset-allowance, scope:issue-specific, pwsh-not-required
// #2852: the current step is owned by hooks/workflow-state/reconciled-current-step.js. Over the
// derived-status fixtures (write_code resume, skip veto, refused unapproved completion, delivery
// boundary) resolveReconciledCurrentStep, next-step's invoke and the `[*]` row of next-step --list
// all name the same step; firstUnsettledStep skips the terminal step only.
// TL3 gap (what this test does NOT catch):
// - the network evidence a live forge would add (gh is stubbed to fail, so evidence stays offline).

const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { confirmEnvRoot, childEnvWith, withConfirmEnv } = require("../lib/confirm-env-fixture");

const restore = isolate();
const BASE = fs.mkdtempSync(path.join(os.tmpdir(), "f2852c-"));
const REPO = path.join(BASE, "repo");
const NO_TRANSCRIPTS = path.join(BASE, "transcripts");
const GH_STUB = path.join(BASE, "gh-stub");
const GH_CONFIG = path.join(BASE, "gh-config");
for (const d of [REPO, NO_TRANSCRIPTS, GH_STUB, GH_CONFIG]) fs.mkdirSync(d);
gitInit(REPO);
// gh always fails, so no case reaches a real forge.
fs.writeFileSync(path.join(GH_STUB, "gh"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
fs.writeFileSync(path.join(GH_STUB, "gh.cmd"), "@exit /b 1\r\n");
after(() => {
  restore();
  fs.rmSync(BASE, { recursive: true, force: true });
});

const F = require("../hooks/feature-2852-reset-allowance/fixture");
const NEXT_STEP = path.join(F.ROOT, "bin", "workflow", "next-step");
const { STEP_TO_SKILL } = F.mod("bin/workflow/lib/next-step/steps.js");
const CONTRACT = "hooks/workflow-state/reconciled-current-step.js";
const CFG_OFF = confirmEnvRoot(BASE, F.ALL_OFF);

function childEnv(cfg) {
  const env = childEnvWith(cfg);
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.GH_TOKEN;
  delete env.GITHUB_TOKEN;
  env.CLAUDE_TRANSCRIPT_BASE_DIR = NO_TRANSCRIPTS;
  env.GH_CONFIG_DIR = GH_CONFIG;
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";
  env[key] = GH_STUB + path.delimiter + (env[key] || "");
  return env;
}

function runNextStep(sid, cfg, extra) {
  const r = spawnSync(process.execPath, [NEXT_STEP].concat(extra || [], ["--session", sid]),
    { cwd: REPO, env: childEnv(cfg), encoding: "utf8", timeout: 60000 });
  assert.ok(!r.error, `next-step did not run: ${r.error && r.error.message}`);
  return r;
}

// nextStepStep(sid, cfg) — the step next-step sends the session to (invoke only).
function nextStepStep(sid, cfg) {
  const r = runNextStep(sid, cfg);
  const kv = {};
  for (const line of String(r.stdout).split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1").replace(/^"(.*)"$/, "$1");
  }
  const where = `rc=${r.status} stdout=${String(r.stdout).slice(0, 600)} stderr=${String(r.stderr).slice(0, 300)}`;
  assert.strictEqual(kv.ACTION, "invoke", where);
  if (F.STEPS.includes(kv.REASON)) return kv.REASON;
  const bySkill = F.STEPS.filter((s) => STEP_TO_SKILL[s] === kv.NEXT_SKILL);
  assert.strictEqual(bySkill.length, 1, `no single step for NEXT_SKILL: ${where}`);
  return bySkill[0];
}

// listCurrentStep(sid, cfg) — the step on the `[*]` row of next-step --list.
function listCurrentStep(sid, cfg) {
  const r = runNextStep(sid, cfg, ["--list"]);
  const rows = String(r.stdout).split(/\r?\n/).map((l) => l.match(/^\s*\[\*\]\s+\d+\s+([a-z_]+)/)).filter(Boolean);
  assert.strictEqual(rows.length, 1, `one [*] row: rc=${r.status} stdout=${String(r.stdout).slice(0, 1500)}`);
  return rows[0][1];
}

function contractStep(sid, cfg) {
  const resolve = F.need(CONTRACT, "resolveReconciledCurrentStep");
  const state = F.read(sid);
  const profile = F.mod("hooks/workflow-state/session-profile").resolveSessionProfile(state, sid, { repoDir: REPO });
  const r = withConfirmEnv(cfg, () => resolve(state, sid, { repoDir: REPO, profile }));
  assert.ok(r && r.ok === true, `resolveReconciledCurrentStep: ${JSON.stringify(r)}`);
  return r.step;
}

let n = 0;
function fixture(tag, events, opts) {
  const sid = `f2852c-${tag}-${++n}`;
  F.seed(sid, events, Object.assign({ cwd: REPO }, opts || {}));
  F.writeIntent(sid);
  return sid;
}

const FIXTURES = [
  ...["fail", "timeout", "runner-error"].map((outcome) => ({
    label: `write_code resume (run_outcome ${outcome})`, want: "write_code", cfg: CFG_OFF,
    events: F.completeRange("workflow_init", "run_tests").concat([F.note("run_tests", "run_outcome", outcome), F.st("run_tests", "pending")]),
  })),
  {
    label: "skip veto on outline", want: "outline", cfg: CFG_OFF,
    events: F.completeRange("workflow_init", "outline").concat([F.st("outline", "skipped"),
      F.note("outline", "skip_verdict", { verdict: "veto", source: "fixture", recorded_at: F.isoAt(0) })],
    F.completeRange("detail", "review_tests")),
  },
  {
    label: "unapproved outline completion under CONFIRM_OUTLINE=on", want: "outline",
    cfg: confirmEnvRoot(BASE, Object.assign({}, F.ALL_OFF, { CONFIRM_OUTLINE: "on" })),
    // Nothing after outline reads complete: a later complete step would trip next-step's
    // inconsistency scan (abort), which is not the contract under test.
    events: F.completeRange("workflow_init", "detail", { unapproved: ["outline"] }),
  },
  {
    label: "delivery boundary (user_verification pending post-merge, direct)", want: "merge_to_main", cfg: CFG_OFF,
    deliveryPath: "direct",
    events: F.completeRange("workflow_init", "push_branch").concat([
      F.note("user_verification", "reset_reason", "post-merge"), F.st("user_verification", "pending"),
      F.st("cleanup", "pending"), F.st("pre_final_report_gate", "pending")]),
  },
];

caseBegin("next-step-matches-the-contract", "bin/workflow/next-step");
for (const fx of FIXTURES) {
  test(`next-step invokes the derived current step: ${fx.label}`, () => {
    const sid = fixture("ns", fx.events, { deliveryPath: fx.deliveryPath });
    assert.strictEqual(nextStepStep(sid, fx.cfg), fx.want);
  });
  test(`next-step --list marks the derived current step: ${fx.label}`, () => {
    const sid = fixture("ls", fx.events, { deliveryPath: fx.deliveryPath });
    assert.strictEqual(listCurrentStep(sid, fx.cfg), fx.want);
  });
}
caseEnd();

caseBegin("contract-resolves-the-derived-step", "hooks/workflow-state/reconciled-current-step.js");
for (const fx of FIXTURES) {
  test(`resolveReconciledCurrentStep names the step next-step invokes: ${fx.label}`, () => {
    const sid = fixture("ct", fx.events, { deliveryPath: fx.deliveryPath });
    assert.strictEqual(contractStep(sid, fx.cfg), fx.want);
  });
}
test("a missing or unreadable state is not ok", () => {
  const resolve = F.need(CONTRACT, "resolveReconciledCurrentStep");
  for (const state of [null, undefined, "x"]) {
    let r;
    assert.doesNotThrow(() => { r = resolve(state, "f2852c-none", { repoDir: REPO }); });
    assert.ok(r && r.ok !== true, `state ${JSON.stringify(state)}: ${JSON.stringify(r)}`);
  }
});
caseEnd();

caseBegin("first-unsettled-step", "hooks/workflow-state/reconciled-current-step.js");
const statusOf = (map) => (step) => map[step];
const allAs = (status) => Object.fromEntries(F.STEPS.map((s) => [s, status]));
test("the first step that is neither complete nor skipped, terminal step excluded", () => {
  const first = F.need(CONTRACT, "firstUnsettledStep");
  assert.strictEqual(first(statusOf(allAs("pending"))), "workflow_init", "all pending");
  assert.strictEqual(first(statusOf(allAs("complete"))), null, "all complete");
  assert.strictEqual(first(statusOf(Object.assign(allAs("complete"), { final_report: "pending" }))), null, "only final_report");
  assert.strictEqual(first(statusOf(Object.assign(allAs("complete"), { research: "skipped", outline: "skipped" }))), null, "skipped is settled");
  assert.strictEqual(first(statusOf(Object.assign(allAs("complete"), { docs: "pending", cleanup: "pending" }))), "docs", "earliest wins");
  assert.strictEqual(first(statusOf(Object.assign(allAs("complete"), { review_docs: undefined }))), "review_docs", "unknown status is unsettled");
});
caseEnd();
