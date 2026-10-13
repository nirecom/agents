"use strict";
// bin/lib/jev-report-aggregate/legacy.js — the legacy section of bin/jev-report: the v1
// records of the shadow period, where the LLM always answered and Jev was only compared.
// Agreement counts only both-ok records where neither side answered S0-undecidable, so
// missing / parse-fallback never skew it; both-ok undecidable ones go under `undecidable`.
// The low-confidence reference likewise skips LLM S0 answers and reports its own n.
// Records are deduplicated per judgment first (duplicates_dropped). Latency covers every
// side whose call completed (LLM ok / parse-fallback; Jev ok / low-confidence /
// unmappable); the low-confidence rate's denominator is the answered Jev records.
// A v1 record was written under the signal vocabulary of its time, so the per-signal
// columns cover the current ids plus the id-shaped keys the records themselves carry.

const path = require("path");
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const { SIGNAL_IDS, UNDECIDABLE_SIGNAL } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));
const { csvToSet } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "decision-record.js"));
const { sanitizeEnum, sanitizeAnswerIds } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "sanitize.js"));
const { isValidId } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "state-paths.js"));
const { isObj, ratio, isNum, fmt, bump } = require("./util");

const ISO_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;
const RECORDED_ID_RE = /^S[1-9][a-z]?-[a-z]{1,16}(-[a-z]{1,16}){0,2}$/;
const MAX_RECORDED_IDS = 32;

const jevOf = (r) => (isObj(r.jev) ? r.jev : {});
const llmOf = (r) => (isObj(r.llm) ? r.llm : {});
const ANSWERED = new Set(["ok", "low-confidence"]);
// Sides whose call came back with a parsed response, even an unmappable one: their latency is real.
// Outage statuses (bad-response included) are not completed calls; a pre-POST unmappable has null latency.
const JEV_COMPLETED = new Set(["ok", "low-confidence", "unmappable"]);
const LLM_COMPLETED = new Set(["ok", "parse-fallback"]);
const UNRUN = new Set(["not-run", "missing"]);
const ran = (s) => typeof s === "string" && !UNRUN.has(s);

// Nearest-rank percentile over the finite values; null when there are none.
function percentile(values, p) {
  const v = values.filter(isNum).sort((a, b) => a - b);
  if (!v.length) return null;
  return v[Math.max(1, Math.ceil((p / 100) * v.length)) - 1];
}

// The current signal ids plus the id-shaped per-signal keys of the records, sorted.
function signalIds(recs) {
  const recorded = new Set();
  for (const r of recs) {
    for (const src of [r.agreement_by_signal, jevOf(r).probabilities]) {
      if (!isObj(src)) continue;
      for (const k of Object.keys(src)) {
        if (recorded.size < MAX_RECORDED_IDS && RECORDED_ID_RE.test(k) && !SIGNAL_IDS.includes(k)) recorded.add(k);
      }
    }
  }
  return [...SIGNAL_IDS, ...recorded].sort();
}

// How much of the judgment a record carries: an LLM answer first, then a Jev run.
function informativeness(r) {
  return (ran(llmOf(r).status) ? 2 : 0) + (ran(jevOf(r).status) ? 1 : 0);
}

// A Jev-only orphan plus the late post's LLM-only record are one judgment: the Jev-run
// record with the LLM-run record's llm block. Compared here as a plain set comparison, so
// a later change to the v2 agreement rule never rewrites a v1 figure.
function mergeSides(jevRec, llmRec) {
  const j = jevOf(jevRec);
  const l = llmOf(llmRec);
  let agreement = null;
  let bySignal = null;
  if (j.status === "ok" && l.status === "ok") {
    const a = csvToSet(j.answer);
    const b = csvToSet(l.answer);
    if (!a.has(UNDECIDABLE_SIGNAL) && !b.has(UNDECIDABLE_SIGNAL)) {
      bySignal = {};
      for (const id of SIGNAL_IDS) bySignal[id] = a.has(id) === b.has(id);
      agreement = a.size === b.size && [...a].every((x) => b.has(x));
    }
  }
  return Object.assign({}, jevRec, { llm: llmRec.llm, agreement, agreement_by_signal: bySignal });
}

