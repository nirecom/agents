#!/usr/bin/env node
"use strict";
// Tests: hooks/rtk-rewrite.js, hooks/lib/rtk-guard-audit.js
// Tags: scope:issue-specific, rtk, rewrite, hook, guard
// tests/hooks/feature-2326-rtk-rewrite.js
// node:test cases for the rtk-rewrite decision pipeline + four guards.
// Covers delegation, quote-aware head substitution, the widened
// bash/sh+interpreter+env guards and the audit toggle; regression groups stay
// green. spawnFn is injected so no real `rtk hook claude` child starts.
// Spec: detail plan §5. Helpers and data tables: ./feature-2326-rtk-rewrite/fixture.js.

const { caseBegin, caseEnd } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");
const fs = require("fs");
const assert = require("assert");

const X = require("./feature-2326-rtk-rewrite/fixture");
const { decide, substituteRtkHead, quoteBin, CANNED_WRAP, cannedSpawn, makeSpawnFake, OPTS,
  expectPass, expectWrap, withParentAudit, captureChildEnv, auditOpts } = X;

let pass = 0;
let fail = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS: ${name}`); pass++; }
  catch (e) { console.log(`FAIL: ${name} — ${e.message}`); fail++; }
}
const failures = () => fail;
after(() => console.log(`PASS=${pass} FAIL=${fail}`));

// --- Regression groups — must stay green against the current source. ---

caseBegin("g-a-agents-emit-passthrough", "hooks/rtk-rewrite.js");
test("G-a agents-framework emitters", () => noNewFailures(failures, () => {
  for (const c of X.G_A_PASS) check(`G-a passthrough: ${c}`, () => expectPass(c));
  check("G-a does not swallow plain git status", () => expectWrap("git status"));
}));
caseEnd();

caseBegin("g-b-machine-readable-passthrough", "hooks/rtk-rewrite.js");
test("G-b machine-readable output", () => noNewFailures(failures, () => {
  for (const c of X.G_B_PASS) check(`G-b passthrough: ${c}`, () => expectPass(c));
  check("G-b non-plumbing/non-machine wraps: git -C . log --oneline", () => expectWrap("git -C . log --oneline"));
}));
caseEnd();

caseBegin("g-c-composite-passthrough", "hooks/rtk-rewrite.js");
test("G-c composite / redirect / substitution", () => noNewFailures(failures, () => {
  for (const c of X.G_C_PASS) check(`G-c passthrough: ${c}`, () => expectPass(c));
}));
caseEnd();

caseBegin("g-d-shell-builtin-passthrough", "hooks/rtk-rewrite.js");
test("G-d shell builtins / assignments", () => noNewFailures(failures, () => {
  for (const c of X.G_D_PASS) check(`G-d passthrough: ${c}`, () => expectPass(c));
}));
caseEnd();

caseBegin("c4-rtk-anti-double-wrap", "hooks/rtk-rewrite.js");
test("C4-RTK anti-double-wrap (isRtkSelf)", () => noNewFailures(failures, () => {
  for (const c of X.C4_PASS) check(`C4-RTK passthrough: ${c}`, () => expectPass(c));
}));
caseEnd();

caseBegin("rtk-off-and-non-bash-passthrough", "hooks/rtk-rewrite.js");
test("RTK=off and non-Bash passthrough", () => noNewFailures(failures, () => {
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
  check("non-Bash tool → passthrough", () => {
    assert.deepStrictEqual(
      decide({ tool_name: "Edit", tool_input: { command: "git status" } }, OPTS),
      {},
    );
  });
}));
caseEnd();

// --- Delegation (#2356) — inject opts.spawnFn fake. ---
const delegate = (canned) => decide({ tool_name: "Bash", tool_input: { command: "git status" } },
  { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: makeSpawnFake(canned).fn, auditOn: false });

caseBegin("delegation-spawns-rtk-hook", "hooks/rtk-rewrite.js");
test("delegation spawns rtk hook claude and passes its output through", () => noNewFailures(failures, () => {
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
    const out = delegate({ hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "canned out" } } });
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
    assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "canned out");
  });
  // Replaces the old positive-wrap test (asserted "/fake/rtk git status");
  // delegation makes the wrapped command come from the RTK hook.
  check("positive delegation: full guard-pass returns RTK canned wrap output", () => {
    const out = delegate({ hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "canned rtk wrapped" } } });
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
    assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "canned rtk wrapped");
  });
  // bare-`rtk` head in RTK output → substituted to quoted rtkBin, via delegate.
  check("delegation: bare-rtk head in RTK output → substituted to rtkBin", () => {
    const out = delegate({ hookSpecificOutput: { permissionDecision: "allow", updatedInput: { command: "rtk git status" } } });
    assert.strictEqual(out.hookSpecificOutput.updatedInput.command, "/fake/rtk git status");
  });
}));
caseEnd();

caseBegin("c1-rtk-hook-audit-child-env", "hooks/rtk-rewrite.js");
test("C1 RTK_HOOK_AUDIT env inheritance in the delegated child env", () => noNewFailures(failures, () => {
  check("C1: parent RTK_HOOK_AUDIT=1 & auditOn=false → deleted from child env", () => {
    withParentAudit("1", () => {
      const env = captureChildEnv(false);
      assert.ok(env, "child env must be provided to spawn");
      assert.strictEqual(env.RTK_HOOK_AUDIT, undefined);
    });
  });
  check("C1: parent RTK_HOOK_AUDIT=1 & auditOn=true → '1'", () => {
    withParentAudit("1", () => assert.strictEqual(captureChildEnv(true).RTK_HOOK_AUDIT, "1"));
  });
  check("C1: parent unset & auditOn=true → '1'", () => {
    withParentAudit(undefined, () => assert.strictEqual(captureChildEnv(true).RTK_HOOK_AUDIT, "1"));
  });
  check("C1: parent unset & auditOn=false → undefined", () => {
    withParentAudit(undefined, () => assert.strictEqual(captureChildEnv(false).RTK_HOOK_AUDIT, undefined));
  });
}));
caseEnd();

caseBegin("delegation-passes-through-rtk-decisions","hooks/rtk-rewrite.js");
test("C1 supplementary: RTK deny / ask / no-update outputs passed through", () => noNewFailures(failures, () => {
  check("delegation: RTK deny output passed through", () => {
    const out = delegate({ hookSpecificOutput: { permissionDecision: "deny", message: "blocked" } });
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "deny");
  });
  check("delegation: RTK ask output passed through", () => {
    const out = delegate({ hookSpecificOutput: { permissionDecision: "ask", message: "please confirm" } });
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "ask");
  });
  check("delegation: RTK allow with no updatedInput passed through", () => {
    const out = delegate({ hookSpecificOutput: { permissionDecision: "allow" } });
    assert.strictEqual(out.hookSpecificOutput.permissionDecision, "allow");
    assert.ok(!out.hookSpecificOutput.updatedInput, "no updatedInput when RTK omits it");
  });
}));
caseEnd();

caseBegin("delegation-fail-open", "hooks/rtk-rewrite.js");
test("C4 supplementary: delegation failure-paths are fail-open (no throw)", () => noNewFailures(failures, () => {
  const noThrow = (fn) => assert.doesNotThrow(() =>
    decide({ tool_name: "Bash", tool_input: { command: "git status" } },
      { rtkOn: true, rtkBin: "/fake/rtk", spawnFn: fn, auditOn: false }));
  check("delegation fail-open: spawn error → does not throw", () =>
    noThrow(() => ({ status: null, stdout: "", stderr: "", error: new Error("spawn ENOENT") })));
  check("delegation fail-open: non-zero exit status → does not throw", () =>
    noThrow(() => ({ status: 1, stdout: "", stderr: "rtk error", error: null })));
  check("delegation fail-open: malformed stdout → does not throw", () =>
    noThrow(() => ({ status: 0, stdout: "NOT JSON at all", stderr: "", error: null })));
  check("delegation fail-open: missing hookSpecificOutput → does not throw", () =>
    noThrow(() => ({ status: 0, stdout: JSON.stringify({ unrelated: true }), stderr: "", error: null })));
}));
caseEnd();

caseBegin("substitute-rtk-head-table", "hooks/rtk-rewrite.js");
test("C3 substituteRtkHead (quote-aware, table-driven)", () => noNewFailures(failures, () => {
  for (const c of X.SUBST_CASES) {
    check(`substituteRtkHead: ${c.name}`, () => {
      assert.strictEqual(substituteRtkHead(c.cmd, c.bin, c.platform), c.want,
        `substituteRtkHead mismatch for case: ${c.name}`);
    });
  }
}));
caseEnd();

caseBegin("quote-bin-table", "hooks/rtk-rewrite.js");
test("quoteBin table", () => noNewFailures(failures, () => {
  for (const c of X.QUOTEBIN_CASES) {
    check(`quoteBin: ${c.name}`, () => {
      assert.strictEqual(quoteBin(c.bin, c.platform), c.want, `quoteBin mismatch for case: ${c.name}`);
    });
  }
}));
caseEnd();

caseBegin("c4-bash-sh-basename-passthrough", "hooks/rtk-rewrite.js");
test("C4 bash/sh basename passthrough (pass AND wrap verdicts)", () => noNewFailures(failures, () => {
  for (const c of X.C4_BASH_CASES) {
    check(`C4-bash ${c.verdict}: ${c.name}`, () => {
      if (c.verdict === "pass") expectPass(c.cmd);
      else expectWrap(c.cmd);
    });
  }
}));
caseEnd();

caseBegin("abs-interpreter-agents-script-2346", "hooks/rtk-rewrite.js");
test("#2346 absolute-path interpreter running an agents script", () => noNewFailures(failures, () => {
  const AGENTS_POSIX = process.env.AGENTS_MAIN_ROOT.replace(/\\/g, "/");
  const AGENTS_SCRIPT = `${AGENTS_POSIX}/bin/get-config-var`; // real file under agents/bin
  check("#2346: /usr/bin/node <agents-abs-script> → passthrough", () => expectPass(`/usr/bin/node ${AGENTS_SCRIPT}`));
  check("#2346: /usr/bin/node with $AGENTS_MAIN_ROOT ref → passthrough", () => expectPass("/usr/bin/node $AGENTS_MAIN_ROOT/bin/next-step"));
  check("#2346: /usr/bin/node /tmp/x.js (non-agents abs script) still wraps", () => expectWrap("/usr/bin/node /tmp/x.js"));
}));
caseEnd();

caseBegin("abs-env-head-peeled-2350", "hooks/rtk-rewrite.js");
test("#2350 absolute-path env head peeled like bare env", () => noNewFailures(failures, () => {
  // Inner is machine-readable so peeling flips wrap→passthrough (distinguishing).
  check("#2350: bare env peels (machine-readable inner) → passthrough [reference]", () => expectPass("env VAR=1 git rev-parse HEAD"));
  check("#2350: /usr/bin/env VAR=1 git rev-parse HEAD → passthrough", () => expectPass("/usr/bin/env VAR=1 git rev-parse HEAD"));
  check("#2350: env.exe VAR=1 git rev-parse HEAD → passthrough", () => expectPass("env.exe VAR=1 git rev-parse HEAD"));
  // #2350 per-guard: absolute-path env peeling covers additional guards (C6).
  check("#2350 per-guard: /usr/bin/env agents-emit → passthrough (G-a)", () => {
    const adir = process.env.AGENTS_MAIN_ROOT.replace(/\\/g, "/");
    expectPass(`/usr/bin/env DEBUG=1 node "${adir}/bin/get-config-var"`);
  });
  check("#2350 per-guard: /usr/bin/env composite → passthrough (G-c)", () => expectPass("/usr/bin/env FOO=1 git status | cat"));
  check("#2350 per-guard: /usr/bin/env shell-builtin → passthrough (G-d)", () => expectPass("/usr/bin/env PAGER=cat declare -A map"));
}));
caseEnd();

caseBegin("audit-toggle", "hooks/lib/rtk-guard-audit.js");
test("Toggle (#2): audit writer gated by auditOn; delegation independent", () => noNewFailures(failures, () => {
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
}));
caseEnd();

caseBegin("c7-audit-per-guard", "hooks/lib/rtk-guard-audit.js");
test("C7 audit per-guard table and delegate no-audit", () => noNewFailures(failures, () => {
  for (const c of X.AUDIT_GUARD_TABLE) {
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
}));
caseEnd();

// isRtkSelf integrity (OPTIONAL) — delegate-shaped rtk command → passthrough.
caseBegin("is-rtk-self-integrity", "hooks/rtk-rewrite.js");
test("isRtkSelf integrity", () => noNewFailures(failures, () => {
  check("isRtkSelf: re-feeding an rtk-headed command → passthrough (no double wrap)", () => expectPass("rtk git status"));
}));
caseEnd();
