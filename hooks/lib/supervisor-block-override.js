"use strict";
// #2256 S5-d / #2709 — record a reviewed human override of a standing TR5 BLOCK hold.
// The only caller is the ask-gated WORKFLOW_SUPERVISOR_BLOCK_OVERRIDE sentinel handler,
// so every override passes the user's permission dialog. The hold is released only while
// the override names the run it was taken against AND the freshness_key it pins still holds.

const { recordBlockOverride } = require("./supervisor-state-writer");
const { lastTerminalRun } = require("./audit-ledger");

const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;
const MIN_REASON_LEN = 20;
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

// recordReviewedBlockOverride(sessionId, { runId, reason, actor, reporter }) -> { ok, code, message }
function recordReviewedBlockOverride(sessionId, opts = {}) {
  const runId = opts.runId;
  const reason = typeof opts.reason === "string" ? opts.reason.trim() : "";
  // Reason gate first: a refused override never touches state.
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
  if (!terminal) return refuse("no-terminal-run", "no terminal audit run exists to override.");
  if (terminal.id !== runId) {
    return refuse("not-last-terminal-run", `run id ${runId} is not the last terminal run (${terminal.id || "<none>"}).`);
  }
  if (terminal.verdict !== "BLOCK") {
    return refuse("not-block",
      `the last terminal run's verdict is ${terminal.verdict || "<none>"}, not BLOCK — nothing to override.`);
  }

  // Pinned straight off the terminal run, so recording needs no git recomputation.
  const freshnessKey = typeof terminal.freshness_key === "string" && terminal.freshness_key.length > 0
    ? terminal.freshness_key
    : null;
  const actor = typeof opts.actor === "string" && opts.actor.length > 0 ? opts.actor : envActor();

  const written = recordBlockOverride(effectiveSid, {
    audit_run_id: runId,
    freshness_key: freshnessKey,
    reason,
    actor,
    reporter: opts.reporter || DEFAULT_REPORTER,
  });
  if (written !== true) return refuse("write-failed", "failed to write the override record.");
  return { ok: true, code: "recorded", message: `override recorded for ${runId} (freshness_key ${freshnessKey || "<none>"}, actor ${actor}).` };
}

module.exports = { recordReviewedBlockOverride, MIN_REASON_LEN };
