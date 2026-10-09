"use strict";
// bin/lib/jev-report-aggregate.js — pure aggregation behind bin/jev-report (#2460).
// Folds every rotated generation of the decision log (.3 oldest ... base newest) per point.
// Agreement counts only both-ok records where neither side answered S0-undecidable, so
// missing / parse-fallback never skew it; both-ok undecidable ones go under `undecidable`.
// The low-confidence reference likewise skips LLM S0 answers and reports its own n.
// Records are deduplicated per judgment first (duplicates_dropped). Latency covers every
// side whose call completed (LLM ok / parse-fallback; Jev ok / low-confidence /
// unmappable); the low-confidence rate's denominator is the answered Jev records.
// docs/architecture/jev.md owns the full report semantics.

const fs = require("fs");
const path = require("path");
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const { SIGNAL_IDS, UNDECIDABLE_SIGNAL } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "complexity-routing.js"));
const { violatesS1Implication, agreeSets, csvToSet, compare } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "decision-record.js"));
const { sanitizeEnum, sanitizeAnswerIds } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "sanitize.js"));
const { isValidId } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "state-paths.js"));

const GENERATIONS = [".3", ".2", ".1", ""];
const ISO_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;

// {records, broken, unreadable} over <log>.3, .2, .1 and <log>; absent generations are
// skipped, any other read failure is labelled ("base" or the suffix) in unreadable.
function readLog(logPath) {
  const records = [];
  const unreadable = [];
  let broken = 0;
  for (const suffix of GENERATIONS) {
    let text;
    try {
      text = fs.readFileSync(logPath + suffix, "utf8");
    } catch (e) {
      if (!e || e.code !== "ENOENT") unreadable.push(suffix || "base");
      continue;
    }
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) continue;
      let o;
      try { o = JSON.parse(line); } catch (_e) { broken++; continue; }
      if (!o || typeof o !== "object" || Array.isArray(o) || typeof o.point !== "string") { broken++; continue; }
      records.push(o);
    }
  }
  return { records, broken, unreadable };
}

