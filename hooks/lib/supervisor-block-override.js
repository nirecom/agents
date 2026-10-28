"use strict";
// #2256 S5-d / #2709 / #2597 — record a reviewed human acceptance of a TR5 BLOCK or WARN verdict.
// The only caller is the ask-gated WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel handler, so every
// acceptance passes the user's permission dialog. The record pins the run's verdict and snapshot
// (freshness_key, artifact_keys, TR5 trigger key); hooks/lib/null-freshness.js decides when it releases.

const { recordBlockOverride } = require("./supervisor-state-writer");
const { lastTerminalRun } = require("./audit-ledger");
const { ACCEPTABLE_VERDICTS, MIN_REASON_LEN, safeVerdict, safeRunId } =require("./null-freshness/acceptance");

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;
const DEFAULT_REPORTER = "supervisor-block-override";

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

function snapshotOf(terminal) {
  const ak = terminal.artifact_keys;
  const keys = terminal.trigger_input_keys;
  return {
    freshness_key: typeof terminal.freshness_key === "string" && terminal.freshness_key.length > 0
      ? terminal.freshness_key : null,
    artifact_keys: ak && typeof ak === "object" && !Array.isArray(ak) ? Object.assign({}, ak) : null,
    trigger_key: keys && typeof keys === "object" && typeof keys.TR5 === "string" ? keys.TR5 : null,
  };
}

// recordReviewedVerdictAcceptance(sessionId, { runId, reason, actor, reporter }) -> { ok, code, message }
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
  } catch (e) {
    return refuse("state-unreadable", `could not read supervisor state for session ${sessionId}.`);
  }
  const { state, effectiveSid } = resolved || {};
  if (!state) return refuse("no-state", `no supervisor state for session ${sessionId}.`);

  const terminal = lastTerminalRun(state.audit || {});
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
  const snap = snapshotOf(terminal);
  const actor = typeof opts.actor === "string" && opts.actor.length > 0 ? opts.actor : envActor();

  const written = recordBlockOverride(effectiveSid, {
    audit_run_id: runId,
    verdict: terminal.verdict,
    freshness_key: snap.freshness_key,
    artifact_keys: snap.artifact_keys,
    trigger_key: snap.trigger_key,
    reason,
    actor,
    reporter: opts.reporter || DEFAULT_REPORTER,
  });
  if (written !== true) return refuse("write-failed", "failed to write the acceptance record.");
  return {
    ok: true,
    code: "recorded",
    message: `${terminal.verdict} acceptance recorded for ${runId} (freshness_key ${snap.freshness_key || "<none>"}, actor ${actor}).`,
  };
}

module.exports = { recordReviewedVerdictAcceptance, MIN_REASON_LEN };
