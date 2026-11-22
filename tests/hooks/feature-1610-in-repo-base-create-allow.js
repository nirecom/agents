"use strict";
// Tests: hooks/enforce-worktree/main-worktree-allows/worktree-command.js, hooks/enforce-worktree/main-worktree-allows/new-item.js, hooks/enforce-worktree.js
// Tags: feature-1610, feature-1849, enforce-worktree, worktree-add, new-item, in-repo-base, path-traversal, security, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap: no live Claude Code session runs `git worktree add` / New-Item through the PreToolUse
// chain here; the hook is driven with a synthetic payload from a fixture main checkout.
//
// #1610: the default worktree base is <main>/.claude/worktrees. Creating a worktree from the main
// checkout is allowed when the target is strictly below that repo's own base (both verdicts pinned):
// the base itself, a sibling `.claude/worktrees-x`, the rest of `.claude/`, other repo paths,
// and traversal back into the repo stay blocked.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");

const restore = isolate();
const { isAllowedWorktreeCommand } = require("../../hooks/enforce-worktree/main-worktree-allows/worktree-command");
const { isAllowedNewItemCommand } = require("../../hooks/enforce-worktree/main-worktree-allows/new-item");

const SB = F.makeBase("f1610ia-");
const MAIN = F.makeRepo(path.join(SB, "main"));
F.git(["-C", MAIN, "branch", "-M", "main"]);
const OTHER = F.makeRepo(path.join(SB, "other"));
const fwd = (p) => p.replace(/\\/g, "/");
const M = fwd(MAIN);
const IN_BASE = `${M}/.claude/worktrees/my-task/main`;
const BLOCKED = {
  "base itself": `${M}/.claude/worktrees`,
  "base with trailing slash": `${M}/.claude/worktrees/`,
  "sibling-prefix base": `${M}/.claude/worktrees-x/my-task`,
  "other .claude dir": `${M}/.claude/other/my-task`,
  "plain repo path": `${M}/src/my-task`,
  "traversal out of the base": `${M}/.claude/worktrees/../../src/x`,
};

