"use strict";
// #2650 G1-G5: the shared gate predicate planGateState (hooks/lib/confirm-gate/plan-gate.js)
// against the gate CLI (next-step --gate), confirm-checkpoint and the Stop hook.
// Usage: node gate-driver.js <G1|G2|G3|G4|G5>. Prints PASS|name / FAIL|name|detail lines.
const path = require("path");
const cp = require("child_process");

// The in-process probes this process takes (config-flag classifyConfigFlag calls on CONFIRM_*),
// and the fault that makes them fail for real (probe-fault-preload.js).
const PC = require("./probe-count-preload");
const PF = require("./probe-fault-preload");

const X = require("./fixture");
const { A, T, U, W, TR, show, check } = X;
const KEY = { intent: "CONFIRM_INTENT", outline: "CONFIRM_OUTLINE", detail: "CONFIRM_DETAIL" };
const PG = X.tryRequire("hooks/lib/confirm-gate/plan-gate.js");
const state = (stage, opts) => {
  if (PG.__missing) return "missing:" + PG.__missing;
  if (typeof PG.planGateState !== "function") return "planGateState is not exported";
  try { return PG.planGateState(stage, opts); } catch (e) { return "threw:" + e.message; }
};
// withEnv(over, fn): run fn with process.env keys set (null deletes), then restore.
function withEnv(over, fn) {
  const saved = {};
  for (const k of Object.keys(over)) { saved[k] = process.env[k]; if (over[k] === null) delete process.env[k]; else process.env[k] = over[k]; }
  try { return fn(); } finally {
    // Reverse order: on Windows process.env keys are case-insensitive (Path / PATH).
    for (const k of Object.keys(saved).reverse()) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  }
}
// A session at the stage. detail gets the outline's text, so the scope-change check finds no change.
const session = (stage) => X.sessionAt(stage, stage === "detail" ? { body: X.F.PLAN_BODY.outline } : {});

