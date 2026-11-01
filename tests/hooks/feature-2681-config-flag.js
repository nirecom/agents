"use strict";
// Tests: hooks/lib/config-flag.js, hooks/lib/confirm-gate/probe.js, hooks/rtk-rewrite.js
// Tags: TL1, hooks, config-flag, confirm-gate, probe, rtk, in-process, env-restore, scope:issue-specific
// #2681: config flags resolve in-process through hooks/lib/config-flag.js. Pins the kind table,
// the failure causes, the process.env restore on every path, the stderr policy, runCli's output,
// the probe causes (over-budget included), no subprocess on the node path, the rtk toggles (and
// decide() reading them when rtkOn / auditOn are left out), and
// the cwd .env.local overlay. Each variant runs from its own copied hooks/ tree (cf-fixture.js).
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./feature-2681-config-flag/cf-fixture");

// Count every subprocess start from here on; only the no-spawn case reads the count. Installed
// before any tree module loads, so a module that destructures these at load time sees the wrapper.
let spawnCount = 0;
let counting = false;
for (const fn of ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"]) {
  const orig = cp[fn];
  cp[fn] = function counted(...args) {
    if (counting) spawnCount++;
    return orig.apply(this, args);
  };
}

const restoreIsolation = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2681-cf-"));
const CFG = path.join(ROOT, "cfg");
const NEUTRAL = path.join(ROOT, "cwd");
const TREES = path.join(ROOT, "trees");
fs.mkdirSync(CFG);
fs.mkdirSync(NEUTRAL);
const HOME_CWD = process.cwd();
process.chdir(NEUTRAL);
process.env.AGENTS_MAIN_ROOT = CFG;
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "CONFIRM_TESTS", "CONFIRM_CODE", "RTK", "RTK_AUDIT", "AGENTS_HOOK_DEBUG"]) {
  delete process.env[k];
}
const writeEnv = (text) => fs.writeFileSync(path.join(CFG, ".env"), text);
writeEnv("");

