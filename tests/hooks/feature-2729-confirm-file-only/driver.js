"use strict";
// #2729 Gap 2 driver: CONFIRM_INTENT/OUTLINE/DETAIL are read from $AGENTS_MAIN_ROOT/.env only.
// An exported value and a project .env.local value are both ignored by every reader: the probe,
// bin/confirm-off, planGateState, checkPlanApproval's gate, plan-confirm-flag and the off waiver.
// Keys outside the three keep the export. Modes: export | local | file-off | control | unit.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");

// --inproc <sid>: every in-process reader of CONFIRM_DETAIL, under the child's env.
if (process.argv[2] === "--inproc") {
  const out = {};
  const sid = process.argv[3];
  const tryIt = (k, fn) => { try { out[k] = fn(); } catch (e) { out[k] = "threw:" + e.message; } };
  tryIt("probe", () => require(path.join(ROOT, "hooks/lib/confirm-gate/probe.js")).probeConfirmGateWithCause("CONFIRM_DETAIL", 5000).value);
  tryIt("plan", () => require(path.join(ROOT, "hooks/lib/confirm-gate/plan-gate.js")).planGateState("detail"));
  tryIt("fromFile", () => require(path.join(ROOT, "hooks/lib/plan-confirm-flag.js")).isConfirmOffForStageFromFile("detail"));
  tryIt("check", () => require(path.join(ROOT, "hooks/workflow-state/plan-approval-check.js")).checkPlanApproval(sid, "detail"));
  tryIt("eval", () => {
    const WS = require(path.join(ROOT, "hooks/workflow-state"));
    return require(path.join(ROOT, "hooks/workflow-state/completion-approval.js")).evaluateCompletionApproval(sid, "detail", WS.readState(sid));
  });
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

const X = require("../feature-2650-confirm-continuation/fixture");
const CE = require("../../lib/confirm-env-fixture");
const { check, show } = X;
const CFG_BASE = path.join(X.F.STATE_DIR, "cfg-file-only");

// envOf(fileVars, {exported, local}) -> child env: a fresh config root, `exported` set as real
// exports, and `local` written to a project dir's .env.local that CLAUDE_PROJECT_DIR points at.
function envOf(fileVars, o) {
  const opt = o || {};
  const env = CE.childEnvWith(CE.confirmEnvRoot(CFG_BASE, fileVars));
  delete env.CLAUDE_CODE_SESSION_ID;
  Object.assign(env, opt.exported || {});
  if (opt.local) {
    const proj = CE.confirmEnvRoot(path.join(CFG_BASE, "proj"), {}, { local: opt.local });
    fs.mkdirSync(path.join(proj, ".git"), { recursive: true });
    env.CLAUDE_PROJECT_DIR = proj;
  }
  return env;
}

function inproc(env, sid) {
  const r = spawnSync(process.execPath, [__filename, "--inproc", sid], { env, encoding: "utf8", timeout: 60000 });
  try { return JSON.parse(r.stdout); } catch (_) { return { raw: (r.stdout || "") + (r.stderr || "") }; }
}

function confirmOff(env, key) {
  const r = spawnSync("bash", [path.join(ROOT, "bin/confirm-off").replace(/\\/g, "/"), key, "on"], { env, encoding: "utf8", timeout: 60000 });
  return String(r.stdout || "").trim() || `rc=${r.status} err=${r.stderr}`;
}

const sid = () => X.sessionAt("detail", { tag: 2729 }).sid;

function expectAll(label, env, want) {
  const s = sid();
  const v = inproc(env, s);
  const gate = v.check && v.check.gate;
  check(`${label}: probe -> ${want}`, v.probe === want, show(v));
  check(`${label}: bin/confirm-off -> ${want}`, confirmOff(env, "CONFIRM_DETAIL") === want, confirmOff(env, "CONFIRM_DETAIL"));
  check(`${label}: planGateState(detail) -> ${want}`, v.plan === want, show(v.plan));
  check(`${label}: checkPlanApproval gate -> ${want}`, gate === want, show(v.check));
  check(`${label}: plan-confirm-flag isConfirmOffForStageFromFile -> ${want === "OFF"}`, v.fromFile === (want === "OFF"), show(v.fromFile));
  if (want === "OFF") {
    check(`${label}: evaluateCompletionApproval waives`, v.eval && v.eval.approved === true && v.eval.source === "confirm-flag-off", show(v.eval));
  } else {
    check(`${label}: evaluateCompletionApproval does not waive`, v.eval && v.eval.approved === false, show(v.eval));
  }
}

const ON = { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" };

const MODES = {
  export: () => expectAll(".env on + export CONFIRM_DETAIL=off", envOf(ON, { exported: { CONFIRM_DETAIL: "off" } }), "ON"),
  local: () => {
    expectAll(".env on + .env.local CONFIRM_DETAIL=off", envOf(ON, { local: { CONFIRM_DETAIL: "off" } }), "ON");
    expectAll(".env with no CONFIRM_DETAIL + .env.local off + export off", envOf({}, { local: { CONFIRM_DETAIL: "off" }, exported: { CONFIRM_DETAIL: "off" } }), "ON");
  },
  "file-off": () => {
    expectAll(".env CONFIRM_DETAIL=off", envOf(Object.assign({}, ON, { CONFIRM_DETAIL: "off" })), "OFF");
    expectAll(".env off + export CONFIRM_DETAIL=on", envOf(Object.assign({}, ON, { CONFIRM_DETAIL: "off" }), { exported: { CONFIRM_DETAIL: "on" } }), "OFF");
  },
  control: () => {
    const env = envOf(ON, { exported: { CONFIRM_CODE: "off" } });
    check("control: export CONFIRM_CODE=off still makes bin/confirm-off OFF", confirmOff(env, "CONFIRM_CODE") === "OFF", confirmOff(env, "CONFIRM_CODE"));
    const local = envOf(ON, { local: { CONFIRM_CODE: "off" } });
    check("control: .env.local CONFIRM_CODE=off still applies (outside the three keys)", confirmOff(local, "CONFIRM_CODE") === "OFF", confirmOff(local, "CONFIRM_CODE"));
  },
  unit: () => {
    const LE = require(path.join(ROOT, "hooks/lib/local-env.js"));
    for (const k of CE.PLAN_KEYS) {
      const r = LE.overlay({ [k]: "on" }, { [k]: "off" });
      check(`local-env overlay ignores ${k} from .env.local`, r.ignored.includes(k) && r.map[k] === "on", show(r));
      check(`local-env blocklists ${k}`, LE.isBlocklisted(k) === true, "false");
    }
    check("local-env still applies CONFIRM_CODE from .env.local", LE.overlay({}, { CONFIRM_CODE: "off" }).applied.includes("CONFIRM_CODE"), "not applied");
    const CF = require(path.join(ROOT, "hooks/lib/config-flag.js"));
    check("config-flag exports kindOfValue", typeof CF.kindOfValue === "function", Object.keys(CF).join(","));
    check("config-flag exports isPlanStageConfirmKey", typeof CF.isPlanStageConfirmKey === "function", Object.keys(CF).join(","));
    if (typeof CF.isPlanStageConfirmKey === "function") {
      check("isPlanStageConfirmKey: the three plan keys", CE.PLAN_KEYS.every((k) => CF.isPlanStageConfirmKey(k) === true), "a key missed");
      check("isPlanStageConfirmKey: CONFIRM_CODE / CONFIRM_TESTS are not plan keys",
        CF.isPlanStageConfirmKey("CONFIRM_CODE") === false && CF.isPlanStageConfirmKey("CONFIRM_TESTS") === false, "true");
    }
  },
};

const mode = process.argv[2];
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