// childEnv(over, fault) -> the child env; fault (a probe-fault-preload mode) breaks its probe.
function childEnv(over, fault) {
  const env = Object.assign({}, process.env, X.gateEnv());
  delete env.CLAUDE_CODE_SESSION_ID;
  for (const k of Object.keys(over || {})) { if (over[k] === null) delete env[k]; else env[k] = over[k]; }
  return fault ? X.probeFaultEnv(env, fault) : env;
}
// cli(sid, key, over, fault) -> {action, value, cause, out}: next-step --gate for the recorded step;
// cause is the REASON's probe-<cause> suffix, null when the probe succeeded.
function cli(sid, key, over, fault) {
  const r = cp.spawnSync(process.execPath, [path.join(X.ROOT, "bin/workflow/next-step"), "--gate", "--session", sid], {
    env: childEnv(over, fault), encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  const val = (k) => { const m = new RegExp("^" + k + "=(.*)$", "m").exec(r.stdout || ""); return m ? m[1].trim() : null; };
  const cause = /probe-([a-z-]+)/.exec(val("REASON") || "");
  return { action: val("GATE_ACTION"), value: val("GATE_" + key), cause: cause ? cause[1] : null, out: (r.stdout || "") + (r.stderr || "") };
}
// checkpoint(sid, stage, over, fault) -> parsed confirm-checkpoint output for the stage's echo.
function checkpoint(sid, stage, over, fault) {
  const input = { tool_name: "Bash", tool_input: { command: X.echoOf(stage) }, session_id: sid, hook_event_name: "PreToolUse" };
  const r = cp.spawnSync(process.execPath, [path.join(X.ROOT, "hooks/confirm-checkpoint.js")], {
    input: JSON.stringify(input), env: childEnv(over, fault), encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  let json = {};
  try { json = r.stdout ? JSON.parse(r.stdout) : {}; } catch (_) { json = { unparsed: r.stdout }; }
  const msg = typeof json.systemMessage === "string" ? json.systemMessage : "";
  const hso = json.hookSpecificOutput || {};
  return { rc: r.status, json, msg, denied: hso.permissionDecision === "deny" };
}
const dialog = (c) => c.rc === 0 && c.msg !== "" && !c.msg.includes("[confirm-skipped") && !c.denied;
const skipped = (c) => c.rc === 0 && c.msg.startsWith("[confirm-skipped:");

const mode = process.argv[2];

if (mode === "G1") {
  // 3 stages x (on / off / unset / unrecognized): planGateState and the CLI action agree.
  const VALUES = [["on", "on"], ["off", "off"], ["unset", null], ["unrecognized", "maybe"]];
  for (const stage of X.STAGES) {
    const s = session(stage);
    for (const [label, v] of VALUES) {
      const want = v === "off" && stage !== "intent" ? "OFF" : "ON";
      const got = withEnv({ [KEY[stage]]: v }, () => state(stage));
      const c = cli(s.sid, KEY[stage], { [KEY[stage]]: v });
      const wantAction = want === "OFF" ? "proceed" : "ask";
      check(`G1 ${stage} ${label}: planGateState is ${want}`, got === want, show(got));
      // The value line stays the raw flag (intent off prints OFF and still asks); the action is the contract.
      check(`G1 ${stage} ${label}: the CLI action is ${wantAction}`, c.action === wantAction, show([c.value, c.action, c.out]));
      check(`G1 ${stage} ${label}: planGateState agrees with the CLI action`,
        (got === "OFF" ? "proceed" : got === "ON" ? "ask" : "?") === c.action, show([got, c.action]));
    }
  }
} else if (mode === "G2") {
  const before = PC.count();
  const got = withEnv({ CONFIRM_INTENT: "off" }, () => state("intent"));
  check("G2 intent off: planGateState is ON", got === "ON", show(got));
  check("G2 intent off: no probe runs", got === "ON" && PC.count() === before, show({ got, probes: PC.count() - before }));
} else if (mode === "G3") {
  // The in-process probe fails for real (load-env throws / reports loadFailed for CONFIRM_*),
  // with CONFIRM_OUTLINE=off pinned so a fail-open would read OFF. Every failure has a working twin.
  const OFF = { CONFIRM_OUTLINE: "off" };
  const presented = () => {
    const t = session("outline");
    X.turnMarker(t.sid, "outline", t.plan);
    return [t, X.writeTranscript(t.sid, [U("write the plan", "u-prompt"), A("a-write", W(t.plan)), TR("w1", "u-tr"), A("a-anchor", T("Here is the plan.\n\n" + t.line))])];
  };
  const healthy = withEnv(OFF, () => state("outline"));
  check("G3 control: CONFIRM_OUTLINE=off with a working probe reads OFF", healthy === "OFF", show(healthy));
  const s = session("outline");
  const cc = cli(s.sid, "CONFIRM_OUTLINE", OFF);
  check("G3 control: the CLI proceeds with a working probe", cc.action === "proceed" && cc.value === "OFF" && cc.cause === null, show([cc.value, cc.action, cc.out]));
  const ctl = checkpoint(s.sid, "outline", OFF);
  check("G3 control: CONFIRM_OUTLINE=off with a working probe is skipped", skipped(ctl), show(ctl.json));
  const [t, tp] = presented();
  const on = X.runStop(t.sid, tp);
  const continued = on.rc === 2 && on.json.decision === "block" && on.reason.startsWith("[confirm-plan] continue:");
  check("G3 control: the Stop hook continues with a working probe", continued, show({ rc: on.rc, out: on.out, err: on.err.slice(0, 200) }));
  for (const fault of PF.MODES) {
    const before = PC.count();
    const disarm = PF.arm(fault);
    let got;
    try { got = withEnv(OFF, () => state("outline")); } finally { disarm(); }
    check(`G3 probe failure (${fault}): planGateState is ERROR`, healthy === "OFF" && got === "ERROR", show(got));
    check(`G3 probe failure (${fault}): the failing probe was taken once`, PC.count() - before === 1, show({ probes: PC.count() - before }));
    const c = cli(s.sid, "CONFIRM_OUTLINE", OFF, fault);
    check(`G3 probe failure (${fault}): the CLI asks and names the cause`,
      cc.action === "proceed" && c.action === "ask" && c.value === "ERROR" && c.cause === fault, show([c.value, c.action, c.cause, c.out]));
    // confirm-checkpoint: with the probe broken, CONFIRM_OUTLINE=off waives nothing; the dialog shows.
    const k = checkpoint(s.sid, "outline", OFF, fault);
    check(`G3 probe failure (${fault}): confirm-checkpoint shows the dialog, not [confirm-skipped]`, skipped(ctl) && dialog(k), show(k.json));
    // Stop hook: the presented-plan turn continues with a working probe, not with a broken one.
    const [u, up] = presented();
    const off = X.runStop(u.sid, up, { probeFault: fault });
    check(`G3 probe failure (${fault}): the Stop hook does not continue (exit 0, no output, no mark)`,
      continued && off.rc === 0 && off.out.trim() === "" && X.readMark(u.sid, "outline") === null, show({ rc: off.rc, out: off.out }));
  }
} else if (mode === "G4") {
  // "off " (trailing blank) is not the off literal: ON everywhere.
  const got = withEnv({ CONFIRM_OUTLINE: "off " }, () => state("outline"));
  check("G4 'off ': planGateState is ON", got === "ON", show(got));
  const s = session("outline");
  const c = cli(s.sid, "CONFIRM_OUTLINE", { CONFIRM_OUTLINE: "off " });
  check("G4 'off ': the CLI asks", c.action === "ask" && c.value === "ON", show([c.value, c.action, c.out]));
  const k = checkpoint(s.sid, "outline", { CONFIRM_OUTLINE: "off " });
  check("G4 'off ': confirm-checkpoint shows the dialog, not [confirm-skipped]", dialog(k), show(k.json));
} else if (mode === "G5") {
  for (const ms of [0, -1]) {
    const before = PC.count();
    const got = withEnv({ CONFIRM_OUTLINE: "off" }, () => state("outline", { timeoutMs: ms }));
    check(`G5 timeoutMs ${ms}: ERROR`, got === "ERROR", show(got));
    check(`G5 timeoutMs ${ms}: no probe runs`, got === "ERROR" && PC.count() === before, show({ got, probes: PC.count() - before }));
  }
  for (const [v, want] of [["off", "OFF"], ["on", "ON"]]) {
    const before = PC.count();
    const got = withEnv({ CONFIRM_OUTLINE: v }, () => state("outline", { timeoutMs: 5000 }));
    check(`G5 control: a positive timeout probes once and reads ${want} (CONFIRM_OUTLINE=${v})`,
      got === want && PC.count() - before === 1, show({ got, probes: PC.count() - before }));
  }
} else {
  check("gate-driver mode", false, "unknown mode: " + mode);
}
