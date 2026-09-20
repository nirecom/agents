#!/usr/bin/env node
"use strict";
// tests/feature-2326-rtk-rewrite/test-rtk-rewrite.js
// Pure Node.js (no framework) tests for the rtk-rewrite decision pipeline and
// its four guards. Guard cases run with rtkOn/rtkBin injected so no child
// process spawns; the RTK=off case exercises the real config resolution.

const path = require("path");
const assert = require("assert");

// isAgentsEmit needs AGENTS_CONFIG_DIR; pin it to this worktree's agents root.
process.env.AGENTS_CONFIG_DIR = path.join(__dirname, "..", "..");
delete process.env.CLAUDE_SESSION_ID;
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.CLAUDE_ENV_FILE;

const HOOK = path.join(__dirname, "..", "..", "hooks", "rtk-rewrite.js");
const { decide } = require(HOOK);

let pass = 0;
let fail = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS: ${name}`); pass++; }
  catch (e) { console.log(`FAIL: ${name} — ${e.message}`); fail++; }
}

const OPTS = { rtkOn: true, rtkBin: "/fake/rtk" };
function run(command) {
  return decide({ tool_name: "Bash", tool_input: { command } }, OPTS);
}
function expectPass(command) {
  const out = run(command);
  assert.deepStrictEqual(out, {}, `expected passthrough for: ${command} (got ${JSON.stringify(out)})`);
}
function expectWrap(command) {
  const out = run(command);
  assert.ok(out && out.hookSpecificOutput && out.hookSpecificOutput.permissionDecision === "allow",
    `expected wrap for: ${command} (got ${JSON.stringify(out)})`);
}

// G-a: agents-framework emitters.
const G_A_PASS = [
  'node "$AGENTS_CONFIG_DIR/bin/next-step" --advance',
  "$AGENTS_CONFIG_DIR/bin/get-config-var --is-off CODEGRAPH off",
];
for (const c of G_A_PASS) check(`G-a passthrough: ${c}`, () => expectPass(c));
check("G-a does not swallow plain git status", () => expectWrap("git status"));

// G-b: machine-readable output.
const G_B_PASS = [
  "git rev-parse HEAD",
  "git -C repo rev-parse HEAD",
  "git -Crepo rev-parse HEAD",
  "git --git-dir=.git rev-parse HEAD",
  "git --no-pager rev-parse HEAD",
  "git --bare rev-parse HEAD",
  "git log --format %H",
  "git log --pretty tformat:%H",
  "git log --format=%H",
  "git status --porcelain",
  "git diff --name-only",
  "gh repo list --json name",
];
for (const c of G_B_PASS) check(`G-b passthrough: ${c}`, () => expectPass(c));
check("G-b non-plumbing/non-machine wraps: git -C . log --oneline", () => expectWrap("git -C . log --oneline"));

// G-c: composite / redirect / substitution.
const G_C_PASS = [
  "git status | cat",
  "git add . && git status",
  "git status > out.txt",
  "cat >> log",
  "git status>/tmp/out",
  "git log 2>&1",
  "git status `printf x`",
  'git status "$(pwd)"',
];
for (const c of G_C_PASS) check(`G-c passthrough: ${c}`, () => expectPass(c));

// G-d: shell builtins / assignments.
const G_D_PASS = [
  "declare -A map",
  "local var=1",
  "readonly FOO=bar",
  '"cd" /tmp',
  'echo "<<WORKFLOW_RESET_FROM_detail: test>>"',
  "printf '%s\\n' hello",
  "true",
  "false",
  "test -f /etc/hosts",
  "[ -f /etc/hosts ]",
];
for (const c of G_D_PASS) check(`G-d passthrough: ${c}`, () => expectPass(c));

// C4-RTK: anti-double-wrap.
const C4_PASS = [
  "rtk gain",
  '"rtk" recall foo',
  "env RTK_DEBUG=1 rtk gain",
];
for (const c of C4_PASS) check(`C4-RTK passthrough: ${c}`, () => expectPass(c));

// Positive wrap: exact command shape.
check("positive wrap command shape", () => {
  const out = decide(
    { tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk" },
  );
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "/fake/rtk git status");
});

// RTK=off fallback: real config resolution must yield passthrough.
check("RTK=off → passthrough", () => {
  const saved = process.env.RTK;
  process.env.RTK = "off";
  try {
    const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } });
    assert.deepStrictEqual(out, {});
  } finally {
    if (saved === undefined) delete process.env.RTK;
    else process.env.RTK = saved;
  }
});

// Non-Bash tool → passthrough.
check("non-Bash tool → passthrough", () => {
  assert.deepStrictEqual(
    decide({ tool_name: "Edit", tool_input: { command: "git status" } }, OPTS),
    {},
  );
});

console.log("----");
console.log(`PASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
