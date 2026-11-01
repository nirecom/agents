"use strict";
// #2256 S5-d / #2709 / #2597 / #2853 — record a reviewed human acceptance of an audit verdict.
// The only caller is the ask-gated WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel handler, so every
// acceptance passes the user's permission dialog. Two shapes:
//   - a BLOCK / WARN verdict of the last terminal run (TR5, or a TR1-3 plan-stage run);
//   - an unsettled TR1-3 run (UNSETTLED): the run never got a verdict, so it is retired and the
//     audit phase settles to done (#2853). TR4 / TR5 runs are never accepted unsettled.
// The record pins the run's verdict and snapshot (freshness_key, artifact_keys, trigger key);
// hooks/lib/null-freshness.js (TR5) and hooks/lib/pre-confirm-audit.js (TR1-3) decide when it releases.

const { recordBlockOverride } = require("./supervisor-state-writer");
const { releaseUnsettledRun } = require("./supervisor-state-writer/audit-run");
const { lastTerminalRun } = require("./audit-ledger");
const { UNSETTLED_AUDIT_PHASES } = require("./supervisor-state-schema");
const { ACCEPTABLE_VERDICTS, MIN_REASON_LEN, safeVerdict, safeRunId } = require("./null-freshness/acceptance");

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;
const DEFAULT_REPORTER = "supervisor-block-override";
const UNSETTLED_VERDICT = "UNSETTLED";
// Plan-stage triggers, heaviest last: a run covering several stages pins the latest stage's key.
const STAGE_TRS = ["TR1", "TR2", "TR3"];

function refuse(code, message) {
  return { ok: false, code, message };
}

function envActor() {
  return process.env.USER || process.env.USERNAME || process.env.LOGNAME || "unknown";
}

// Lazy: the resolver lives with its other consumer (the TR5 gate) so both read the same store.
function resolveState(sessionId) {
  const { resolveSupervisorState } = require("../workflow-gate/supervisor-check");
  return resolveSupervisorState(sessionId);
}

function trIdsOf(run) {
  return Array.isArray(run && run.tr_ids) ? run.tr_ids.filter((t) => typeof t === "string") : [];
}

// TR5's key when the run carries one, else the latest plan stage's key among the run's triggers.
function triggerKeyOf(run) {
  const keys = run.trigger_input_keys;
  if (!keys || typeof keys !== "object" || Array.isArray(keys)) return null;
  if (typeof keys.TR5 === "string") return keys.TR5;
  const trs = trIdsOf(run);
  for (let i = STAGE_TRS.length - 1; i >= 0; i--) {
    const tr = STAGE_TRS[i];
    if (trs.includes(tr) && typeof keys[tr] === "string") return keys[tr];
  }
  return null;
}

function snapshotOf(run) {
  const ak = run.artifact_keys;
  return {
    freshness_key: typeof run.freshness_key === "string" && run.freshness_key.length > 0 ? run.freshness_key : null,
    artifact_keys: ak && typeof ak === "object" && !Array.isArray(ak) ? Object.assign({}, ak) : null,
    trigger_key: triggerKeyOf(run),
  };
}

// The armed, still-unsettled run named runId when every trigger it carries is a plan stage; else null.
function unsettledStageRun(audit, runId) {
  if (!audit || !UNSETTLED_AUDIT_PHASES.includes(audit.audit_phase)) return null;
  if (typeof runId !== "string" || runId !== audit.audit_run_id) return null;
  const entries = (Array.isArray(audit.ledger) ? audit.ledger : []).filter((e) => e && e.id === runId);
  const run = entries.length > 0 ? entries[entries.length - 1] : null;
  if (!run || run.outcome === "terminal") return null;
  const trs = trIdsOf(run);
  return trs.length > 0 && trs.every((t) => STAGE_TRS.includes(t)) ? run : null;
}

function record(effectiveSid, run, verdict, reason, actor, reporter) {
  const snap = snapshotOf(run);
  const written = recordBlockOverride(effectiveSid, {
    audit_run_id: run.id,
    verdict,
    freshness_key: snap.freshness_key,
    artifact_keys: snap.artifact_keys,
    trigger_key: snap.trigger_key,
    reason,
    actor,
    reporter: reporter || DEFAULT_REPORTER,
  });
  return { written: written === true, snap };
}

// recordReviewedVerdictAcceptance(sessionId, { runId, reason, actor, reporter })
//   -> { ok, code, message, verdict?, tr_ids? }
function recordReviewedVerdictAcceptance(sessionId, opts = {}) {
  const runId = opts.runId;
  const reason = typeof opts.reason === "string" ? opts.reason.trim() : "";
  // Reason gate first: a refused acceptance never touches state.
  if (reason.length < MIN_REASON_LEN) {
    return refuse("reason-too-short", `reason must be at least ${MIN_REASON_LEN} characters; got ${reason.length}.`);
  }
  if (!sessionId || !SESSION_ID_RE.test(sessionId)) {
    return refuse("invalid-session", "could not resolve a valid session id.");
  }

  let resolved;
  try {
    resolved = resolveState(sessionId);
  } catch {
    return refuse("state-unreadable", `could not read supervisor state for session ${sessionId}.`);
  }
  const { state, effectiveSid } = resolved || {};
  if (!state) return refuse("no-state", `no supervisor state for session ${sessionId}.`);
  const audit = state.audit || {};
  const actor = typeof opts.actor === "string" && opts.actor.length > 0 ? opts.actor : envActor();

  const unsettled = unsettledStageRun(audit, runId);
  if (unsettled) {
    const { written } = record(effectiveSid, unsettled, UNSETTLED_VERDICT, reason, actor, opts.reporter);
    if (!written) return refuse("write-failed", "failed to write the acceptance record.");
    const rel = releaseUnsettledRun(effectiveSid, runId);
    if (!rel || rel.released !== true) {
      return refuse("release-failed", `acceptance recorded but run ${safeRunId(runId)} was not released (${(rel && rel.reason) || "unknown"}).`);
    }
    return {
      ok: true, code: "recorded", verdict: UNSETTLED_VERDICT, tr_ids: trIdsOf(unsettled),
      message: `${UNSETTLED_VERDICT} acceptance recorded for ${runId} (the run is retired; actor ${actor}).`,
    };
  }

  const terminal = lastTerminalRun(audit);
  if (!terminal) return refuse("no-terminal-run", "no terminal audit run exists to accept.");
  if (terminal.id !== runId) {
    return refuse("not-last-terminal-run", `run id ${safeRunId(runId)} is not the last terminal run (${terminal.id ? safeRunId(terminal.id) : "<none>"}).`);
  }
  if (!ACCEPTABLE_VERDICTS.includes(terminal.verdict)) {
    const shown = terminal.verdict === null || terminal.verdict === undefined ? "<none>" : safeVerdict(terminal.verdict);
    return refuse("verdict-not-acceptable",
      `the last terminal run's verdict is ${shown}, not ${ACCEPTABLE_VERDICTS.join(" or ")} — nothing to accept.`);
  }

  // Pinned straight off the terminal run, so recording needs no git recomputation.
  const { written, snap } = record(effectiveSid, terminal, terminal.verdict, reason, actor, opts.reporter);
  if (!written) return refuse("write-failed", "failed to write the acceptance record.");
  return {
    ok: true,
    code: "recorded",
    verdict: terminal.verdict,
    tr_ids: trIdsOf(terminal),
    message: `${terminal.verdict} acceptance recorded for ${runId} (freshness_key ${snap.freshness_key || "<none>"}, actor ${actor}).`,
  };
}

module.exports = { recordReviewedVerdictAcceptance, MIN_REASON_LEN };
