"use strict";
// bin/lib/jev-report-aggregate.js — the aggregation behind bin/jev-report (#2460): reads
// every rotated generation of the decision log (.3 oldest ... base newest) and hands each
// record to the section that owns its version. Dispatch and re-export only:
//   ./jev-report-aggregate/select.js    version routing, ticket dedupe, superseded tickets
//   ./jev-report-aggregate/legacy.js    v1 records (shadow period): Jev compared with the LLM
//   ./jev-report-aggregate/adoption.js  v2 decisions: who decided, LLM call and short-circuit rates
//   ./jev-report-aggregate/retune.js    v2 decisions of the skip points: agreement and RETUNE_POLICY
// docs/architecture/jev.md owns the report semantics.

const fs = require("fs");
const { routeByVersion, selectV2Decisions } = require("./jev-report-aggregate/select");
const { percentile, aggregatePoint, formatLegacy } = require("./jev-report-aggregate/legacy");
const { aggregateAdoption, formatAdoption } = require("./jev-report-aggregate/adoption");
const { RETUNE_POLICY, aggregateRetune, formatRetune } = require("./jev-report-aggregate/retune");

const GENERATIONS = [".3", ".2", ".1", ""];

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

// points: the legacy (v1) summary per point; adoption / retune: the v2 sections.
// thresholdFor(point) -> the low-confidence cut of the legacy summary.
// Maps keyed by a log-derived string have no prototype: "constructor" or "__proto__" is
// then an ordinary key instead of an inherited property.
function aggregate({ records, broken, unreadable }, { point, thresholdFor }) {
  const routed = routeByVersion(point ? records.filter((r) => r.point === point) : records);
  const groups = Object.create(null);
  for (const r of routed.v1) (groups[r.point] = groups[r.point] || []).push(r);
  const points = Object.create(null);
  for (const name of Object.keys(groups).sort()) points[name] = aggregatePoint(groups[name], thresholdFor(name));
  const selected = selectV2Decisions(routed.v2);
  return {
    points,
    adoption: aggregateAdoption(selected),
    retune: aggregateRetune(selected.decisions, { point }),
    unknown_version: routed.unknown_version,
    unknown_record_type: selected.unknown_record_type,
    duplicate_ticket_records: selected.duplicate_ticket_records,
    superseded_count: selected.superseded_count,
    broken_lines: broken,
    unreadable_generations: Array.isArray(unreadable) ? unreadable : [],
  };
}

// --json keeps the raw log values (JSON-escaped); the text sections sanitise what they print.
function formatText(result) {
  const out = [];
  if (!Object.keys(result.points).length && !result.adoption.overall.count) out.push("jev-report: no records");
  out.push(...formatLegacy(result.points), ...formatAdoption(result.adoption), ...formatRetune(result.retune));
  out.push(`unknown_version: ${result.unknown_version}`);
  out.push(`unknown_record_type: ${result.unknown_record_type}`);
  out.push(`duplicate_ticket_records: ${result.duplicate_ticket_records}`);
  out.push(`superseded_count: ${result.superseded_count}`);
  out.push(`broken lines: ${result.broken_lines}`);
  const unreadable = result.unreadable_generations || [];
  if (unreadable.length) out.push(`unreadable generations: ${unreadable.length} (${unreadable.join(" ")})`);
  return out.join("\n") + "\n";
}

module.exports = { readLog, percentile, aggregatePoint, aggregate, formatText, GENERATIONS, RETUNE_POLICY };