// One record per (session_id, tool_use_id): a late or duplicate post logs a second,
// less informative record for the same judgment. Ties keep the earliest (log order).
function dedupeRecords(recs) {
  const kept = [];
  const slot = new Map();
  let dropped = 0;
  for (const r of recs) {
    if (typeof r.tool_use_id !== "string" || r.tool_use_id === "") { kept.push(r); continue; }
    const key = JSON.stringify([r.session_id === undefined ? null : r.session_id, r.tool_use_id]);
    const g = slot.get(key);
    if (!g) {
      slot.set(key, { i: kept.length, best: r, jevRec: ran(jevOf(r).status) ? r : null, llmRec: ran(llmOf(r).status) ? r : null });
      kept.push(r);
      continue;
    }
    dropped++;
    if (informativeness(r) > informativeness(g.best)) g.best = r;
    if (!g.jevRec && ran(jevOf(r).status)) g.jevRec = r;
    if (!g.llmRec && ran(llmOf(r).status)) g.llmRec = r;
  }
  for (const g of slot.values()) {
    const split = informativeness(g.best) < 3 && g.jevRec && g.llmRec && g.jevRec !== g.llmRec;
    kept[g.i] = split ? mergeSides(g.jevRec, g.llmRec) : g.best;
  }
  return { kept, dropped };
}

const orNull = (x) => (x === undefined ? null : x);
const latencies = (recs, sideOf, completed) => recs.filter((r) => completed.has(sideOf(r).status)).map((r) => sideOf(r).latency_ms);
const span = (lat) => ({ p50: percentile(lat, 50), p95: percentile(lat, 95) });

// threshold: one number, or the registry's per-direction {true, false} pair.
function belowBar(p, threshold) {
  const bar = isObj(threshold) ? threshold[String(p >= 0.5)] : threshold;
  return Math.max(p, 1 - p) < bar;
}

// One point's summary over its v1 records. threshold: the low-confidence cut.
function aggregatePoint(allRecs, threshold) {
  const { kept: recs, dropped } = dedupeRecords(allRecs);
  const ids = signalIds(allRecs);
  const zero = () => Object.fromEntries(ids.map((id) => [id, 0]));
  const rates = (num, den) => Object.fromEntries(ids.map((id) => [id, ratio(num[id], typeof den === "number" ? den : den[id])]));
  const byStage = Object.create(null);
  for (const r of recs) bump(byStage, typeof r.stage === "string" ? r.stage : "unknown");

  const compared = recs.filter((r) => typeof r.agreement === "boolean");
  const agreeBySig = zero();
  const agreeBySigN = zero();
  for (const r of compared) {
    if (!isObj(r.agreement_by_signal)) continue;
    for (const id of ids) {
      if (typeof r.agreement_by_signal[id] !== "boolean") continue;
      agreeBySigN[id]++;
      if (r.agreement_by_signal[id]) agreeBySig[id]++;
    }
  }

  // Low-confidence columns: which signal drags min_confidence below the bar, and how the
  // p>=0.5 reading of low-confidence answers would have compared with the LLM.
  const withProbs = recs.filter((r) => ANSWERED.has(jevOf(r).status) && isObj(jevOf(r).probabilities));
  const lowBySig = zero();
  for (const r of withProbs) {
    for (const id of ids) {
      const p = jevOf(r).probabilities[id];
      if (isNum(p) && belowBar(p, threshold)) lowBySig[id]++;
    }
  }
  // An LLM S0-undecidable answer carries no per-signal truth, so it is skipped and counted.
  const refAgree = zero();
  let refN = 0;
  let refLlmUndecidable = 0;
  const undecidable = { n: 0, jev: 0, llm: 0 };
  const fallbackReasons = Object.create(null);
  let fallbackN = 0;
  let cost = 0;
  for (const r of recs) {
    const j = jevOf(r);
    const l = llmOf(r);
    if (j.status === "low-confidence" && l.status === "ok" && isObj(j.probabilities)) {
      const llmSet = csvToSet(l.answer);
      if (llmSet.has(UNDECIDABLE_SIGNAL)) refLlmUndecidable++;
      else {
        refN++;
        for (const id of ids) if ((isNum(j.probabilities[id]) && j.probabilities[id] >= 0.5) === llmSet.has(id)) refAgree[id]++;
      }
    }
    if (j.status === "ok" && l.status === "ok") {
      const ju = csvToSet(j.answer).has(UNDECIDABLE_SIGNAL);
      const lu = csvToSet(l.answer).has(UNDECIDABLE_SIGNAL);
      if (ju) undecidable.jev++;
      if (lu) undecidable.llm++;
      if (ju || lu) undecidable.n++;
    }
    if (typeof r.fallback_reason === "string") { fallbackN++; bump(fallbackReasons, r.fallback_reason); }
    if (isNum(j.est_cost_usd)) cost += j.est_cost_usd;
  }

  return {
    count: recs.length,
    by_stage: byStage,
    agreement_rate: ratio(compared.filter((r) => r.agreement).length, compared.length),
    agreement_n: compared.length,
    undecidable,
    agreement_by_signal: rates(agreeBySig, agreeBySigN),
    missing: recs.filter((r) => llmOf(r).status === "missing").length,
    parse_fallback: recs.filter((r) => llmOf(r).status === "parse-fallback").length,
    low_confidence_rate_by_signal: rates(lowBySig, withProbs.length),
    low_confidence_rate_n: withProbs.length,
    low_confidence_reference_by_signal: rates(refAgree, refN),
    low_confidence_reference_n: refN,
    low_confidence_reference_llm_undecidable: refLlmUndecidable,
    mismatches: compared.filter((r) => r.agreement === false).map((r) => ({
      ts: orNull(r.ts), session_id: orNull(r.session_id), stage: orNull(r.stage), jev: orNull(jevOf(r).answer), llm: orNull(llmOf(r).answer),
    })),
    latency_ms: { jev: span(latencies(recs, jevOf, JEV_COMPLETED)), llm: span(latencies(recs, llmOf, LLM_COMPLETED)) },
    duplicates_dropped: dropped,
    fallback_rate: ratio(fallbackN, recs.length),
    fallback_reasons: fallbackReasons,
    est_cost_usd_total: cost,
  };
}