// Nearest-rank percentile over the finite values; null when there are none.
function percentile(values, p) {
  const v = values.filter((x) => typeof x === "number" && Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const rank = Math.max(1, Math.ceil((p / 100) * v.length));
  return v[rank - 1];
}

function ratio(num, den) {
  return den > 0 ? num / den : null;
}

function perSignal(init) {
  return Object.fromEntries(SIGNAL_IDS.map((id) => [id, init]));
}

function isObj(x) {
  return x && typeof x === "object" && !Array.isArray(x);
}

const jevOf = (r) => (isObj(r.jev) ? r.jev : {});
const llmOf = (r) => (isObj(r.llm) ? r.llm : {});
const ANSWERED = new Set(["ok", "low-confidence"]);
// Sides whose call came back with a parsed response, even an unmappable one: their latency is real.
// Outage statuses (bad-response included) are not completed calls; a pre-POST unmappable has null latency.
const JEV_COMPLETED = new Set(["ok", "low-confidence", "unmappable"]);
const LLM_COMPLETED = new Set(["ok", "parse-fallback"]);
const UNRUN = new Set(["not-run", "missing"]);

const ran = (s) => typeof s === "string" && !UNRUN.has(s);

// How much of the judgment a record carries: an LLM answer first, then a Jev run.
function informativeness(r) {
  return (ran(llmOf(r).status) ? 2 : 0) + (ran(jevOf(r).status) ? 1 : 0);
}

// A Jev-only orphan plus the late post's LLM-only record are one judgment: the Jev-run
// record with the LLM-run record's llm block, compared by the record builder's rule.
function mergeSides(jevRec, llmRec) {
  const cmp = compare(jevOf(jevRec), llmOf(llmRec));
  return Object.assign({}, jevRec, { llm: llmRec.llm, agreement: cmp.agreement, agreement_by_signal: cmp.agreement_by_signal });
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

function completedLatencies(recs, sideOf, completed) {
  return recs.filter((r) => completed.has(sideOf(r).status)).map((r) => sideOf(r).latency_ms);
}

// One point's summary. threshold: the point's confidence threshold (low-confidence cut).
function aggregatePoint(allRecs, threshold) {
  const { kept: recs, dropped } = dedupeRecords(allRecs);
  const jevLat = completedLatencies(recs, jevOf, JEV_COMPLETED);
  const llmLat = completedLatencies(recs, llmOf, LLM_COMPLETED);
  const byStage = Object.create(null);
  for (const r of recs) {
    const s = typeof r.stage === "string" ? r.stage : "unknown";
    byStage[s] = (byStage[s] || 0) + 1;
  }

  const compared = recs.filter((r) => typeof r.agreement === "boolean");
  const agreeBySig = perSignal(0);
  const agreeBySigN = perSignal(0);
  for (const r of compared) {
    if (!isObj(r.agreement_by_signal)) continue;
    for (const id of SIGNAL_IDS) {
      if (typeof r.agreement_by_signal[id] !== "boolean") continue;
      agreeBySigN[id]++;
      if (r.agreement_by_signal[id]) agreeBySig[id]++;
    }
  }

  // Low-confidence columns: which signal drags min_confidence below the bar, and how the
  // p>=0.5 reading of low-confidence answers would have compared with the LLM.
  const withProbs = recs.filter((r) => ANSWERED.has(jevOf(r).status) && isObj(jevOf(r).probabilities));
  const lowBySig = perSignal(0);
  for (const r of withProbs) {
    const pr = jevOf(r).probabilities;
    for (const id of SIGNAL_IDS) {
      const p = pr[id];
      if (typeof p === "number" && Number.isFinite(p) && Math.max(p, 1 - p) < threshold) lowBySig[id]++;
    }
  }
  // An LLM S0-undecidable answer carries no per-signal truth, so it is skipped and counted.
  const refAgree = perSignal(0);
  let refN = 0;
  let refLlmUndecidable = 0;
  for (const r of recs) {
    const j = jevOf(r);
    const l = llmOf(r);
    if (j.status !== "low-confidence" || l.status !== "ok" || !isObj(j.probabilities)) continue;
    const llmSet = csvToSet(l.answer);
    if (llmSet.has(UNDECIDABLE_SIGNAL)) { refLlmUndecidable++; continue; }
    refN++;
    const ref = new Set(SIGNAL_IDS.filter((id) => typeof j.probabilities[id] === "number" && j.probabilities[id] >= 0.5));
    const bySignal = agreeSets(ref, llmSet).agreement_by_signal;
    for (const id of SIGNAL_IDS) if (bySignal[id]) refAgree[id]++;
  }

  const undecidable = { n: 0, jev: 0, llm: 0 };
  for (const r of recs) {
    const j = jevOf(r);
    const l = llmOf(r);
    if (j.status !== "ok" || l.status !== "ok") continue;
    const ju = csvToSet(j.answer).has(UNDECIDABLE_SIGNAL);
    const lu = csvToSet(l.answer).has(UNDECIDABLE_SIGNAL);
    if (ju) undecidable.jev++;
    if (lu) undecidable.llm++;
    if (ju || lu) undecidable.n++;
  }

  // The raw S1b-without-S1 rubric gap per side (such a record scores as disagreement).
  const s1bWithoutS1 = { jev: 0, llm: 0 };
  for (const r of recs) {
    for (const [side, sideOf] of [["jev", jevOf], ["llm", llmOf]]) {
      if (sideOf(r).status !== "ok") continue;
      if (violatesS1Implication(csvToSet(sideOf(r).answer))) s1bWithoutS1[side]++;
    }
  }

  const fallbackReasons = Object.create(null);
  let fallbackN = 0;
  for (const r of recs) {
    if (typeof r.fallback_reason !== "string") continue;
    fallbackN++;
    fallbackReasons[r.fallback_reason] = (fallbackReasons[r.fallback_reason] || 0) + 1;
  }

  let cost = 0;
  for (const r of recs) {
    const c = jevOf(r).est_cost_usd;
    if (typeof c === "number" && Number.isFinite(c)) cost += c;
  }

  return {
    count: recs.length,
    by_stage: byStage,
    agreement_rate: ratio(compared.filter((r) => r.agreement).length, compared.length),
    agreement_n: compared.length,
    undecidable,
    s1b_without_s1: s1bWithoutS1,
    agreement_by_signal: Object.fromEntries(SIGNAL_IDS.map((id) => [id, ratio(agreeBySig[id], agreeBySigN[id])])),
    missing: recs.filter((r) => llmOf(r).status === "missing").length,
    parse_fallback: recs.filter((r) => llmOf(r).status === "parse-fallback").length,
    low_confidence_rate_by_signal: Object.fromEntries(SIGNAL_IDS.map((id) => [id, ratio(lowBySig[id], withProbs.length)])),
    low_confidence_rate_n: withProbs.length,
    low_confidence_reference_by_signal: Object.fromEntries(SIGNAL_IDS.map((id) => [id, ratio(refAgree[id], refN)])),
    low_confidence_reference_n: refN,
    low_confidence_reference_llm_undecidable: refLlmUndecidable,
    mismatches: compared.filter((r) => r.agreement === false).map((r) => ({
      ts: r.ts === undefined ? null : r.ts,
      session_id: r.session_id === undefined ? null : r.session_id,
      stage: r.stage === undefined ? null : r.stage,
      jev: jevOf(r).answer === undefined ? null : jevOf(r).answer,
      llm: llmOf(r).answer === undefined ? null : llmOf(r).answer,
    })),
    latency_ms: {
      jev: { p50: percentile(jevLat, 50), p95: percentile(jevLat, 95) },
      llm: { p50: percentile(llmLat, 50), p95: percentile(llmLat, 95) },
    },
    duplicates_dropped: dropped,
    fallback_rate: ratio(fallbackN, recs.length),
    fallback_reasons: fallbackReasons,
    est_cost_usd_total: cost,
  };
}

// {points: {<point>: summary}, broken_lines, unreadable_generations}. thresholdFor(point) -> number.
// Maps keyed by a log-derived string have no prototype: "constructor" or "__proto__" is
// then an ordinary key instead of an inherited property.
function aggregate({ records, broken, unreadable }, { point, thresholdFor }) {
  const groups = Object.create(null);
  for (const r of records) {
    if (point && r.point !== point) continue;
    (groups[r.point] = groups[r.point] || []).push(r);
  }
  const points = Object.create(null);
  for (const name of Object.keys(groups).sort()) points[name] = aggregatePoint(groups[name], thresholdFor(name));
  return { points, broken_lines: broken, unreadable_generations: Array.isArray(unreadable) ? unreadable : [] };
}

function fmt(x, digits = 3) {
  if (x === null || x === undefined) return "n/a";
  return typeof x === "number" ? String(Number(x.toFixed(digits))) : String(x);
}

function safeTs(ts) {
  if (typeof ts === "number" && Number.isFinite(ts)) return String(ts);
  return typeof ts === "string" && ISO_TS_RE.test(ts) ? ts : "-";
}

// Log-derived strings are untrusted on a terminal: each goes through a sanitiser that
// prints "-" for anything outside its charset. --json keeps the raw values (JSON-escaped).
function formatText(result) {
  const out = [];
  const names = Object.keys(result.points);
  if (!names.length) out.push("jev-report: no records");
  for (const name of names) {
    const p = result.points[name];
    out.push(`== ${sanitizeEnum(name)} ==`);
    out.push(`records: ${p.count}  by stage: ${Object.entries(p.by_stage).map(([k, v]) => `${sanitizeEnum(k)}=${v}`).join(" ") || "-"}`);
    out.push(`agreement: ${fmt(p.agreement_rate)} (n=${p.agreement_n})  missing: ${p.missing}  parse-fallback: ${p.parse_fallback}`);
    out.push(`undecidable: ${p.undecidable.n} (jev=${p.undecidable.jev} llm=${p.undecidable.llm})`);
    out.push(`S1b without S1: jev=${p.s1b_without_s1.jev} llm=${p.s1b_without_s1.llm}`);
    out.push(`agreement by signal: ${Object.entries(p.agreement_by_signal).map(([k, v]) => `${k}=${fmt(v)}`).join(" ")}`);
    out.push(`low-confidence rate by signal: ${Object.entries(p.low_confidence_rate_by_signal).map(([k, v]) => `${k}=${fmt(v)}`).join(" ")}` +
      `  (n=${p.low_confidence_rate_n})`);
    out.push(`low-confidence reference by signal: ${Object.entries(p.low_confidence_reference_by_signal).map(([k, v]) => `${k}=${fmt(v)}`).join(" ")}` +
      `  (n=${p.low_confidence_reference_n} llm-undecidable=${p.low_confidence_reference_llm_undecidable})`);
    out.push(`latency ms: jev p50=${fmt(p.latency_ms.jev.p50)} p95=${fmt(p.latency_ms.jev.p95)}  llm p50=${fmt(p.latency_ms.llm.p50)} p95=${fmt(p.latency_ms.llm.p95)}`);
    out.push(`fallback: ${fmt(p.fallback_rate)}  ${Object.entries(p.fallback_reasons).map(([k, v]) => `${sanitizeEnum(k)}=${v}`).join(" ")}`);
    out.push(`est cost usd total: ${fmt(p.est_cost_usd_total, 6)}`);
    out.push(`duplicates dropped: ${p.duplicates_dropped}`);
    out.push(`mismatches: ${p.mismatches.length}`);
    for (const m of p.mismatches) {
      out.push(`  ${safeTs(m.ts)} ${isValidId(m.session_id) ? m.session_id : "-"} ${sanitizeEnum(m.stage)} ` +
        `jev=${sanitizeAnswerIds(m.jev)} llm=${sanitizeAnswerIds(m.llm)}`);
    }
  }
  out.push(`broken lines: ${result.broken_lines}`);
  const unreadable = result.unreadable_generations || [];
  if (unreadable.length) out.push(`unreadable generations: ${unreadable.length} (${unreadable.join(" ")})`);
  return out.join("\n") + "\n";
}

module.exports = { readLog, percentile, aggregatePoint, aggregate, formatText, GENERATIONS };
