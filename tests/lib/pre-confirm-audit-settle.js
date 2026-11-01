"use strict";
// tests/lib/pre-confirm-audit-settle.js
// Tests: tests/lib/pre-confirm-audit-settle.js
// Tags: test-infrastructure, shared-lib, supervisor-audit, pre-confirm-audit, fixture, scope:common
// #2853: a plan stage's CONFIRM gate waits until the stage's pre-confirm audit (TR1 / TR2 / TR3) is
// settled on the current plan. A test whose subject is not that audit settles it here, through the
// real arm and finalize writers, so the run's input_key is the one the gate computes.
// Requires WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR pinned by the caller.
// CLI: node pre-confirm-audit-settle.js <sid> <step> [verdict]  -> prints the run id, or ERR:<reason> + exit 1.
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const STAGE_TR = { clarify_intent: "TR1", intent: "TR1", outline: "TR2", detail: "TR3" };
const STEP_OF = { intent: "clarify_intent" };

// arm(sid, step) -> the armed run id (launch shown, any unsettled run superseded), or throws.
function arm(sid, step) {
  const tr = STAGE_TR[step];
  if (!tr) throw new Error("not a plan stage: " + step);
  const { armAuditRun } = require(path.join(ROOT, "hooks/lib/supervisor-state-writer"));
  const res = armAuditRun(sid, {
    tr_ids: [tr], cause: "pre-confirm:" + (STEP_OF[step] || step),
    plans_dir: process.env.WORKFLOW_PLANS_DIR, plan_session_id: sid,
    launch_shown: true, supersede_unsettled: true,
  });
  if (!res || !res.ok || !res.audit_run_id) throw new Error("arm failed: " + JSON.stringify(res));
  return res.audit_run_id;
}

// finalize(sid, runId, verdict) -> true, or throws when the compare-and-set refuses.
function finalize(sid, runId, verdict) {
  const { finalizeAuditRun } = require(path.join(ROOT, "hooks/lib/supervisor-state-writer"));
  const res = finalizeAuditRun(sid, {
    audit_run_id: runId, verdict: verdict || "CONTINUE",
    verdict_summary: `fixture ${verdict || "CONTINUE"} summary for ${runId}`,
  });
  if (!res || res.accepted !== true) throw new Error("finalize refused: " + JSON.stringify(res));
  return true;
}

// settle(sid, step, verdict) -> the run id of a terminal run judged on the current plan.
function settle(sid, step, verdict) {
  const runId = arm(sid, step);
  finalize(sid, runId, verdict);
  return runId;
}

// trySettle(sid, stage, verdict) -> settle()'s run id, or null when the stage is not a plan stage or
// the arm / finalize refuses; a fixture that settles before every echo leaves the deny to the hook.
function trySettle(sid, stage, verdict) {
  if (!sid || !STAGE_TR[stage]) return null;
  try { return settle(sid, stage, verdict); } catch (_) { return null; }
}

module.exports = { STAGE_TR, arm, finalize, settle, trySettle };

if (require.main === module) {
  const [sid, step, verdict] = process.argv.slice(2);
  try {
    process.stdout.write(settle(sid, step, verdict));
  } catch (e) {
    process.stdout.write("ERR:" + String((e && e.message) || e).split("\n")[0]);
    process.exit(1);
  }
}
