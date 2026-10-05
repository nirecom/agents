"use strict";
// hooks/lib/jev/decision-record.js — the v1 decision record and the agreement rule.
// A record holds only normalised values: parser CSVs, enums, numbers, the sanitised
// model name, and the size/hash of the request (never the prompt or plan artifacts).
// Agreement is compared only when both sides are ok and neither answered S0-undecidable
// (not a usable answer), after closeImplications on both; a side listing S1b without S1
// is a rubric violation and scores as disagreement (agreeSets owns the rule).

const path = require("path");
const { SIGNAL_IDS, UNDECIDABLE_SIGNAL } = require("../../workflow-state/complexity-routing");
const { appendJsonlRotating, resolveLogDir } = require("../jsonl-rotating-log");
const { MODEL_RE, OUTAGE_STATUSES } = require("./provider-core");

const RECORD_VERSION = 1;
const LOG_NAME = "jev-decisions.log";
const EXECUTOR = "complexity-judge";

function decisionLogPath(opts = {}) {
  return opts.logPath || path.join(resolveLogDir({}), LOG_NAME);
}

const S1_SIGNAL = "S1-multi-file";
const S1B_SIGNAL = "S1b-wide-change";

// The rubric's S1b => S1 implication, applied to both sides for comparison only.
function closeImplications(set) {
  const out = new Set(set);
  if (out.has(S1B_SIGNAL)) out.add(S1_SIGNAL);
  return out;
}

// A raw (pre-closure) answer listing S1b without S1 breaks the rubric's S1b => S1 rule.
function violatesS1Implication(set) {
  return set.has(S1B_SIGNAL) && !set.has(S1_SIGNAL);
}

function csvToSet(csv) {
  if (typeof csv !== "string" || csv.trim() === "") return new Set();
  return new Set(csv.split(",").map((s) => s.trim()).filter(Boolean));
}

// The agreement rule over two raw signal sets (S0-undecidable is the caller's concern):
// closure on both, except that a side violating S1b => S1 never agrees on S1 or overall.
function agreeSets(rawA, rawB) {
  const a = closeImplications(rawA);
  const b = closeImplications(rawB);
  const violated = violatesS1Implication(rawA) || violatesS1Implication(rawB);
  const bySignal = {};
  for (const id of SIGNAL_IDS) bySignal[id] = a.has(id) === b.has(id);
  if (violated) bySignal[S1_SIGNAL] = false;
  const same = !violated && a.size === b.size && [...a].every((x) => b.has(x));
  return { agreement: same, agreement_by_signal: bySignal };
}

function compare(jev, llm) {
  if (!jev || !llm || jev.status !== "ok" || llm.status !== "ok") {
    return { agreement: null, agreement_by_signal: null };
  }
  const a = csvToSet(jev.answer);
  const b = csvToSet(llm.answer);
  if (a.has(UNDECIDABLE_SIGNAL) || b.has(UNDECIDABLE_SIGNAL)) return { agreement: null, agreement_by_signal: null };
  return agreeSets(a, b);
}

function notRunJev() {
  return {
    status: "not-run", http_status: null, answer: null, probabilities: null, min_confidence: null,
    latency_ms: null, model: null, input_tokens: null, est_cost_usd: null,
  };
}

function emptyInput() {
  return { bytes: 0, sha256: null, truncated: false, sources: [] };
}

const LLM_STATUSES = new Set(["ok", "parse-fallback", "missing"]);
// Every status the broker's jevResult / notRunJev can carry.
const JEV_STATUSES = new Set([...OUTAGE_STATUSES, "ok", "low-confidence", "unmappable", "no-key", "breaker-open", "not-run"]);
const JEV_ANSWERED = new Set(["ok", "low-confidence"]);
const ANSWER_VOCAB = new Set([...SIGNAL_IDS, UNDECIDABLE_SIGNAL]);
const MAX_ANSWER_CHARS = 512;
const MAX_LATENCY_MS = 86400000;
const MAX_TOKENS = 1e8;
const MAX_COST_USD = 1000;
const MAX_INPUT_BYTES = 1e7;
const STEP_RE = /^[A-Za-z0-9_-]{1,64}$/;
const SOURCE_RE = /^[a-z_]{1,32}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;

function isAnswerCsv(v) {
  if (typeof v !== "string" || v.length > MAX_ANSWER_CHARS) return false;
  return v.trim() === "" || v.split(",").every((s) => ANSWER_VOCAB.has(s.trim()));
}

function canonicalAnswer(raw) {
  return raw.trim() === "" ? "" : raw.split(",").map((s) => s.trim()).join(",");
}

function isObj(v) {
  return Boolean(v) && typeof v === "object" && !Array.isArray(v);
}

function boundedNum(v, max, round) {
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > max) return null;
  return round ? Math.round(v) : v;
}

function boundedLatency(ms) {
  return boundedNum(ms, MAX_LATENCY_MS, true);
}

function modelOrNull(m) {
  return typeof m === "string" && MODEL_RE.test(m) ? m : null;
}

