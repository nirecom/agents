"use strict";
// hooks/lib/jev/two-stage/merge.js — finalize's judgment for complexity-judge (#2460): read the
// ticket's own answer file (1 MiB cap), parse it with the adapter, merge the deterministic,
// Jev-adopted and subagent-adopted signals into one contract line, and build the decision
// record. Also builds the finalize-absent record of an orphaned ticket.

const fs = require("fs");
const path = require("path");

const { buildRecord } = require("../decision-record");
const { frozenEntry } = require("./paths");
const { readCappedBytes } = require(path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "lib", "jev-request-common.js"));
const { SIGNAL_IDS, JUDGED_SIGNAL_IDS, DETERMINISTIC_SIGNAL_IDS, UNDECIDABLE_SIGNAL } = require("../../../workflow-state/complexity-routing");

const MAX_ANSWER_BYTES = 1048576;
const arr = (v) => (Array.isArray(v) ? v : []);

// {received, raw}: raw is null when the file is over the cap (read as unparseable).
function readAnswer(file) {
  let r;
  try {
    r = readCappedBytes(file, MAX_ANSWER_BYTES);
  } catch (_e) {
    return { received: false, raw: null };
  }
  return { received: true, raw: r.over_cap ? null : r.bytes.toString("utf8") };
}

function idOfKey(adapter) {
  const map = {};
  for (const id of JUDGED_SIGNAL_IDS) map[adapter.questionKey(id)] = id;
  return map;
}

// The record of a ticket: frozen policy and Jev side from the ticket, the rest from the caller.
function ticketRecord(sid, tid, hand, parts) {
  const rec = buildRecord({
    point: hand.point, sessionId: sid, step: null, stage: hand.stage, ticket: tid,
    pending: { jev: hand.jev, stage: hand.stage, step: null, input: hand.input },
    llm: parts.llm, mode: hand.mode, adopted: parts.adopted, entry: frozenEntry(hand),
    llmAnswerReceived: parts.received,
  });
  return Object.assign(rec, {
    short_circuited: hand.short_circuited === true, unjudged_keys: arr(hand.unjudged),
    deterministic: parts.deterministic, llm_needed: arr(hand.delegated).length > 0,
    final: parts.final, fallback_reason: parts.fallback,
  });
}

function deterministicRecord(det, override) {
  if (det && typeof det === "object") return Object.assign({}, det, { override: override.slice() });
  return override.length ? { status: "not-applicable", values: null, source_sha256: null, override: override.slice() } : null;
}

// The reason a delegated answer could not be used (null when none was needed or it parsed ok).
// Vocabulary SSOT: docs/architecture/jev/two-stage-broker.md "Missing answer".
function answerFallbackOf(needed, received, parsedStatus) {
  if (!needed || parsedStatus === "ok") return null;
  if (!received) return "answer-file-absent";
  if (parsedStatus === "missing") return "answer-empty";
  if (parsedStatus === "parse-fallback") return "answer-unparseable";
  return null;
}

function fallbackOf(hand, answerReason, detFail) {
  if (answerReason) return answerReason;
  if (detFail) return `write-code-list-${hand.deterministic.status}`;
  if (hand.input_insufficient === true) return "input-insufficient";
  return hand.jev && hand.jev.status !== "ok" ? hand.jev.status : null;
}

function adoptedOf(jevKeys, llmKeys) {
  if (jevKeys.length && llmKeys.length) return "mixed";
  return llmKeys.length ? "llm" : "jev";
}

// judgeComplexity(sid, tid, hand, adapter, normalize) -> {result, record}: the write-ahead payload.
function judgeComplexity(sid, tid, hand, adapter, normalize) {
  const delegated = arr(hand.delegated);
  const keyId = idOfKey(adapter);
  const needed = delegated.length > 0;
  const ans = needed ? readAnswer(hand.answer_file) : { received: false, raw: null };
  const parsed = needed && ans.received ? adapter.parseSubagent(ans.raw)
    : { status: "missing", csv: null, override: [] };
  const llmUndecidable = needed && (parsed.status === "missing" || parsed.csv === null
    || String(parsed.csv).split(",").includes(UNDECIDABLE_SIGNAL));
  const det = hand.deterministic;
  const detFail = Boolean(det) && det.status !== "ok";
  const llmSet = new Set(llmUndecidable ? [] : String(parsed.csv || "").split(",").filter(Boolean));
  const adoptedJev = hand.adopted_jev && typeof hand.adopted_jev === "object" ? hand.adopted_jev : {};
  const truth = new Set();
  if (det && det.status === "ok" && det.values) for (const id of DETERMINISTIC_SIGNAL_IDS) if (det.values[id] === true) truth.add(id);
  for (const k of Object.keys(adoptedJev)) if (adoptedJev[k] === true && keyId[k]) truth.add(keyId[k]);
  for (const k of delegated) if (keyId[k] && llmSet.has(keyId[k])) truth.add(keyId[k]);
  const signals = SIGNAL_IDS.filter((id) => truth.has(id));
  const undecidable = llmUndecidable || detFail;
  const scope = (llmUndecidable ? delegated.map((k) => keyId[k]).filter(Boolean) : [])
    .concat(detFail ? DETERMINISTIC_SIGNAL_IDS : []);
  const mergedLine = undecidable ? `SIGNALS: ${UNDECIDABLE_SIGNAL}` : adapter.toContractLine(signals);
  const signalsCsv = normalize(mergedLine);
  if (typeof signalsCsv !== "string") throw new Error("normalize failed on the merged line");
  const adopted = adoptedOf(Object.keys(adoptedJev), delegated);
  const answerReason = answerFallbackOf(needed, ans.received, parsed.status);
  const unjudgedSignals = arr(hand.unjudged).map((k) => keyId[k]).filter(Boolean);
  const record = ticketRecord(sid, tid, hand, {
    llm: {
      status: needed && ans.received ? parsed.status : "missing",
      answer: needed && ans.received && parsed.status !== "missing" ? parsed.csv : null,
      executor_model: adapter.resolveExecutorModel(undefined), latency_ms: null,
    },
    adopted, received: needed && ans.received,
    deterministic: deterministicRecord(det, arr(parsed.override)),
    final: {
      signals, undecidable, undecidable_scope: scope, unjudged_signals: unjudgedSignals,
      contract_line: mergedLine, signals_csv: signalsCsv,
    },
    fallback: fallbackOf(hand, answerReason, detFail),
  });
  const fallback = answerReason || detFail ? record.fallback_reason : null;
  return { result: { stage: hand.stage, merged_line: mergedLine, signals_csv: signalsCsv, adopted, fallback }, record };
}

// The record of a ticket nobody finalized: observation only, no result.
function absentRecord(sid, tid, hand, adapter) {
  let received = false;
  try { received = fs.statSync(hand.answer_file).isFile(); } catch (_e) { received = false; }
  const rec = ticketRecord(sid, tid, hand, {
    llm: { status: "missing", answer: null, executor_model: adapter.resolveExecutorModel(undefined), latency_ms: null },
    adopted: null, received, deterministic: hand.deterministic || null, final: null, fallback: "finalize-absent",
  });
  if (adapter.executor && rec.llm) rec.llm.executor = adapter.executor;
  return rec;
}

module.exports = { MAX_ANSWER_BYTES, readAnswer, ticketRecord, adoptedOf, answerFallbackOf, judgeComplexity, absentRecord };
