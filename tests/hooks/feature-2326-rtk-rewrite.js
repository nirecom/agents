#!/usr/bin/env node
"use strict";
// tests/hooks/feature-2326-rtk-rewrite.js
// No-framework Node tests for the rtk-rewrite decision pipeline + four guards.
// TEST-FIRST (#2356): delegation, quote-aware head substitution, widened
// bash/sh+interpreter+env guards and the audit toggle are NOT yet implemented,
// so new-behavior cases fail RED; regression groups stay green. spawnFn is
// injected so no real `rtk hook claude` child starts. Spec: detail plan §5.

const path = require("path");
const os = require("os");
const fs = require("fs");
const assert = require("assert");

// isAgentsEmit needs AGENTS_CONFIG_DIR; pin it to this worktree's agents root.
process.env.AGENTS_CONFIG_DIR = path.join(__dirname, "..", "..");
delete process.env.CLAUDE_SESSION_ID;
delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.CLAUDE_ENV_FILE;

const HOOK = path.join(__dirname, "..", "..", "hooks", "rtk-rewrite.js");
// substituteRtkHead / quoteBin are new exports (undefined until implemented).
const { decide, substituteRtkHead, quoteBin } = require(HOOK);

let pass = 0;
let fail = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS: ${name}`); pass++; }
  catch (e) { console.log(`FAIL: ${name} — ${e.message}`); fail++; }
}

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

// --- Regression groups — must stay green against the current source. ---

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
for (const c of G_D_PASS) check(`G-d passthrough: ${c}`, () => expectPass(c));

// C4-RTK: anti-double-wrap (isRtkSelf).
const C4_PASS = [
  "rtk gain",
  '"rtk" recall foo',
  "env RTK_DEBUG=1 rtk gain",
];
for (const c of C4_PASS) check(`C4-RTK passthrough: ${c}`, () => expectPass(c));

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

// --- Delegation (#2356) — inject opts.spawnFn fake. ---

// (a) full guard-pass → spawn(rtkBin,["hook","claude"],…) with payload = JSON(input).
check("delegation: spawn rtk hook claude once with input payload = JSON(input)", () => {
  const { fn, calls } = makeSpawnFake(CANNED_WRAP);
  const input = { tool_name: "Bash", tool_input: { command: "git status" } };
  decide(input, { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(calls.length, 1, "spawnFn must be called exactly once on full guard-pass");
  assert.strictEqual(calls[0].bin, "/fake/rtk");
  assert.deepStrictEqual(calls[0].args, ["hook", "claude"]);
  assert.deepStrictEqual(JSON.parse(calls[0].input), input,
    "stdin payload must be JSON of the original input");
});

// (b) fake's returned hookSpecificOutput is passed through unchanged.
check("delegation: canned hookSpecificOutput is passed through", () => {
  const canned = {
    hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "canned out" } },
  };
  const { fn } = makeSpawnFake(canned);
  const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "canned out");
});

// Replaces the old positive-wrap test (asserted "/fake/rtk git status");
// delegation makes the wrapped command come from the RTK hook.
check("positive delegation: full guard-pass returns RTK canned wrap output", () => {
  const canned = {
    hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "canned rtk wrapped" } },
  };
  const { fn } = makeSpawnFake(canned);
  const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "canned rtk wrapped");
});

// bare-`rtk` head in RTK output → substituted to quoted rtkBin, via delegate.
check("delegation: bare-rtk head in RTK output → substituted to rtkBin", () => {
  const canned = {
    hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "rtk git status" } },
  };
  const { fn } = makeSpawnFake(canned);
  const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "/fake/rtk git status");
});

// --- C1 — RTK_HOOK_AUDIT env inheritance in the delegated child env. ---
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
check("C1: parent RTK_HOOK_AUDIT=1 & auditOn=false → deleted from child env", () => {
  withParentAudit("1", () => {
    const env = captureChildEnv(false);
    assert.ok(env, "child env must be provided to spawn");
    assert.strictEqual(env.RTK_HOOK_AUDIT, undefined);
  });
});
check("C1: parent RTK_HOOK_AUDIT=1 & auditOn=true → '1'", () => {
  withParentAudit("1", () => {
    assert.strictEqual(captureChildEnv(true).RTK_HOOK_AUDIT, "1");
  });
});
check("C1: parent unset & auditOn=true → '1'", () => {
  withParentAudit(undefined, () => {
    assert.strictEqual(captureChildEnv(true).RTK_HOOK_AUDIT, "1");
  });
});
check("C1: parent unset & auditOn=false → undefined", () => {
  withParentAudit(undefined, () => {
    assert.strictEqual(captureChildEnv(false).RTK_HOOK_AUDIT, undefined);
  });
});

// --- C1 supplementary: RTK deny / ask / no-update outputs passed through. ---
check("delegation: RTK deny output passed through", () => {
  const canned = { hookSpecificOutput: { permissionDecision: "deny", message: "blocked" } };
  const { fn } = makeSpawnFake(canned);
  const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "deny");
});
check("delegation: RTK ask output passed through", () => {
  const canned = { hookSpecificOutput: { permissionDecision: "ask", message: "please confirm" } };
  const { fn } = makeSpawnFake(canned);
  const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
});
check("delegation: RTK allow with no updatedInput passed through", () => {
  const canned = { hookSpecificOutput: { permissionDecision: "allow" } };
  const { fn } = makeSpawnFake(canned);
  const out = decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
  assert.ok(!out.hookSpecificOutput.updatedInput, "no updatedInput when RTK omits it");
});

// --- C4 supplementary: delegation failure-paths are fail-open (no throw). ---
check("delegation fail-open: spawn error → does not throw", () => {
  const fn = () => ({ status: null, stdout: "", stderr: "", error: new Error("spawn ENOENT") });
  assert.doesNotThrow(() =>
    decide({ tool_name: "Bash", tool_input: { command: "git status" } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false }));
});
check("delegation fail-open: non-zero exit status → does not throw", () => {
  const fn = () => ({ status: 1, stdout: "", stderr: "rtk error", error: null });
  assert.doesNotThrow(() =>
    decide({ tool_name: "Bash", tool_input: { command: "git status" } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false }));
});
check("delegation fail-open: malformed stdout → does not throw", () => {
  const fn = () => ({ status: 0, stdout: "NOT JSON at all", stderr: "", error: null });
  assert.doesNotThrow(() =>
    decide({ tool_name: "Bash", tool_input: { command: "git status" } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false }));
});
check("delegation fail-open: missing hookSpecificOutput → does not throw", () => {
  const fn = () => ({ status: 0, stdout: JSON.stringify({ unrelated: true }), stderr: "", error: null });
  assert.doesNotThrow(() =>
    decide({ tool_name: "Bash", tool_input: { command: "git status" } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false }));
});

// --- C3 — substituteRtkHead (quote-aware, table-driven). ---
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
for (const c of SUBST_CASES) {
  check(`substituteRtkHead: ${c.name}`, () => {
    assert.strictEqual(substituteRtkHead(c.cmd, c.bin, c.platform), c.want,
      `substituteRtkHead mismatch for case: ${c.name}`);
  });
}

// --- quoteBin — table-driven (migrated from the removed buildRtkCommand unit). ---
const QUOTEBIN_CASES = [
  { name: "posix plain absolute", bin: "/fake/rtk", platform: "linux", want: "/fake/rtk" },
  { name: "posix plain name", bin: "rtk", platform: "linux", want: "rtk" },
  { name: "posix with space", bin: "/fa ke/rtk", platform: "linux", want: '"/fa ke/rtk"' },
  { name: "win32 with backslash", bin: "C:\\tools\\rtk.exe", platform: "win32", want: '"C:/tools/rtk.exe"' },
  { name: "win32 with space", bin: "C:\\Program Files\\rtk.exe", platform: "win32", want: '"C:/Program Files/rtk.exe"' },
  { name: "win32 plain (no space/backslash)", bin: "rtk.exe", platform: "win32", want: "rtk.exe" },
];
for (const c of QUOTEBIN_CASES) {
  check(`quoteBin: ${c.name}`, () => {
    assert.strictEqual(quoteBin(c.bin, c.platform), c.want, `quoteBin mismatch for case: ${c.name}`);
  });
}

// --- C4 — bash/sh basename passthrough (table-driven; pass AND wrap verdicts). ---
const C4_BASH_CASES = [
  { name: "/bin/bash -c", cmd: '/bin/bash -c "echo x"', verdict: "pass" },
  { name: "/usr/bin/sh -c", cmd: '/usr/bin/sh -c "git status"', verdict: "pass" },
  { name: "bash.exe -c", cmd: 'bash.exe -c "echo x"', verdict: "pass" },
  { name: "env /bin/bash -c", cmd: 'env /bin/bash -c "echo x"', verdict: "pass" },
  { name: "bash script.sh (no -c) still wraps", cmd: "bash script.sh", verdict: "wrap" },
];
for (const c of C4_BASH_CASES) {
  check(`C4-bash ${c.verdict}: ${c.name}`, () => {
    if (c.verdict === "pass") expectPass(c.cmd);
    else expectWrap(c.cmd);
  });
}

// --- #2346 — absolute-path interpreter running an agents script. ---
const AGENTS_POSIX = process.env.AGENTS_CONFIG_DIR.replace(/\\/g, "/");
const AGENTS_SCRIPT = `${AGENTS_POSIX}/bin/get-config-var`; // real file under agents/bin
check("#2346: /usr/bin/node <agents-abs-script> → passthrough", () => {
  expectPass(`/usr/bin/node ${AGENTS_SCRIPT}`);
});
check("#2346: /usr/bin/node with $AGENTS_CONFIG_DIR ref → passthrough", () => {
  expectPass("/usr/bin/node $AGENTS_CONFIG_DIR/bin/next-step");
});
check("#2346: /usr/bin/node /tmp/x.js (non-agents abs script) still wraps", () => {
  expectWrap("/usr/bin/node /tmp/x.js");
});

// --- #2350 residual — absolute-path env head peeled like bare env. ---
// Inner is machine-readable so peeling flips wrap→passthrough (distinguishing).
check("#2350: bare env peels (machine-readable inner) → passthrough [reference]", () => {
  expectPass("env VAR=1 git rev-parse HEAD");
});
check("#2350: /usr/bin/env VAR=1 git rev-parse HEAD → passthrough", () => {
  expectPass("/usr/bin/env VAR=1 git rev-parse HEAD");
});
check("#2350: env.exe VAR=1 git rev-parse HEAD → passthrough", () => {
  expectPass("env.exe VAR=1 git rev-parse HEAD");
});
// #2350 per-guard: absolute-path env peeling covers additional guards (C6).
check("#2350 per-guard: /usr/bin/env agents-emit → passthrough (G-a)", () => {
  const adir = process.env.AGENTS_CONFIG_DIR.replace(/\\/g, "/");
  expectPass(`/usr/bin/env DEBUG=1 node "${adir}/bin/get-config-var"`);
});
check("#2350 per-guard: /usr/bin/env composite → passthrough (G-c)", () => {
  expectPass("/usr/bin/env FOO=1 git status | cat");
});
check("#2350 per-guard: /usr/bin/env shell-builtin → passthrough (G-d)", () => {
  expectPass("/usr/bin/env PAGER=cat declare -A map");
});

// --- Toggle (#2) — audit writer gated by auditOn; delegation independent. ---
function auditOpts() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rtk-audit-"));
  const logPath = path.join(dir, "guard.log");
  return { logPath, lockPath: logPath + ".lock" };
}
check("toggle: auditOn=true → guard reject recorded to injected logPath", () => {
  const ao = auditOpts();
  const out = decide({ tool_name: "Bash", tool_input: { command: "git rev-parse HEAD" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: cannedSpawn, auditOn: true, auditOpts: ao });
  assert.deepStrictEqual(out, {}, "machine-readable command must passthrough");
  assert.ok(fs.existsSync(ao.logPath), "audit log must be written when auditOn=true");
  const lines = fs.readFileSync(ao.logPath, "utf8").split(/\n/).filter(Boolean);
  assert.strictEqual(lines.length, 1, "exactly one audit line");
  const rec = JSON.parse(lines[0]);
  assert.strictEqual(rec.action, "reject");
  assert.ok(rec.guard, "guard name recorded");
  assert.ok(rec.command.includes("rev-parse"), "original command recorded");
});
check("toggle: RTK=on & RTK_AUDIT=off → passthrough with NO audit write", () => {
  const ao = auditOpts();
  const out = decide({ tool_name: "Bash", tool_input: { command: "git rev-parse HEAD" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: cannedSpawn, auditOn: false, auditOpts: ao });
  assert.deepStrictEqual(out, {}, "machine-readable command must passthrough");
  assert.ok(!fs.existsSync(ao.logPath), "no audit log when auditOn=false");
});
check("toggle: RTK_AUDIT=off still delegates and drops RTK_HOOK_AUDIT", () => {
  const { fn, calls } = makeSpawnFake(CANNED_WRAP);
  withParentAudit("1", () => {
    decide({ tool_name: "Bash", tool_input: { command: "git status" } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false });
  });
  assert.strictEqual(calls.length, 1, "delegation must occur regardless of the audit toggle");
  assert.strictEqual(calls[0].env.RTK_HOOK_AUDIT, undefined);
});

// --- C7 — Audit per-guard table (G-a..G-d) and delegate no-audit. ---
const AUDIT_GUARD_TABLE = [
  { name: "G-a agents-emit", cmd: `node "${process.env.AGENTS_CONFIG_DIR.replace(/\\/g, "/")}/bin/get-config-var"` },
  { name: "G-b machine-readable", cmd: "git rev-parse HEAD" },
  { name: "G-c composite", cmd: "git status | cat" },
  { name: "G-d shell-builtin", cmd: "declare -A map" },
];
for (const c of AUDIT_GUARD_TABLE) {
  check(`C7 audit per-guard: ${c.name} → audit log written when auditOn=true`, () => {
    const ao = auditOpts();
    decide({ tool_name: "Bash", tool_input: { command: c.cmd } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: cannedSpawn, auditOn: true, auditOpts: ao });
    assert.ok(fs.existsSync(ao.logPath),
      `audit log must be written for guard-rejected command (${c.name})`);
  });
}
check("C7 audit: delegation (guard-pass) does NOT write audit log", () => {
  const ao = auditOpts();
  const { fn } = makeSpawnFake(CANNED_WRAP);
  decide({ tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: true, auditOpts: ao });
  assert.ok(!fs.existsSync(ao.logPath),
    "no audit write when command reaches delegation (no agent guard rejected it)");
});

// --- isRtkSelf integrity (OPTIONAL) — delegate-shaped rtk command → passthrough. ---
check("isRtkSelf: re-feeding an rtk-headed command → passthrough (no double wrap)", () => {
  expectPass("rtk git status");
});

console.log("----");
console.log(`PASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