const SAVED_HOME = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
after(() => {
  for (const [k, v] of Object.entries(SAVED_HOME)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

const add = (target) => `git worktree add "${target}" -b feature/my-task`;

caseBegin("worktree-add-into-own-in-repo-base-allowed", "hooks/enforce-worktree/main-worktree-allows/worktree-command.js");
test("worktree-add-into-own-in-repo-base-allowed", () => {
  assert.equal(isAllowedWorktreeCommand(add(IN_BASE), MAIN), true, "git worktree add <main>/.claude/worktrees/<task>/<repo>");
  assert.equal(isAllowedWorktreeCommand(`git -C "${M}" worktree add "${IN_BASE}" -b feature/my-task`, MAIN), true, "with -C <main>");
  assert.equal(isAllowedWorktreeCommand(add(`${M}/.CLAUDE/Worktrees/my-task/main`), MAIN), true,
    "case-insensitive compare, the same style as isPathOutsideRepo");
  assert.equal(isAllowedWorktreeCommand(add(`${fwd(OTHER)}/.claude/worktrees/t/other`), OTHER), true,
    "each repo's own base, judged against that repo's root");
});
caseEnd();

caseBegin("worktree-add-in-repo-outside-base-still-blocked", "hooks/enforce-worktree/main-worktree-allows/worktree-command.js");
test("worktree-add-in-repo-outside-base-still-blocked", () => {
  for (const [label, target] of Object.entries(BLOCKED)) {
    assert.equal(isAllowedWorktreeCommand(add(target), MAIN), false, `${label}: ${target}`);
  }
  // The exception is keyed to the repo being judged: OTHER's root does not except MAIN's base layout.
  assert.equal(isAllowedWorktreeCommand(add(`${fwd(OTHER)}/src/x`), OTHER), false, "other repo's plain path from OTHER");
  assert.equal(isAllowedWorktreeCommand(add(`${fwd(OTHER)}/.claude/worktrees`), OTHER), false, "other repo's base itself");
});
caseEnd();

caseBegin("worktree-add-outside-repo-unchanged", "hooks/enforce-worktree/main-worktree-allows/worktree-command.js");
test("worktree-add-outside-repo-unchanged", () => {
  assert.equal(isAllowedWorktreeCommand(add(`${fwd(SB)}/shared/my-task/main`), MAIN), true);
  assert.equal(isAllowedWorktreeCommand("git worktree add -b foo", MAIN), true, "path omitted stays fail-open");
});
caseEnd();

const ni = (p) => `New-Item -ItemType Directory -Path "${p}"`;

caseBegin("new-item-into-own-in-repo-base-allowed", "hooks/enforce-worktree/main-worktree-allows/new-item.js");
test("new-item-into-own-in-repo-base-allowed", () => {
  assert.equal(isAllowedNewItemCommand(ni(IN_BASE), MAIN), true, "double-quoted static path");
  assert.equal(isAllowedNewItemCommand(`New-Item -ItemType Directory -Path '${IN_BASE}'`, MAIN), true, "single-quoted literal path");
  process.env.HOME = SB;
  process.env.USERPROFILE = SB;
  assert.equal(isAllowedNewItemCommand("New-Item -ItemType Directory -Path $HOME/main/.claude/worktrees/my-task/main", MAIN), true,
    "$HOME-expanded path");
});
caseEnd();

caseBegin("new-item-in-repo-outside-base-still-blocked", "hooks/enforce-worktree/main-worktree-allows/new-item.js");
test("new-item-in-repo-outside-base-still-blocked", () => {
  for (const [label, target] of Object.entries(BLOCKED)) {
    assert.equal(isAllowedNewItemCommand(ni(target), MAIN), false, `double-quoted ${label}: ${target}`);
    assert.equal(isAllowedNewItemCommand(`New-Item -ItemType Directory -Path '${target}'`, MAIN), false, `single-quoted ${label}`);
  }
  process.env.HOME = SB;
  process.env.USERPROFILE = SB;
  assert.equal(isAllowedNewItemCommand("New-Item -ItemType Directory -Path $HOME/main/.claude/worktrees", MAIN), false, "$HOME base itself");
  assert.equal(isAllowedNewItemCommand("New-Item -ItemType Directory -Path $HOME/main/.claude/x", MAIN), false, "$HOME other .claude dir");
  assert.equal(isAllowedNewItemCommand(`New-Item -ItemType File -Path "${IN_BASE}/f.txt"`, MAIN), false, "-ItemType File never allowed");
});
caseEnd();

function ewRun(command, toolName = "Bash") {
  const payload = JSON.stringify({ session_id: "f1610ia", tool_name: toolName, tool_input: { command } });
  const env = { ...process.env, ENFORCE_WORKTREE: "on", AGENTS_MAIN_ROOT: MAIN };
  for (const k of ["CLAUDE_CODE_SESSION_ID", "SCRATCHPAD", "DEFAULT_BRANCHES", "ENFORCE_WORKTREE_ADDITIONAL_REPOS", "WORKFLOW_OFF"]) delete env[k];
  const r = F.runNode([F.rel("hooks/enforce-worktree.js")], { cwd: MAIN, input: payload, env, timeout: 30000 });
  const out = r.out.replace(/[\r\n]/g, "");
  if (r.rc !== 0) return `crash:${r.rc}`;
  if (out === "{}") return "allow";
  return /"decision":"block"/.test(out) ? "block" : `other:${out}`;
}

caseBegin("hook-allows-in-repo-base-add-and-blocks-the-rest", "hooks/enforce-worktree.js");
test("hook-allows-in-repo-base-add-and-blocks-the-rest", () => {
  assert.equal(ewRun(add(IN_BASE)), "allow", "end-to-end: add into the own in-repo base");
  assert.equal(ewRun(add(BLOCKED["base itself"])), "block", "end-to-end: the base itself");
  assert.equal(ewRun(add(BLOCKED["other .claude dir"])), "block", "end-to-end: other .claude dir");
  assert.equal(ewRun(add(BLOCKED["traversal out of the base"])), "block", "end-to-end: traversal");
});
caseEnd();

caseBegin("hook-allows-in-repo-base-new-item-and-blocks-the-rest", "hooks/enforce-worktree.js");
test("hook-allows-in-repo-base-new-item-and-blocks-the-rest", () => {
  // New-Item reaches enforce-worktree as Bash command text (settings.json matcher; PowerShell is no command tool).
  assert.equal(ewRun(ni(BLOCKED["plain repo path"]), "PowerShell"), "allow", "control: an unmatched tool_name is never judged");
  assert.equal(ewRun(ni(BLOCKED["plain repo path"])), "block", "the Bash route is judged, unlike the unmatched tool_name");
  for (const label of ["base itself", "sibling-prefix base", "other .claude dir", "plain repo path", "traversal out of the base"]) {
    assert.equal(ewRun(ni(BLOCKED[label])), "block", `end-to-end New-Item: ${label}`);
  }
  assert.equal(ewRun(ni(IN_BASE)), "allow", "end-to-end: New-Item into the own in-repo base");
});
caseEnd();
