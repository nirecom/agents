"use strict";
// Tests: docs/architecture/claude-code/settings/hook-timeout.md, settings.json, hooks/scan-outbound.js, hooks/workflow-gate.js, hooks/enforce-worktree.js, hooks/confirm-forge-target-ownership.js, hooks/check-cross-platform.js
// Tags: TL1, TL2, hooks, pretooluse, allow-deny-hook, non-allow-deny-hook, decision-time-limit, settings, docs, scope:issue-specific, subprocess, scan-outbound, workflow-gate, enforce-worktree, settings-registration, block-case-markers
// Serial: spawns every PreToolUse hook and real git commits; ~100 s alone, exceeds the 180 s file limit under parallel load
// #2676 / #2540 Step 6 (split from feature-2676-hook-classification.js): scan-outbound and
// workflow-gate launched by the command string settings.json registers, deciding as before and
// answering "ask" at a shrunken limit.
// TL3 gap (what this test does NOT catch):
// - how Claude Code acts on each printed decision; its launch delay and cancel of an overrun hook
// Closest-to-action mitigation: tests/hooks/TL3-hook-registered-deny.sh, TL3-hook-timeout-window.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const fx = require("./feature-2676-hook-classification/fixture");
after(() => { fx.cleanup(); restore(); });
const { LIMIT_MS, bash, limitAsk, decided } = require("./feature-2676-hook-classification/common");

// --- the real settings.json registration (not a fake settings, not a direct script path) -------
// Each case launches the hook by the command string settings.json registers for Bash and then
// plays Claude Code's part: the commit runs only when the decision lets the tool run.
const reg = require("./feature-2676-hook-classification/registration");
const commitInput = (repo) => bash(`git -C ${repo} commit -m "test"`);
const COMMIT_ARGV = ["commit", "-q", "-m", "test"];
// The registered command names the root variable; built from parts so no line joins it to a code dir.
const ROOT_VAR = "$" + "AGENTS_MAIN_ROOT";

caseBegin("scan-outbound-registration", "hooks/scan-outbound.js");
// The scanner reads its lists from the main worktree of its own checkout: a copy attached to the
// fixture repo makes that main worktree the fixture, so the outcome is the same on every host.
function scanOutboundRepo(label, content) {
  const repo = fx.makeRepo(label, { "notes.txt": content });
  fs.writeFileSync(path.join(repo, ".private-info-blocklist"), "forbiddenword[0-9]+\n");
  fs.writeFileSync(path.join(repo, ".private-info-allowlist"), "");
  return { repo, agentsRoot: reg.checkoutCopy(repo), warm: true };
}
test("scan-outbound registration: matcher covers Bash and the command is the deployed one", () => {
  const registration = reg.registeredCommand("scan-outbound");
  assert.strictEqual(registration.command, `node "${ROOT_VAR}/hooks/scan-outbound.js"`);
});
test("scan-outbound registration: a staged private IP is denied and the commit does not run", () => {
  const { repo, agentsRoot, warm } = scanOutboundRepo("soregdeny", "Internal gateway at 10.20.30.40 is offline.\n");
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("scan-outbound", commitInput(repo), { agentsRoot, warm });
  decided(run, "block");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, false);
  assert.strictEqual(reg.commitCount(repo), before, "the protected commit was not made");
});
test("scan-outbound registration (control): clean staged text is approved and the commit runs", () => {
  const { repo, agentsRoot, warm } = scanOutboundRepo("soregclean", "Just an ordinary log line with nothing sensitive.\n");
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("scan-outbound", commitInput(repo), { agentsRoot, warm });
  decided(run, "approve");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, true);
  assert.strictEqual(reg.commitCount(repo), before + 1, "the permitted commit was made (the emulation is not vacuous)");
});
test("scan-outbound registration: at the limit -> ask in the fixed reason format, no commit", () => {
  const repo = fx.makeRepo("soreglimit", { "a.txt": "hello\n" });
  const before = reg.commitCount(repo);
  // The preload rewrites hooks/lib/decision-time-limit.js of this checkout, so the root is this checkout.
  const run = reg.runRegistered("scan-outbound", commitInput(repo),
    { env: { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (show|cat-file)" } });
  limitAsk(run, "scan-outbound", /git (show|cat-file)/);
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, false);
  assert.strictEqual(reg.commitCount(repo), before);
});
caseEnd();

caseBegin("workflow-gate-registration", "hooks/workflow-gate.js");
// writeBegunState: workflow_init complete and every other step pending, so a commit is premature.
function writeBegunState(sessionId) {
  const { VALID_STEPS } = require("../../hooks/workflow-state.js");
  const now = new Date().toISOString();
  const steps = Object.fromEntries(VALID_STEPS.map((step) => [step, { status: "pending", updated_at: null }]));
  steps.workflow_init = { status: "complete", updated_at: now };
  const state = { version: 1, session_id: sessionId, created_at: now, steps };
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sessionId}.json`), JSON.stringify(state, null, 2));
}
const commitIn = (repo, sessionId) => ({ ...commitInput(repo), session_id: sessionId });
// These cases judge the decision, not the limit: run from a fresh checkout copy, with each git call
// going through the run-all command guard, the commit path overruns the decision time limit on Windows and asks. A limit
// near the wait cap keeps the decision reachable; the at-the-limit case below still uses LIMIT_MS.
const decisionRun = (repo) => ({ agentsRoot: reg.checkoutCopy(repo), warm: true, env: { F2540_LIMIT_MS: String(fx.WAIT_CAP_MS - 1000) } });
test("workflow-gate registration: matcher covers Bash and the command is the deployed one", () => {
  const registration = reg.registeredCommand("workflow-gate");
  assert.strictEqual(registration.command, `node "${ROOT_VAR}/hooks/workflow-gate.js"`);
});
test("workflow-gate registration: a commit in a begun, incomplete workflow is denied and does not run", () => {
  const sessionId = "00000000-0000-4000-8000-0000000025a1";
  const repo = fx.makeRepo("wgregdeny", { "app.js": "src\n" });
  writeBegunState(sessionId);
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("workflow-gate", commitIn(repo, sessionId), decisionRun(repo));
  decided(run, "block");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, false);
  assert.strictEqual(reg.commitCount(repo), before, "the protected commit was not made");
});
test("workflow-gate registration (control): no workflow state -> approved and the commit runs", () => {
  const sessionId = "00000000-0000-4000-8000-0000000025a2";
  const repo = fx.makeRepo("wgregclean", { "app.js": "src\n" });
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("workflow-gate", commitIn(repo, sessionId), decisionRun(repo));
  decided(run, "approve");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, true);
  assert.strictEqual(reg.commitCount(repo), before + 1, "the permitted commit was made (the emulation is not vacuous)");
});
test("workflow-gate registration: at the limit -> ask in the fixed reason format", () => {
  const linked = fx.makeLinkedWorktree(fx.makeRepo("wgreglimit"));
  const run = reg.runRegistered("workflow-gate", bash('echo "<<WORKFLOW_USER_VERIFIED: fixture>>"', linked),
    { env: { ENFORCE_WORKTREE: "on", F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (-C \\S+ )?rev-parse" } });
  limitAsk(run, "workflow-gate", /git (-C \S+ )?rev-parse/);
});
caseEnd();
