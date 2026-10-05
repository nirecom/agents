"use strict";
// hooks/lib/jev/broker.js — library entry for Jev shadow mode (hooks and CLIs alike).
// Shadow means the LLM is always adopted: Jev's result reaches only the decision log, never
// the parent conversation, the signals file or routing.
// Callers take captureTestOverrides(process.env) before requiring this module and pass
// the snapshot in as `overrides`.

const fs = require("fs");
const { resolveConfigVar } = require("../load-env");
const { registryEntry } = require("./registry");
const provider = require("./provider-core");
const breaker = require("./breaker");
const liveness = require("./liveness");
const pending = require("./pending");
const retention = require("./retention");
const record = require("./decision-record");
const { isValidId, jevStateDir } = require("./state-paths");
const { findPointBySubagentType } = require("./dispatch-gate");

// Fail-safe OFF: only a case-insensitive "on" enables; a .env load failure is off.
function isEnabled() {
  try {
    const r = resolveConfigVar("JEV", "off");
    if (r.loadFailed) return false;
    return String(r.value).trim().toLowerCase() === "on";
  } catch (_e) {
    return false;
  }
}

function adapterFor(point) {
  return require(registryEntry(point).adapter);
}

// Calls the unmodified parser's normalize() in-process; returns its CSV or null on failure.
// No file is written: the CLI would overwrite the live <stage>-signals.txt, which shadow
// mode must never touch, and the raw judge text never reaches disk.
function normalizeViaParser(point, rawText) {
  const entry = registryEntry(point);
  if (!entry) return null;
  try {
    const out = require(entry.normalizer).normalize(rawText === null || rawText === undefined ? "" : String(rawText));
    return typeof out === "string" ? out : null;
  } catch (_e) {
    return null;
  }
}

function jevResult(status, extra) {
  return Object.assign({
    status, http_status: null, answer: null, probabilities: null, min_confidence: null,
    latency_ms: null, model: null, input_tokens: null, est_cost_usd: null,
  }, extra || {});
}

// Order: no key -> breaker open -> liveness probe (unless cached) -> query.
// Only the branch after a completed query POST sets latency_ms (its unmappable included);
// every earlier return and every failed query keeps jevResult's null.
async function runJev(point, ctx, sessionId, request) {
  const entry = registryEntry(point);
  const adapter = adapterFor(point);
  if (!provider.jevCoreCheck(ctx).ok) return jevResult("no-key");
  // One admission time, so a late success never clears a breaker that opened after it.
  const admittedAt = Date.now();
  if (!breaker.tryAcquire(sessionId, { now: () => admittedAt })) return jevResult("breaker-open");
  let questions;
  try {
    questions = adapter.buildQuestions();
  } catch (_e) {
    return jevResult("unmappable", { answer: entry.fallback });
  }
  if (!liveness.isFresh(sessionId)) {
    const probe = await provider.jevCoreProbe(ctx);
    if (!probe.ok) {
      breaker.recordFailure(sessionId, probe.status);
      provider.jevCoreEmitFailed(ctx, probe.status, probe.http_status);
      return jevResult(probe.status, { http_status: Number.isInteger(probe.http_status) ? probe.http_status : null });
    }
    liveness.markLive(sessionId);
  }
  const r = await provider.jevCoreRun(ctx, { state: request.state, questions });
  const cls = provider.jevCoreLog(ctx, r);
  if (r.status !== "ok") {
    if (cls.counts_as_outage) breaker.recordFailure(sessionId, r.status);
    provider.jevCoreEmitFailed(ctx, r.status, r.http_status);
    return jevResult(r.status, { http_status: Number.isInteger(r.http_status) ? r.http_status : null });
  }
  const m = adapter.mapAnswers(r.response, entry.confidence_threshold);
  const parsed = normalizeViaParser(point, m.rawLine);
  // A malformed answer set or a parser failure counts as an outage for the breaker while the
  // record keeps "unmappable"; a parser failure is never logged as a usable Jev answer.
  if (m.status === "unmappable" || parsed === null) breaker.recordFailure(sessionId, "bad-response");
  else breaker.recordSuccess(sessionId, { admittedAtMs: admittedAt });
  return jevResult(parsed === null ? "unmappable" : m.status, {
    answer: parsed === null ? entry.fallback : parsed,
    probabilities: m.probabilities,
    min_confidence: m.minConfidence,
    latency_ms: r.latency_ms,
    model: r.model,
    input_tokens: r.input_tokens,
    est_cost_usd: r.est_cost_usd,
  });
}

// The workflow step both hooks record: the hook session's, else (when it has no workflow
// state) that of the cwd's WORKTREE_NOTES Session-ID when notesSessionId binds it to this
// cwd. Null on any failure (fail-open).
function resolveStep(point, sessionId, cwd) {
  try {
    const { resolveCurrentEffectiveStep } = require("../../workflow-state/current-step");
    const own = resolveCurrentEffectiveStep(sessionId);
    if (own !== null && own !== undefined) return own;
    const adapter = adapterFor(point);
    const wsid = typeof adapter.notesSessionId === "function" ? adapter.notesSessionId(cwd) : null;
    return wsid && wsid !== sessionId ? resolveCurrentEffectiveStep(wsid) : null;
  } catch (_e) {
    return null;
  }
}