// The llm block a failed post left in its claim (untrusted file content): the same value
// classes recordShadow produces, else null so the orphan falls back to "missing".
function observedLlm(v) {
  if (!isObj(v) || !LLM_STATUSES.has(v.status)) return null;
  const raw = v.status === "missing" ? null : v.answer;
  if (raw === null ? v.status !== "missing" : !isAnswerCsv(raw)) return null;
  return {
    status: v.status,
    answer: raw === null ? null : canonicalAnswer(raw),
    executor_model: modelOrNull(v.executor_model) || undefined,
    latency_ms: boundedLatency(v.latency_ms),
  };
}

// The jev block of a pending / claim (untrusted file content). An unknown status, or an
// answered status without a vocabulary answer, is null (recorded as jev not-run).
function observedJev(v) {
  if (!isObj(v) || !JEV_STATUSES.has(v.status)) return null;
  const raw = v.answer === null || v.answer === undefined ? null : v.answer;
  if (raw === null ? JEV_ANSWERED.has(v.status) : !isAnswerCsv(raw)) return null;
  let probabilities = null;
  if (isObj(v.probabilities)) {
    probabilities = {};
    for (const id of SIGNAL_IDS) probabilities[id] = boundedNum(v.probabilities[id], 1, false);
  }
  const http = v.http_status;
  return {
    status: v.status,
    http_status: Number.isInteger(http) && http >= 100 && http <= 599 ? http : null,
    answer: raw === null ? null : canonicalAnswer(raw),
    probabilities,
    min_confidence: boundedNum(v.min_confidence, 1, false),
    latency_ms: boundedLatency(v.latency_ms),
    model: modelOrNull(v.model),
    input_tokens: Number.isSafeInteger(v.input_tokens) ? boundedNum(v.input_tokens, MAX_TOKENS, false) : null,
    est_cost_usd: boundedNum(v.est_cost_usd, MAX_COST_USD, false),
  };
}

function observedInput(v) {
  if (!isObj(v)) return emptyInput();
  return {
    bytes: Number.isSafeInteger(v.bytes) ? boundedNum(v.bytes, MAX_INPUT_BYTES, false) || 0 : 0,
    sha256: typeof v.sha256 === "string" && SHA256_RE.test(v.sha256) ? v.sha256 : null,
    truncated: v.truncated === true,
    sources: Array.isArray(v.sources) ? v.sources.filter((s) => typeof s === "string" && SOURCE_RE.test(s)).slice(0, 8) : [],
  };
}

// A pending / claim hand-off rebuilt from validated fields only; stage is re-derived from
// the validated step exactly as the pre hook derives it. Null when hand is not an object.
function observedPending(hand, stageForStep) {
  if (!isObj(hand)) return null;
  const step = typeof hand.step === "string" && STEP_RE.test(hand.step) ? hand.step : null;
  const ts = hand.llm_dispatch_ts;
  return {
    step,
    stage: stageForStep(step),
    input: observedInput(hand.input),
    jev: observedJev(hand.jev),
    executor_model: modelOrNull(hand.executor_model) || undefined,
    llm_dispatch_ts: typeof ts === "number" && Number.isFinite(ts) && ts > 0 ? ts : null,
  };
}

// pending: the pre hook's hand-off (null when the post arrived without one).
// llm: {status, answer, executor_model, latency_ms}.
function buildRecord({ point, sessionId, toolUseId, pending, step, stage, llm, now }) {
  const p = pending || {};
  const jev = p.jev && typeof p.jev === "object" ? p.jev : notRunJev();
  const llmSide = {
    status: llm.status,
    answer: llm.answer === undefined ? null : llm.answer,
    executor: EXECUTOR,
    executor_model: llm.executor_model || p.executor_model || "unknown",
    latency_ms: llm.latency_ms === undefined ? null : llm.latency_ms,
  };
  const cmp = compare(jev, llmSide);
  return {
    v: RECORD_VERSION,
    ts: new Date(now || Date.now()).toISOString(),
    point,
    mode: "shadow",
    adopted: "llm",
    session_id: sessionId,
    step: p.jev ? (p.step === undefined ? null : p.step) : (step === undefined ? null : step),
    stage: p.jev ? p.stage || "unknown" : stage || "unknown",
    tool_use_id: toolUseId,
    input: p.input && typeof p.input === "object" ? p.input : emptyInput(),
    jev,
    llm: llmSide,
    agreement: cmp.agreement,
    agreement_by_signal: cmp.agreement_by_signal,
    fallback_reason: jev.status === "ok" ? null : jev.status,
  };
}

// Best effort: an unwritable log never breaks the dispatch.
function appendDecision(record, opts = {}) {
  return appendJsonlRotating(decisionLogPath(opts), record);
}

module.exports = {
  RECORD_VERSION, LOG_NAME, EXECUTOR,
  decisionLogPath, closeImplications, violatesS1Implication, agreeSets, csvToSet, compare, boundedLatency,
  observedLlm, observedJev, observedInput, observedPending, buildRecord, appendDecision,
};