let PASS = 0;
let FAIL = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS: ${name}`);
    PASS++;
  } catch (e) {
    console.log(`FAIL: ${name} — ${String(e && e.message).split("\n")[0]}`);
    FAIL++;
  }
}
const failures = () => FAIL;
after(() => {
  process.chdir(HOME_CWD);
  restoreIsolation();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
  console.log(`\nTotal: ${PASS} passed, ${FAIL} failed`);
});

const T = {};
for (const v of ["real", "throw-on-require", "throw-on-call", "load-failed", "inject-then-throw", "inject-then-load-failed", "slow", "slow-load-failed", "throw-for-CONFIRM_CODE"]) {
  T[v] = F.mkTree(TREES, v);
}
// A second unstubbed tree whose modules first load inside the no-spawn case.
T.nospawn = F.mkTree(path.join(ROOT, "trees-nospawn"), "real");
const CF = (v) => F.load(T[v], "hooks/lib/config-flag.js");
const PROBE = (v) => F.load(T[v], "hooks/lib/confirm-gate/probe.js");
const classify = (v, name, def) => F.need(CF(v), "classifyConfigFlag")(name, def);
const kv = (r) => `${r && r.kind}/${r && r.cause}`;
const cli = (v, mode, name, def) => F.capture(() => F.need(CF(v), "runCli")({ mode, name, defaultValue: def, repoRoot: "" }));
const withCause = (v, key, budget) => F.need(PROBE(v), "probeConfirmGateWithCause")(key, budget);
const vc = (r) => `${r && r.value}/${r && r.cause}`;
// Each case's .env writes run inside its test body: node:test defers bodies until after load.
let RTK = null;

caseBegin("kind-table", "hooks/lib/config-flag.js");
test("kind-table", () => noNewFailures(failures, () => {
  writeEnv("CF_A=off\nCF_B=OFF\nCF_C=on\nCF_D=On\nCF_E=maybe\nCF_I=off\n");
  for (const [key, def, want] of [["CF_A", "", "off"], ["CF_B", "", "off"], ["CF_C", "", "on"], ["CF_D", "", "on"], ["CF_E", "", "unrecognized"], ["CF_F", "", "unset"], ["CF_G", "on", "on"]]) {
    check(`${key} (default '${def}') -> ${want}`, () => assert.strictEqual(kv(classify("real", key, def)), `${want}/null`));
  }
  check("export 'off\\n' classifies as off, value kept raw", () => {
    const r = F.withEnv({ CF_H: "off\n" }, () => classify("real", "CF_H", ""));
    assert.deepStrictEqual([r.kind, r.value], ["off", "off\n"]);
  });
  check("export beats .env (export on, .env off)", () => {
    const r = F.withEnv({ CF_I: "on" }, () => classify("real", "CF_I", "off"));
    assert.deepStrictEqual([r.kind, r.value, r.cause], ["on", "on", null]);
  });
  // Only trailing newlines are trimmed (as shell command substitution does); spaces and \r are not.
  for (const [raw, want] of [["off ", "unrecognized"], [" off", "unrecognized"], ["off\r", "unrecognized"], ["off\n\n", "off"]]) {
    check(`export ${JSON.stringify(raw)} -> ${want}`, () =>
      assert.strictEqual(F.withEnv({ CF_BND: raw }, () => classify("real", "CF_BND", "")).kind, want));
  }
  check("KINDS is the five-word vocabulary", () =>
    assert.deepStrictEqual(F.need(CF("real"), "KINDS"), ["off", "on", "unset", "unrecognized", "failed"]));
}));
caseEnd();

caseBegin("failure-causes", "hooks/lib/config-flag.js");
test("failure-causes", () => noNewFailures(failures, () => {
  for (const v of ["throw-on-require", "throw-on-call"]) {
    check(`${v} -> failed/exception, value falls back to default`, () => {
      const r = F.withEnv({ CF_X: undefined }, () => classify(v, "CF_X", "on"));
      assert.deepStrictEqual([r.kind, r.cause, r.value], ["failed", "exception", "on"]);
    });
    check(`${v} -> value is the non-empty export when there is one`, () => {
      const r = F.withEnv({ CF_X: "exported" }, () => classify(v, "CF_X", "on"));
      assert.deepStrictEqual([r.kind, r.cause, r.value], ["failed", "exception", "exported"]);
    });
  }
  check("load-failed -> failed/load-failed", () => assert.strictEqual(kv(classify("load-failed", "CF_X", "on")), "failed/load-failed"));
}));
caseEnd();

caseBegin("verdict-of-kind", "hooks/lib/config-flag.js");
test("verdict-of-kind", () => noNewFailures(failures, () => {
  for (const [kind, want] of [["off", "OFF"], ["on", "ON"], ["unset", "ON"], ["unrecognized", "ON"], ["failed", "ERROR"], ["bogus", "ERROR"]]) {
    check(`verdictOfKind(${kind}) -> ${want}`, () => assert.strictEqual(F.need(CF("real"), "verdictOfKind")(kind), want));
  }
}));
caseEnd();

caseBegin("process-env-restored-on-every-path", "hooks/lib/config-flag.js");
test("process-env-restored-on-every-path", () => noNewFailures(failures, () => {
  writeEnv("CF_ONLY_DOTENV=from-dotenv\nCF_EXP=from-dotenv\n");
  check("normal path: process.env is unchanged, the .env-only key is not left behind", () => {
    const before = F.envSnapshot();
    const r = classify("real", "CF_ONLY_DOTENV", "");
    assert.strictEqual(r.value, "from-dotenv", "premise: the .env value was read");
    assert.strictEqual(F.envSnapshot(), before);
    assert.strictEqual(process.env.CF_ONLY_DOTENV, undefined);
  });
  check("a key the caller exported keeps its value", () => F.withEnv({ CF_EXP: "mine" }, () => {
    const r = classify("real", "CF_EXP", "");
    assert.deepStrictEqual([r.value, process.env.CF_EXP], ["mine", "mine"]);
  }));
  for (const [v, cause] of [["inject-then-throw", "exception"], ["inject-then-load-failed", "load-failed"]]) {
    check(`${v}: added, changed and removed keys are all put back; result failed/${cause}`, () =>
      F.withEnv({ CF_NEW: undefined, CF_MOD: "orig", CF_DEL: "keep" }, () => {
        const before = F.envSnapshot();
        const r = classify(v, "CF_X", "");
        assert.strictEqual(kv(r), `failed/${cause}`);
        assert.deepStrictEqual([process.env.CF_NEW, process.env.CF_MOD, process.env.CF_DEL], [undefined, "orig", "keep"]);
        assert.strictEqual(F.envSnapshot(), before);
      }));
  }
}));
caseEnd();

caseBegin("stderr-names-the-key-never-the-value", "hooks/lib/config-flag.js");
test("stderr-names-the-key-never-the-value", () => noNewFailures(failures, () => {
  writeEnv('CONFIRM_TESTS=off\nCF_SECRET="s3cr3t-value\n');
  check("unterminated quote: no throw, CONFIRM_TESTS=off, stderr names CF_SECRET without its value", () => {
    const c = F.capture(() => classify("real", "CONFIRM_TESTS", "on"));
    assert.strictEqual(c.ret.kind, "off");
    assert.ok(c.err.includes("CF_SECRET"), `stderr names the key (got: ${JSON.stringify(c.err)})`);
    assert.ok(!c.err.includes("s3cr3t-value"), "stderr never carries the value");
  });
}));
caseEnd();

caseBegin("run-cli-output", "hooks/lib/config-flag.js");
test("run-cli-output", () => noNewFailures(failures, () => {
  writeEnv("CF_V=hello\nCF_O=off\nCF_N=on\nCF_U=s3cr3t-maybe\n");
  const KIND_WARN = "get-config-var: unrecognized value for CF_U (value withheld; caller-dependent: exit 3 — see usage header for ON vs OFF handling)";
  const VERDICT_WARN = "confirm-off: unrecognized value for CF_U (value withheld; treated as ON)";
  for (const [v, mode, name, want] of [
    ["real", "value", "CF_V", "hello"], ["real", "value", "CF_MISSING", "dflt"],
    ["real", "kind", "CF_O", "off"], ["real", "kind", "CF_N", "on"], ["real", "kind", "CF_MISSING", "unset"],
    ["real", "verdict", "CF_O", "OFF"], ["real", "verdict", "CF_N", "ON"],
    ["load-failed", "kind", "CF_O", "failed load-failed"], ["load-failed", "verdict", "CF_O", "ERROR load-failed"],
    ["throw-on-call", "kind", "CF_O", "failed exception"], ["throw-on-call", "verdict", "CF_O", "ERROR exception"],
  ]) {
    const def = name === "CF_MISSING" && mode === "value" ? "dflt" : "";
    check(`runCli ${v} ${mode} ${name} -> stdout '${want}' (one token, no newline)`, () => assert.strictEqual(cli(v, mode, name, def).out, want));
  }
  check("kind mode, unrecognized: stdout 'unrecognized', stderr has the get-config-var warning, no value", () => {
    const c = cli("real", "kind", "CF_U", "");
    assert.strictEqual(c.out, "unrecognized");
    assert.ok(c.err.includes(KIND_WARN), `stderr: ${JSON.stringify(c.err)}`);
    assert.ok(!c.err.includes("s3cr3t-maybe"), "value withheld");
  });
  check("verdict mode, unrecognized: stdout 'ON', stderr has the confirm-off warning, no value", () => {
    const c = cli("real", "verdict", "CF_U", "");
    assert.strictEqual(c.out, "ON");
    assert.ok(c.err.includes(VERDICT_WARN), `stderr: ${JSON.stringify(c.err)}`);
    assert.ok(!c.err.includes("s3cr3t-maybe"), "value withheld");
  });
}));
caseEnd();

caseBegin("probe-causes", "hooks/lib/confirm-gate/probe.js");
test("probe-causes", () => noNewFailures(failures, () => {
  writeEnv("CONFIRM_TESTS=off\n");
  check("PROBE_CAUSES lists the four causes", () =>
    assert.deepStrictEqual([...F.need(PROBE("real"), "PROBE_CAUSES")].sort(), ["exception", "load-failed", "ok", "over-budget"]));
  check("real tree, .env off -> OFF/ok", () => assert.strictEqual(vc(withCause("real", "CONFIRM_TESTS", 1500)), "OFF/ok"));
  check("load-failed -> ERROR/load-failed", () => assert.strictEqual(vc(withCause("load-failed", "CONFIRM_TESTS", 1500)), "ERROR/load-failed"));
  check("throw-on-call -> ERROR/exception", () => assert.strictEqual(vc(withCause("throw-on-call", "CONFIRM_TESTS", 1500)), "ERROR/exception"));
  check("throw-on-require -> ERROR/exception", () => assert.strictEqual(vc(withCause("throw-on-require", "CONFIRM_TESTS", 1500)), "ERROR/exception"));
  check("slow resolver, budget 10 -> value kept OFF, cause over-budget", () => assert.strictEqual(vc(withCause("slow", "CONFIRM_TESTS", 10)), "OFF/over-budget"));
  check("CONFIRM_TESTS=maybe -> ON/ok (unrecognized reads as ON, not as a failure)", () =>
    assert.strictEqual(vc(F.withEnv({ CONFIRM_TESTS: "maybe" }, () => withCause("real", "CONFIRM_TESTS", 1500))), "ON/ok"));
  check("slow load failure, budget 10 -> ERROR/load-failed, never over-budget", () =>
    assert.strictEqual(vc(withCause("slow-load-failed", "CONFIRM_TESTS", 10)), "ERROR/load-failed"));
  for (const b of [0, -5, NaN, Infinity, "abc", undefined]) {
    check(`slow resolver, budget ${String(b)} -> never over-budget`, () => assert.strictEqual(vc(withCause("slow", "CONFIRM_TESTS", b)), "OFF/ok"));
  }
  check("one key failing leaves the other key resolved", () => {
    assert.strictEqual(vc(withCause("throw-for-CONFIRM_CODE", "CONFIRM_TESTS", 1500)), "OFF/ok");
    assert.strictEqual(vc(withCause("throw-for-CONFIRM_CODE", "CONFIRM_CODE", 1500)), "ERROR/exception");
  });
  check("probe.js drops buildProbeInvocation / verdictOf / VERDICTS and keeps posixJoin", () => {
    const m = PROBE("real");
    assert.deepStrictEqual([typeof m.buildProbeInvocation, typeof m.verdictOf, typeof m.VERDICTS, typeof m.posixJoin],
      ["undefined", "undefined", "undefined", "function"]);
  });
}));
caseEnd();

caseBegin("node-path-starts-no-subprocess", "hooks/lib/confirm-gate/probe.js");
test("node-path-starts-no-subprocess", () => noNewFailures(failures, () => {
  const NS_PROBE = F.load(T.nospawn, "hooks/lib/confirm-gate/probe.js");
  const NS_RTK = F.load(T.nospawn, "hooks/rtk-rewrite.js");
  // Positive control (mirrors contract.sh C6-ctrl): the counter really sees a subprocess start.
  check("control: one spawnSync while counting -> count 1", () => {
    spawnCount = 0;
    counting = true;
    try {
      cp.spawnSync(process.execPath, ["-e", ""]);
    } finally {
      counting = false;
    }
    assert.strictEqual(spawnCount, 1);
  });
  check("both probes and both rtk toggles start zero subprocesses", () => {
    spawnCount = 0;
    counting = true;
    try {
      F.need(NS_PROBE, "probeConfirmGateSync")("CONFIRM_TESTS", 1500);
      F.need(NS_PROBE, "probeConfirmGate")("CONFIRM_TESTS", 1500);
      F.need(NS_RTK, "isRtkEnabled")();
      F.need(NS_RTK, "isRtkAuditEnabled")();
    } finally {
      counting = false;
    }
    assert.strictEqual(spawnCount, 0);
  });
}));
caseEnd();

caseBegin("rtk-toggles", "hooks/rtk-rewrite.js");
test("rtk-toggles", () => noNewFailures(failures, () => {
  writeEnv("");
  RTK = F.load(T.real, "hooks/rtk-rewrite.js");
  for (const [val, want] of [["on", true], ["off", false], [undefined, false], ["garbage", false]]) {
    check(`RTK=${String(val)} -> isRtkEnabled ${want}`, () =>
      assert.strictEqual(F.withEnv({ RTK: val }, () => F.need(RTK, "isRtkEnabled")()), want));
    check(`RTK_AUDIT=${String(val)} -> isRtkAuditEnabled ${want}`, () =>
      assert.strictEqual(F.withEnv({ RTK_AUDIT: val }, () => F.need(RTK, "isRtkAuditEnabled")()), want));
  }
  const RTK_BROKEN = F.load(T["throw-on-require"], "hooks/rtk-rewrite.js");
  check("load-env throwing on require -> both toggles false", () => F.withEnv({ RTK: "on", RTK_AUDIT: "on" }, () =>
    assert.deepStrictEqual([F.need(RTK_BROKEN, "isRtkEnabled")(), F.need(RTK_BROKEN, "isRtkAuditEnabled")()], [false, false])));
  // The toggles read RTK / RTK_AUDIT from .env without leaving any other .env key in process.env.
  writeEnv("RTK=on\nRTK_AUDIT=on\nRTK_BIN=evil-rtk\nCF_SECRET=s\n");
  for (const fn of ["isRtkEnabled", "isRtkAuditEnabled"]) {
    check(`.env RTK*=on: ${fn}() true, RTK_BIN / CF_SECRET not left in process.env`, () =>
      F.withEnv({ RTK: undefined, RTK_AUDIT: undefined, RTK_BIN: undefined, CF_SECRET: undefined }, () => {
        const got = F.need(RTK, fn)();
        assert.deepStrictEqual([got, process.env.RTK_BIN, process.env.CF_SECRET], [true, undefined, undefined]);
      }));
  }
  writeEnv("");
  check("the old names loadDefaultEnv / loadAuditEnabled are gone", () =>
    assert.deepStrictEqual([typeof RTK.loadDefaultEnv, typeof RTK.loadAuditEnabled], ["undefined", "undefined"]));
}));
caseEnd();

// decide() with rtkOn / auditOn left out must fall back to the .env toggles. rtkBin, spawnFn and
// readStateFn are injected so no real rtk runs; the audit log lands under the fixture's AGENTS_STATE_DIR.
caseBegin("decide-without-rtkOn-auditOn-reads-the-toggles", "hooks/rtk-rewrite.js");
test("decide-without-rtkOn-auditOn-reads-the-toggles", () => noNewFailures(failures, () => {
  const decide = F.need(RTK, "decide");
  const AUDIT_DIR = path.join(ROOT, "agents-state");
  const AUDIT_LOG = path.join(AUDIT_DIR, "logs", "rtk-guard-audit.log");
  const bashIn = (command) => ({ tool_name: "Bash", tool_input: { command } });
  let rtkCalls = 0;
  const cannedSpawn = () => {
    rtkCalls++;
    const hso = { hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: { command: "rtk git status" } };
    return { status: 0, stdout: JSON.stringify({ hookSpecificOutput: hso }) };
  };
  const OPEN = { rtkBin: "/fake/rtk", spawnFn: cannedSpawn, readStateFn: () => null };
  const auditLines = () => {
    try { return fs.readFileSync(AUDIT_LOG, "utf8").split("\n").filter(Boolean); } catch (_e) { return []; }
  };
  const decideFresh = (envText, cmd) => {
    writeEnv(envText);
    rtkCalls = 0;
    fs.rmSync(AUDIT_DIR, { recursive: true, force: true });
    return F.withEnv({ RTK: undefined, RTK_AUDIT: undefined, AGENTS_STATE_DIR: AUDIT_DIR }, () => decide(bashIn(cmd), OPEN));
  };
  check(".env RTK=on, no rtkOn: an eligible command is rewritten to rtk", () => {
    const out = decideFresh("RTK=on\n", "git status");
    assert.strictEqual(rtkCalls, 1);
    assert.strictEqual(out.hookSpecificOutput && out.hookSpecificOutput.updatedInput.command, "/fake/rtk git status");
  });
  check(".env RTK=off, no rtkOn: passthrough, rtk never called", () => {
    assert.deepStrictEqual(decideFresh("RTK=off\n", "git status"), {});
    assert.strictEqual(rtkCalls, 0);
  });
  check(".env RTK_AUDIT=on, no auditOn: a guard-rejected command leaves one record in the fixture log", () => {
    const out = decideFresh("RTK=on\nRTK_AUDIT=on\n", "echo hi");
    assert.deepStrictEqual([out, rtkCalls], [{}, 0]);
    const lines = auditLines();
    assert.strictEqual(lines.length, 1, `audit lines: ${JSON.stringify(lines)}`);
    const rec = JSON.parse(lines[0]);
    assert.deepStrictEqual([rec.guard, rec.action, rec.command], ["shellBuiltin", "reject", "echo hi"]);
  });
  check(".env RTK_AUDIT=off control: the same rejected command leaves no record", () => {
    assert.deepStrictEqual(decideFresh("RTK=on\nRTK_AUDIT=off\n", "echo hi"), {});
    assert.strictEqual(auditLines().length, 0);
  });
  writeEnv("");
}));
caseEnd();

caseBegin("cwd-project-env-local-overlay", "hooks/lib/confirm-gate/probe.js");
test("cwd-project-env-local-overlay", () => noNewFailures(failures, () => {
  writeEnv("");
  const PROJ = path.join(ROOT, "proj");
  fs.mkdirSync(PROJ);
  gitInit(PROJ);
  fs.writeFileSync(path.join(PROJ, ".env.local"), "CONFIRM_TESTS=off\n");
  check("no CLAUDE_PROJECT_DIR: the caller cwd's .env.local turns the gate OFF", () => {
    process.chdir(PROJ);
    try {
      assert.strictEqual(vc(withCause("real", "CONFIRM_TESTS", 1500)), "OFF/ok");
    } finally {
      process.chdir(NEUTRAL);
    }
  });
}));
caseEnd();

// Async half last: probeConfirmGate must resolve to the same token the sync probe returns.
caseBegin("sync-and-async-probe-agree", "hooks/lib/confirm-gate/probe.js");
test("sync-and-async-probe-agree", () => noNewFailures(failures, async () => {
  writeEnv("CONFIRM_TESTS=off\n");
  const rows = await Promise.all([["real", "OFF"], ["load-failed", "ERROR"], ["throw-on-call", "ERROR"], ["slow", "OFF"]].map(([v, want]) => {
    let sync;
    try { sync = F.need(PROBE(v), "probeConfirmGateSync")("CONFIRM_TESTS", 1500); } catch (_e) { sync = "THREW"; }
    return Promise.resolve()
      .then(() => F.need(PROBE(v), "probeConfirmGate")("CONFIRM_TESTS", 1500))
      .catch(() => "REJECTED")
      .then((async) => [v, want, sync, async]);
  }));
  for (const [v, want, sync, asyncTok] of rows) {
    check(`${v}: sync and async both ${want}`, () => assert.deepStrictEqual([sync, asyncTok], [want, want]));
  }
}));
caseEnd();
