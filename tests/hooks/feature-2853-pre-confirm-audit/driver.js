"use strict";
// Shared #2853 driver: runs `next-step --gate` as a child against a fixture session, reads the
// supervisor audit state, and reports PASS / FAIL lines with a failure count. Builds on the #2650
// fixture (sessions at a plan stage, the per-call .env root for CONFIRM_INTENT/OUTLINE/DETAIL).
// Requires WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR pinned by the calling test before require.
const path = require("path");
const { spawnSync } = require("child_process");
const X = require("../feature-2650-confirm-continuation/fixture");
const S = require("../../lib/pre-confirm-audit-settle");

const ROOT = X.ROOT;
const PRELOAD = path.join(ROOT, "tests", "lib", "artifact-key-throw-preload.js");
const ACCEPT_SENTINEL = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";

let failures = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 400);
function check(name, ok, detail) {
  if (ok) console.log(`PASS ${name}`);
  else { failures += 1; console.log(`FAIL ${name} :: ${clip(detail)}`); }
}
const failureCount = () => failures;

// childEnv(over, extra) -> the gate child env: plan flags via the .env root, no session id.
function childEnv(over, extra) {
  const env = Object.assign({}, process.env, X.gateEnv(over), { ENFORCE_WORKTREE: "off" }, extra || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  for (const k of Object.keys(env)) if (env[k] === undefined) delete env[k];
  return env;
}

// parseGate(stdout) -> {action, hint, reason, lines}; the first occurrence of a key wins.
function parseGate(out) {
  const lines = {};
  for (const ln of String(out || "").split(/\r?\n/)) {
    const m = /^([A-Z_]+)=(.*)$/.exec(ln);
    if (m && !(m[1] in lines)) lines[m[1]] = m[2].replace(/^"|"$/g, "");
  }
  return { action: lines.GATE_ACTION || "", hint: lines.GATE_HINT || "", reason: lines.REASON || "", lines };
}

// gate(sid, over, extra) -> parseGate(...) plus {rc, out, err}. over: CONFIRM_* and other keys.
function gate(sid, over, extra) {
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin/workflow/next-step"), "--gate", "--session", sid], {
    env: childEnv(over, extra), encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  return Object.assign({ rc: r.status, out: r.stdout || "", err: r.stderr || "" }, parseGate(r.stdout));
}

// throwEnv() -> extra env that makes the plan-artifact key computation throw in the child.
const throwEnv = () => ({ CC_ARTIFACT_KEY_THROW: "1", NODE_OPTIONS: X.nodeOptions([PRELOAD]) });

function audit(sid) {
  try {
    const st = require(path.join(ROOT, "hooks/lib/supervisor-state-writer")).readState(sid);
    return (st && st.audit) || {};
  } catch (_) { return {}; }
}
const ledgerOf = (sid) => (Array.isArray(audit(sid).ledger) ? audit(sid).ledger : []);
const runEntry = (sid, runId) => ledgerOf(sid).find((e) => e && e.id === runId) || null;
const countOf = (sid, tr) => ((audit(sid).audit_run_counts || {})[tr]);

// accept(sid, runId) -> the recordReviewedVerdictAcceptance result for runId.
function accept(sid, runId) {
  const { recordReviewedVerdictAcceptance } = require(path.join(ROOT, "hooks/lib/supervisor-block-override"));
  return recordReviewedVerdictAcceptance(sid, {
    runId, reason: "fixture: the user reviewed the findings and accepts them", actor: "test-fixture",
  });
}

// editPlan(sid, stage, n) -> rewrites the stage's plan so its artifact key changes.
function editPlan(sid, stage, n) {
  X.F.writePlan(sid, stage, X.F.PLAN_BODY[stage] + `\nrevision ${n}\n`);
}

const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };

module.exports = {
  X, S, ROOT, PRELOAD, ACCEPT_SENTINEL, check, failureCount, childEnv, parseGate, gate, throwEnv,
  audit, ledgerOf, runEntry, countOf, accept, editPlan, show,
};
