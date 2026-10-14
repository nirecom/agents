"use strict";
// bin/lib/jev-report-aggregate/adoption.js — the adoption section of bin/jev-report: who
// decided each v2 judgment, per point and overall. Reads only the decisions
// selectV2Decisions kept (one per ticket, superseded tickets left out).
// llm_needed_rate is the share of tickets for which the CLI requested a subagent dispatch;
// the dispatch itself is not observed. Log-derived names are counted under a fixed
// vocabulary ("other" for the rest), so a hostile log adds no key and prints no text.

const path = require("path");
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const { MODES, registryEntry } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "registry.js"));
const { sanitizeEnum } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "sanitize.js"));
const { STAGE_SOURCE_SECTIONS } = require(path.join(SCRIPT_CHECKOUT_ROOT, "bin", "workflow", "lib", "jev-request-common.js"));
const { isObj, own, ratio, fmt, bump, pairs } = require("./util");

const ADOPTED = Object.freeze(["jev", "llm", "mixed"]);
const LIST_FAILSAFES = Object.freeze(["missing", "invalid", "copy-failed"]);
const SOURCE_FAIL_REASONS = Object.freeze(["copy-failed", "over-cap"]);
const SECTIONS = Object.freeze([...new Set(Object.values(STAGE_SOURCE_SECTIONS).flat())]);
const OTHER = "other";

const zeroed = (keys) => Object.fromEntries(keys.map((k) => [k, 0]));
const known = (list, v) => (typeof v === "string" && list.includes(v) ? v : OTHER);

function summarize(recs, supersededCount) {
  const adopted = zeroed(ADOPTED);
  const byMode = zeroed(MODES);
  const failsafe = zeroed(LIST_FAILSAFES);
  const bySection = Object.create(null);
  const byReason = zeroed(SOURCE_FAIL_REASONS);
  let needed = 0;
  let received = 0;
  let shortCircuited = 0;
  let override = 0;
  let finalizeAbsent = 0;
  let insufficient = 0;
  for (const r of recs) {
    if (ADOPTED.includes(r.adopted)) adopted[r.adopted]++;
    bump(byMode, known(MODES, r.mode));
    if (r.llm_needed === true) {
      needed++;
      if (r.llm_answer_received === true) received++;
    }
    if (r.short_circuited === true) shortCircuited++;
    const det = isObj(r.deterministic) ? r.deterministic : {};
    if (Array.isArray(det.override) && det.override.length > 0) override++;
    if (LIST_FAILSAFES.includes(det.status)) failsafe[det.status]++;
    if (r.fallback_reason === "finalize-absent") finalizeAbsent++;
    const input = isObj(r.input) ? r.input : {};
    if (Array.isArray(input.missing) && input.missing.length > 0) {
      insufficient++;
      for (const s of new Set(input.missing.map((x) => known(SECTIONS, x)))) bump(bySection, s);
    }
    const reasons = isObj(input.sources_failed_reasons) ? input.sources_failed_reasons : {};
    for (const k of Object.keys(reasons)) bump(byReason, known(SOURCE_FAIL_REASONS, reasons[k]));
  }
  return {
    count: recs.length,
    adopted,
    by_mode: byMode,
    llm_needed_rate: ratio(needed, recs.length),
    llm_answer_received_rate: ratio(received, needed),
    answer_missing: needed - received,
    short_circuit_count: shortCircuited,
    short_circuit_rate: ratio(shortCircuited, recs.length),
    deterministic_override: override,
    write_code_list_failsafe: failsafe,
    finalize_absent: finalizeAbsent,
    input_insufficient: insufficient,
    input_insufficient_by_section: Object.assign({}, bySection),
    sources_failed_by_reason: byReason,
    superseded_count: supersededCount,
  };
}

// {overall, points}: points holds every point with a kept decision or a superseded ticket.
function aggregateAdoption(selected) {
  const groups = Object.create(null);
  for (const r of selected.decisions) (groups[r.point] = groups[r.point] || []).push(r);
  for (const name of Object.keys(selected.superseded_by_point)) groups[name] = groups[name] || [];
  const points = Object.create(null);
  for (const name of Object.keys(groups).sort()) {
    const sup = own(selected.superseded_by_point, name) ? selected.superseded_by_point[name] : 0;
    points[name] = summarize(groups[name], sup);
  }
  return { overall: summarize(selected.decisions, selected.superseded_count), points };
}

// A point whose registry entry never short-circuits has no short-circuit rate to show.
function neverShortCircuits(point) {
  const e = registryEntry(point);
  return Boolean(e) && e.short_circuit_answer === null;
}

function rows(label, a, noShortCircuit) {
  const sc = noShortCircuit ? "no short-circuit" : `short-circuit rate=${fmt(a.short_circuit_rate)} (${a.short_circuit_count})`;
  return [
    `${label}: decisions=${a.count} LLM call rate=${fmt(a.llm_needed_rate)} answer-received rate=${fmt(a.llm_answer_received_rate)} ` +
      `answer_missing=${a.answer_missing} ${sc}`,
    `${label}: adopted ${pairs(a.adopted)} | by_mode ${pairs(a.by_mode)} | superseded_count=${a.superseded_count}`,
    `${label}: finalize_absent=${a.finalize_absent} deterministic_override=${a.deterministic_override} ` +
      `write_code_list_failsafe ${pairs(a.write_code_list_failsafe)}`,
    `${label}: input_insufficient=${a.input_insufficient} by section ${pairs(a.input_insufficient_by_section, (k) => k.replace(/ /g, "_"))} ` +
      `| sources_failed ${pairs(a.sources_failed_by_reason)}`,
  ];
}

function formatAdoption(adoption) {
  const out = ["-- adoption (v2 decisions) --"];
  if (!adoption.overall.count && !Object.keys(adoption.points).length) return out.concat("no v2 decisions");
  out.push("LLM call rate = tickets for which the CLI requested a subagent dispatch / decisions (the dispatch itself is not observed)");
  out.push(...rows("overall", adoption.overall, false));
  for (const name of Object.keys(adoption.points)) out.push(...rows(sanitizeEnum(name), adoption.points[name], neverShortCircuits(name)));
  return out;
}

module.exports = { aggregateAdoption, formatAdoption };