function safeTs(ts) {
  if (isNum(ts)) return String(ts);
  return typeof ts === "string" && ISO_TS_RE.test(ts) ? ts : "-";
}

const kv = (map, key = (k) => k, val = (v) => v) => Object.entries(map).map(([k, v]) => `${key(k)}=${val(v)}`).join(" ");

// The legacy lines of one point. Log-derived strings are untrusted on a terminal: each
// goes through a sanitiser that prints "-" for anything outside its charset.
function formatLegacyPoint(name, p) {
  const ids = Object.keys(p.agreement_by_signal);
  const out = [
    `== ${sanitizeEnum(name)} ==`,
    `records: ${p.count}  by stage: ${kv(p.by_stage, sanitizeEnum) || "-"}`,
    `agreement: ${fmt(p.agreement_rate)} (n=${p.agreement_n})  missing: ${p.missing}  parse-fallback: ${p.parse_fallback}`,
    `undecidable: ${p.undecidable.n} (jev=${p.undecidable.jev} llm=${p.undecidable.llm})`,
    `agreement by signal: ${kv(p.agreement_by_signal, undefined, fmt)}`,
    `low-confidence rate by signal: ${kv(p.low_confidence_rate_by_signal, undefined, fmt)}  (n=${p.low_confidence_rate_n})`,
    `low-confidence reference by signal: ${kv(p.low_confidence_reference_by_signal, undefined, fmt)}` +
      `  (n=${p.low_confidence_reference_n} llm-undecidable=${p.low_confidence_reference_llm_undecidable})`,
    `latency ms: jev p50=${fmt(p.latency_ms.jev.p50)} p95=${fmt(p.latency_ms.jev.p95)}  llm p50=${fmt(p.latency_ms.llm.p50)} p95=${fmt(p.latency_ms.llm.p95)}`,
    `fallback: ${fmt(p.fallback_rate)}  ${kv(p.fallback_reasons, sanitizeEnum)}`,
    `est cost usd total: ${fmt(p.est_cost_usd_total, 6)}`,
    `duplicates dropped: ${p.duplicates_dropped}`,
    `mismatches: ${p.mismatches.length}`,
  ];
  for (const m of p.mismatches) {
    out.push(`  ${safeTs(m.ts)} ${isValidId(m.session_id) ? m.session_id : "-"} ${sanitizeEnum(m.stage)} ` +
      `jev=${sanitizeAnswerIds(m.jev, ids)} llm=${sanitizeAnswerIds(m.llm, ids)}`);
  }
  return out;
}

function formatLegacy(points) {
  const names = Object.keys(points);
  if (!names.length) return [];
  return ["-- legacy (v1, shadow period) --"].concat(...names.map((name) => formatLegacyPoint(name, points[name])));
}

module.exports = { percentile, dedupeRecords, aggregatePoint, formatLegacy };