// Pre-hook side: query Jev and leave the result in pending for the post hook.
async function queryShadow({ point, sessionId, toolUseId, toolInput, step, cwd, overrides }) {
  if (!isEnabled()) return null;
  if (!registryEntry(point) || !isValidId(sessionId) || !isValidId(toolUseId)) return null;
  const adapter = adapterFor(point);
  const stage = adapter.stageForStep(step);
  let request = null;
  try {
    request = adapter.buildRequest({ toolInput, sessionId, stage, cwd });
  } catch (_e) { /* unredactable text is never sent: jev not-run */ }
  let jev;
  if (request === null) {
    request = { state: "", input: { bytes: 0, sha256: null, truncated: false, sources: [] } };
    jev = jevResult("not-run");
  } else {
    const ctx = provider.jevCoreInit({ sessionId, overrides });
    try {
      jev = await runJev(point, ctx, sessionId, request);
    } catch (_e) {
      jev = jevResult("bad-response");
    }
  }
  const hand = {
    v: 1, point, session_id: sessionId, tool_use_id: toolUseId, step: step === undefined ? null : step, stage,
    input: request.input, jev, executor_model: adapter.resolveExecutorModel(toolInput),
    // Taken after the Jev round trip so the LLM latency never includes Jev's.
    llm_dispatch_ts: Date.now(),
  };
  try {
    pending.writePending(sessionId, toolUseId, hand);
  } catch (_e) { /* the post hook then records jev not-run */ }
  return hand;
}

const MAX_DATE_MS = 8.64e15;

// point: already validated by pointOfPending — the hand-off's own value is file content,
// so only fields re-validated by observedPending / observedLlm reach the record.
// A post whose append failed left its observed LLM side in the claim (llm_observed), and
// an unlogged entry also carries the time it was observed (record_ts).
function orphanRecord(point, sessionId, toolUseId, hand) {
  const p = record.observedPending(hand, adapterFor(point).stageForStep) || {};
  const observed = record.observedLlm(hand && hand.llm_observed);
  const ts = hand && hand.record_ts;
  return record.buildRecord({
    point, sessionId, toolUseId, pending: p, step: p.step, stage: p.stage,
    now: Number.isSafeInteger(ts) && ts > 0 && ts <= MAX_DATE_MS ? ts : undefined,
    llm: observed || { status: "missing", answer: null, executor_model: p.executor_model, latency_ms: null },
  });
}

function pointOfPending(hand) {
  return hand && registryEntry(hand.point) ? hand.point : "complexity-judge";
}

// Orphans of one session become "llm missing" records.
function sweepSession(sessionId, overrides, opts = {}) {
  if (!isValidId(sessionId)) return 0;
  const ttl = overrides && overrides.pendingTtlMs;
  return pending.sweepOrphans(sessionId, {
    ttlMs: ttl || pending.DEFAULT_PENDING_TTL_MS,
    skipTid: opts.skipTid,
    onOrphan: (tid, hand) => record.appendDecision(orphanRecord(pointOfPending(hand), sessionId, tid, hand)),
  });
}

function sweepAllSessions(overrides) {
  let names = [];
  try { names = fs.readdirSync(jevStateDir()); } catch (_e) { return 0; }
  let n = 0;
  for (const sid of names) if (isValidId(sid)) n += sweepSession(sid, overrides);
  return n;
}

function runRetention() {
  try {
    return retention.sweepStateDirs({
      onOrphan: (sid, tid, hand) => record.appendDecision(orphanRecord(pointOfPending(hand), sid, tid, hand)),
    });
  } catch (_e) {
    return [];
  }
}

// Post-hook side: pair with the pending, normalise the LLM side, log, return the record built
// (also when the append failed); null when disabled or the input is invalid.
// endTs: when the LLM answer arrived, taken by the caller before any housekeeping.
function recordShadow({ point, sessionId, toolUseId, llmText, toolInput, step, endTs }) {
  if (!isEnabled()) return null;
  const entry = registryEntry(point);
  if (!entry || !isValidId(sessionId) || !isValidId(toolUseId)) return null;
  const adapter = adapterFor(point);
  const now = Number.isFinite(endTs) ? endTs : Date.now();
  const hand = pending.claimPending(sessionId, toolUseId);
  const raw = llmText === undefined ? null : llmText;
  const parsed = raw === null ? null : normalizeViaParser(point, raw);
  let status = adapter.classifyLlm(raw, parsed);
  if (status !== "missing" && parsed === null) status = "parse-fallback";
  const p = hand ? record.observedPending(hand, adapter.stageForStep) : null;
  const dispatchTs = p ? p.llm_dispatch_ts : null;
  const rec = record.buildRecord({
    point, sessionId, toolUseId, pending: p, step, stage: adapter.stageForStep(step), now,
    llm: {
      status,
      answer: status === "missing" ? null : parsed === null ? entry.fallback : parsed,
      executor_model: adapter.resolveExecutorModel(toolInput),
      latency_ms: dispatchTs === null ? null : record.boundedLatency(Math.max(0, Math.round(now - dispatchTs))),
    },
  });
  const appended = record.appendDecision(rec);
  if (appended && appended.ok) {
    if (hand) pending.releaseClaim(sessionId, toolUseId);
  } else if (hand) {
    // A false return leaves the original claim; its orphan sweep then records llm missing.
    pending.rewriteClaim(sessionId, toolUseId, Object.assign({}, hand, { llm_observed: rec.llm }));
  } else {
    // No claim to keep (late or duplicate post): leave the LLM-only record for a sweep.
    pending.writeUnlogged(sessionId, toolUseId, {
      v: 1, point, step: rec.step, jev: rec.jev, input: rec.input, executor_model: rec.llm.executor_model,
      llm_observed: rec.llm, record_ts: now,
    });
  }
  return rec;
}

module.exports = {
  isEnabled,
  findPointBySubagentType,
  normalizeViaParser,
  resolveStep,
  queryShadow,
  recordShadow,
  sweepSession,
  sweepAllSessions,
  runRetention,
};
