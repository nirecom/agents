"use strict";
// hooks/lib/jev/two-stage/merge-skip.js — finalize's judgment for outline-skip / detail-skip
// (#2460): Jev-adopted keys plus the delegated keys from plan-skip-judge's answer file, every
// key without a value filled false, and the decision record. The raw answer is never stored:
// the record keeps only the canonical SKIP_CONDITIONS: line rebuilt from the parsed values.

const { readAnswer, ticketRecord, adoptedOf } = require("./merge");

const arr = (v) => (Array.isArray(v) ? v : []);
const obj = (v) => (v && typeof v === "object" ? v : {});

// A missing input is the root cause even when the subagent's answer is also absent.
function fallbackOf(hand, needed, received) {
  if (hand.input_insufficient === true) return "input-insufficient";
  if (needed && !received) return "answer-file-absent";
  return hand.jev && hand.jev.status !== "ok" ? hand.jev.status : null;
}

// {key: (Jev p >= 0.5) === subagent value} over every answered key Jev gave a probability.
function agreementBySignal(hand, answered) {
  const probs = obj(hand.jev && hand.jev.probabilities);
  const out = {};
  for (const k of Object.keys(answered)) {
    const p = probs[k];
    if (typeof p === "number" && Number.isFinite(p)) out[k] = (p >= 0.5) === answered[k];
  }
  return out;
}

// judgeSkip(sid, tid, hand, adapter) -> {result, record}: the write-ahead payload.
function judgeSkip(sid, tid, hand, adapter) {
  const target = hand.target;
  const delegated = arr(hand.delegated);
  const needed = delegated.length > 0;
  const ans = needed ? readAnswer(hand.answer_file) : { received: false, raw: null };
  const parsed = needed && ans.received ? adapter.parseSubagent(ans.raw, target)
    : { status: "missing", values: adapter.fillConditions(target, {}), answered: {} };
  const adoptedJev = obj(hand.adopted_jev);
  const values = {};
  for (const k of Object.keys(adoptedJev)) values[k] = adoptedJev[k] === true;
  for (const k of delegated) values[k] = parsed.values[k] === true;
  const conditions = adapter.fillConditions(target, values);
  const skip = Object.values(conditions).every((v) => v === true);
  const adopted = adoptedOf(Object.keys(adoptedJev), delegated);
  const trueKeys = Object.keys(parsed.answered).filter((k) => parsed.answered[k] === true);
  const llm = {
    status: needed && ans.received ? parsed.status : "missing",
    answer: needed && ans.received && parsed.status !== "missing" ? adapter.toContractLine(trueKeys, hand) : null,
    executor_model: adapter.resolveExecutorModel(undefined), latency_ms: null,
  };
  const record = ticketRecord(sid, tid, hand, {
    llm, adopted, received: needed && ans.received, deterministic: null,
    final: { conditions, skip }, fallback: fallbackOf(hand, needed, ans.received),
  });
  if (!needed) {
    Object.assign(record, { llm: null, agreement_by_signal: {}, agreement: null });
  } else {
    const by = agreementBySignal(hand, parsed.answered);
    const vals = Object.values(by);
    Object.assign(record, {
      llm: Object.assign({}, record.llm, { executor: adapter.executor }),
      agreement_by_signal: by, agreement: vals.length ? vals.every((v) => v === true) : null,
    });
  }
  const source = adapter.ADOPTED_TO_SOURCE[adopted];
  return { result: { target, stage: hand.stage, conditions, source, skip, adopted }, record };
}

module.exports = { judgeSkip };
