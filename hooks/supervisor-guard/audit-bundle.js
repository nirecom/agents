"use strict";

// #2698 change 3 — alert and audit as one intervention. Owns the post-alert suppression window
// (launch-directive suppression window) and the bundling of an audit launch section into an alert block reason.
// Authority: the #2698 detail plan, Step 3-0 / 3-3.

const { countHumanPromptsSince } = require("../lib/user-dialog-turn");

// The suppression window: P = human prompts since alert.last_run_at; P in {0, 1} is inside.
// No last_run_at (no alert review ever completed) or an undecidable P (null) is outside, so the
// fallback is today's behaviour (the launch is shown) and a deferred run is never stuck.
function inPostAlertSuppression(state, input) {
  const alert = state && state.alert;
  const lastRunAt = alert && typeof alert.last_run_at === "string" ? alert.last_run_at : null;
  if (!lastRunAt) return false;
  const p = countHumanPromptsSince(input, lastRunAt);
  return p === 0 || p === 1;
}

// Appends the audit launch section to an alert block reason. The state is re-read here because
// the caller's snapshot is stale after Phase B's done->null CAS. No CONV_LANG injection is added:
// the alert reason already carries it. Fail-open: any error returns alertReason unchanged.
function bundleAuditLaunch(alertReason, deps) {
  try {
    const { evaluatePhaseA, formatAuditLaunchSection } = require("./audit-arm");
    const fresh = deps.readState(deps.sessionId);
    const audit = (fresh && fresh.audit) || {};
    const ctx = {
      ...deps.ctx,
      mode: "bundled",
      auditPhase: audit.audit_phase === undefined ? null : audit.audit_phase,
    };
    const result = evaluatePhaseA(deps.sessionId, fresh, ctx);
    if (!result || !result.armInfo) return alertReason;
    const runId = result.armInfo.run_id || "<none>";
    return [
      alertReason,
      "",
      "---",
      `In the same turn, in parallel with the supervisor alert review above, launch supervisor-audit with run-id ${runId}.`,
      formatAuditLaunchSection(result.armInfo, ctx.meta || {}),
    ].join("\n");
  } catch (_) {
    return alertReason;
  }
}

module.exports = { inPostAlertSuppression, bundleAuditLaunch };
