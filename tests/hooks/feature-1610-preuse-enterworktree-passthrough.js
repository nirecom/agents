"use strict";
// Tests: hooks/preuse-auto-approve/judge.js
// Tags: feature-1610, preuse-auto-approve, enterworktree, monitor, auto-approve, config-dependent, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap: no real Claude Code session drives the PreToolUse hook here; whether the harness still
// shows its own EnterWorktree dialog once the hook stops answering is only observable live.
//
// #1610: EnterWorktree is no longer auto-approved by preuse-auto-approve — every path, the old
// WORKTREE_BASE_DIR included, gets no decision. Monitor keeps its allow, and AUTO_APPROVE_TOOLS=off
// still turns that allow off.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const { judgeAutoApprove } = require("../../hooks/preuse-auto-approve/judge");

const SB = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f1610pa-")));
const BASE = path.join(SB, "base");
const INSIDE = path.join(BASE, "task", "repo");
fs.mkdirSync(INSIDE, { recursive: true });

const SAVED = { WORKTREE_BASE_DIR: process.env.WORKTREE_BASE_DIR, AUTO_APPROVE_TOOLS: process.env.AUTO_APPROVE_TOOLS };
function withEnv(vars, fn) {
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(SAVED)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

caseBegin("enterworktree-inside-old-base-passes-through", "hooks/preuse-auto-approve/judge.js");
test("enterworktree-inside-old-base-passes-through", () => {
  const r = withEnv({ WORKTREE_BASE_DIR: BASE, AUTO_APPROVE_TOOLS: "on" },
    () => judgeAutoApprove({ tool_name: "EnterWorktree", tool_input: { path: INSIDE } }));
  assert.equal(r.decision, "none", `EnterWorktree inside the base must get no decision, got ${JSON.stringify(r)}`);
});
caseEnd();

caseBegin("enterworktree-name-only-and-outside-pass-through", "hooks/preuse-auto-approve/judge.js");
test("enterworktree-name-only-and-outside-pass-through", () => {
  for (const toolInput of [{ name: "feature-x" }, { path: SB }, {}]) {
    const r = withEnv({ WORKTREE_BASE_DIR: BASE, AUTO_APPROVE_TOOLS: undefined },
      () => judgeAutoApprove({ tool_name: "EnterWorktree", tool_input: toolInput }));
    assert.equal(r.decision, "none", `input ${JSON.stringify(toolInput)} -> ${JSON.stringify(r)}`);
  }
});
caseEnd();

caseBegin("monitor-still-allowed", "hooks/preuse-auto-approve/judge.js");
test("monitor-still-allowed", () => {
  const r = withEnv({ WORKTREE_BASE_DIR: undefined, AUTO_APPROVE_TOOLS: undefined },
    () => judgeAutoApprove({ tool_name: "Monitor", tool_input: {} }));
  assert.equal(r.decision, "allow");
  assert.match(r.reason, /Monitor auto-approved/);
});
caseEnd();

caseBegin("auto-approve-off-disables-monitor", "hooks/preuse-auto-approve/judge.js");
test("auto-approve-off-disables-monitor", () => {
  for (const off of ["off", "OFF", " Off "]) {
    const r = withEnv({ AUTO_APPROVE_TOOLS: off }, () => judgeAutoApprove({ tool_name: "Monitor", tool_input: {} }));
    assert.equal(r.decision, "none", `AUTO_APPROVE_TOOLS=${JSON.stringify(off)} -> ${JSON.stringify(r)}`);
  }
});
caseEnd();
