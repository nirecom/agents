"use strict";
// Fixture for tests/hooks/feature-2326-rtk-rewrite.js: the rtk-rewrite hook under test,
// its fake spawn helpers, and the data tables the table-driven cases iterate.

const path = require("path");
const os = require("os");
const fs = require("fs");
const assert = require("assert");

const ROOT = path.join(__dirname, "..", "..", "..");
// isAgentsEmit needs AGENTS_MAIN_ROOT; pin it to this worktree's agents root.
process.env.AGENTS_MAIN_ROOT = ROOT;
delete process.env.CLAUDE_CODE_SESSION_ID;

const HOOK = path.join(ROOT, "hooks", "rtk-rewrite.js");
const { decide, substituteRtkHead, quoteBin } = require(HOOK);

// Stateless fake `rtk hook claude` returning a canned allow wrap; the default
// spawnFn so wrap-expecting cases work under delegation with no real child.
const CANNED_WRAP = {
  hookSpecificOutput: {
    permissionDecision: "allow",
    updatedInput: { command: "CANNED wrap" },
  },
};
function cannedSpawn() {
  return { status: 0, stdout: JSON.stringify(CANNED_WRAP), stderr: "", error: null };
}
// Capturing fake: records each call's bin/args/env/input and returns `out`.
function makeSpawnFake(out) {
  const calls = [];
  const fn = (bin, args, spawnOpts) => {
    calls.push({
      bin,
      args,
      input: spawnOpts && spawnOpts.input,
      env: spawnOpts && spawnOpts.env,
    });
    return { status: 0, stdout: JSON.stringify(out), stderr: "", error: null };
  };
  return { fn, calls };
}

const OPTS = { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: cannedSpawn, auditOn: false };
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

// C1 — RTK_HOOK_AUDIT env inheritance in the delegated child env.
function withParentAudit(value, body) {
  const saved = process.env.RTK_HOOK_AUDIT;
  if (value === undefined) delete process.env.RTK_HOOK_AUDIT;
  else process.env.RTK_HOOK_AUDIT = value;
  try { body(); } finally {
    if (saved === undefined) delete process.env.RTK_HOOK_AUDIT;
    else process.env.RTK_HOOK_AUDIT = saved;
  }
}
function captureChildEnv(auditOn) {
  const { fn, calls } = makeSpawnFake(CANNED_WRAP);
  decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn });
  assert.strictEqual(calls.length, 1, "spawnFn must be called to capture the child env");
  return calls[0].env;
}

function auditOpts() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rtk-audit-"));
  const logPath = path.join(dir, "guard.log");
  return { logPath, lockPath: logPath + ".lock" };
}

// G-a: agents-framework emitters.
const G_A_PASS = [
  'node "$AGENTS_MAIN_ROOT/bin/next-step" --advance',
  "$AGENTS_MAIN_ROOT/bin/get-config-var --is-off CODEGRAPH off",
];

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

// G-d: shell builtins / assignments (C5: alias/typeset widened per #2345).
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
  "alias ll='ls -la'",
  "typeset -i count",
];

// C4-RTK: anti-double-wrap (isRtkSelf).
const C4_PASS = [
  "rtk gain",
  '"rtk" recall foo',
  "env RTK_DEBUG=1 rtk gain",
];

// C3 — substituteRtkHead (quote-aware, table-driven).
const SUBST_CASES = [
  { name: "bare rtk", cmd: "rtk git status", bin: "/usr/local/bin/rtk", platform: "linux",
    want: "/usr/local/bin/rtk git status" },
  { name: "unquoted full path rtk", cmd: "/usr/bin/rtk git status", bin: "/usr/local/bin/rtk", platform: "linux",
    want: "/usr/local/bin/rtk git status" },
  { name: "quoted spaced full path rtk (win32)", cmd: '"C:\\Program Files\\rtk\\rtk.exe" git status',
    bin: "C:\\tools\\rtk.exe", platform: "win32", want: '"C:/tools/rtk.exe" git status' },
  { name: "leading token not rtk (bare git)", cmd: "git status", bin: "/usr/local/bin/rtk", platform: "linux",
    want: "git status" },
  { name: "leading token not rtk (quoted git.exe win32)", cmd: '"C:\\Program Files\\git\\git.exe" status',
    bin: "C:\\tools\\rtk.exe", platform: "win32", want: '"C:\\Program Files\\git\\git.exe" status' },
  { name: "win32 quoting of spaced rtkBin", cmd: "rtk gain", bin: "C:\\Program Files\\rtk\\rtk.exe",
    platform: "win32", want: '"C:/Program Files/rtk/rtk.exe" gain' },
];

// quoteBin — table-driven (migrated from the removed buildRtkCommand unit).
const QUOTEBIN_CASES = [
  { name: "posix plain absolute", bin: "/fake/rtk", platform: "linux", want: "/fake/rtk" },
  { name: "posix plain name", bin: "rtk", platform: "linux", want: "rtk" },
  { name: "posix with space", bin: "/fa ke/rtk", platform: "linux", want: '"/fa ke/rtk"' },
  { name: "win32 with backslash", bin: "C:\\tools\\rtk.exe", platform: "win32", want: '"C:/tools/rtk.exe"' },
  { name: "win32 with space", bin: "C:\\Program Files\\rtk.exe", platform: "win32", want: '"C:/Program Files/rtk.exe"' },
  { name: "win32 plain (no space/backslash)", bin: "rtk.exe", platform: "win32", want: "rtk.exe" },
];

// C4 — bash/sh basename passthrough (table-driven; pass AND wrap verdicts).
const C4_BASH_CASES = [
  { name: "/bin/bash -c", cmd: '/bin/bash -c "echo x"', verdict: "pass" },
  { name: "/usr/bin/sh -c", cmd: '/usr/bin/sh -c "git status"', verdict: "pass" },
  { name: "bash.exe -c", cmd: 'bash.exe -c "echo x"', verdict: "pass" },
  { name: "env /bin/bash -c", cmd: 'env /bin/bash -c "echo x"', verdict: "pass" },
  { name: "bash script.sh (no -c) still wraps", cmd: "bash script.sh", verdict: "wrap" },
];

// C7 — Audit per-guard table (G-a..G-d).
const AUDIT_GUARD_TABLE = [
  { name: "G-a agents-emit", cmd: `node "${process.env.AGENTS_MAIN_ROOT.replace(/\\/g, "/")}/bin/get-config-var"` },
  { name: "G-b machine-readable", cmd: "git rev-parse HEAD" },
  { name: "G-c composite", cmd: "git status | cat" },
  { name: "G-d shell-builtin", cmd: "declare -A map" },
];

module.exports = {
  decide, substituteRtkHead, quoteBin,
  CANNED_WRAP, cannedSpawn, makeSpawnFake, OPTS, expectPass, expectWrap,
  withParentAudit, captureChildEnv, auditOpts,
  G_A_PASS, G_B_PASS, G_C_PASS, G_D_PASS, C4_PASS,
  SUBST_CASES, QUOTEBIN_CASES, C4_BASH_CASES, AUDIT_GUARD_TABLE,
};
