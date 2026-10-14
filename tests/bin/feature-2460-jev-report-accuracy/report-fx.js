"use strict";
// Fixture builder and JSON query helper for tests/bin/feature-2460-jev-report-accuracy.sh (#2460).
//   node report-fx.js build <out-log> <js-expr>  -- writes one log line per element of the
//     (deep-flattened) array <js-expr> evaluates to; strings are written raw, objects as JSON.
//     Builders in scope: D (v2 decision), S (v2 settle), V1 (v1 record), range(n, f).
//   node report-fx.js q <report-json> <js-expr>  -- evaluates <js-expr> over the --json report
//     with accessors in scope; a throw prints THROW:<message> instead of a stack trace.
// The v2 shape follows the detail plan's decision log v2 (record_type, ticket, two-way
// threshold, short_circuited, unjudged_keys, llm_needed / llm_answer_received, input.missing,
// input.sources_failed(_reasons), deterministic.override, agreement_by_signal).

const fs = require("fs");

// Pinned --json report contract (o = the report): o.points[<pt>] is the legacy v1 summary;
// o.unknown_version, o.duplicate_ticket_records, o.superseded_count; o.adoption.overall and
// o.adoption.points[<pt>] carry count, adopted{jev,llm,mixed}, by_mode, llm_needed_rate,
// llm_answer_received_rate, answer_missing, short_circuit_count, short_circuit_rate,
// deterministic_override, write_code_list_failsafe{missing,invalid,copy-failed}, finalize_absent,
// input_insufficient, input_insufficient_by_section, sources_failed_by_reason, superseded_count;
// o.retune.points[<skip pt>] carries agreement_by_signal{<key>:{n,rate}}, run_direction{n,rate}
// and candidates{"0.7"|"0.8": {t, by_key{<key>:{n,agree,rate}}, retune_ready}}.
const POINTS = {
  "complexity-judge": { thr: { true: 0.7, false: 0.7 }, sc: null, stage: "complexity",
    keys: ["S2-architecture", "S3-security", "S5-breaking"], sub: "complexity-judge" },
  "outline-skip": { thr: { true: 0.9, false: 0.7 }, sc: false, stage: "outline",
    keys: ["so_c1", "so_c2"], sub: "plan-skip-judge" },
  "detail-skip": { thr: { true: 0.9, false: 0.7 }, sc: false, stage: "outline",
    keys: ["sd_single_approach", "sd_no_open_decision"], sub: "plan-skip-judge" },
};

let seq = 0;
const nextTicket = () => (0xabc00000 + ++seq).toString(16).padStart(16, "0");
const ts = () => "2026-10-02T00:" + String(Math.floor(seq / 60) % 60).padStart(2, "0") + ":" + String(seq % 60).padStart(2, "0") + "Z";
const perKey = (keys, v, dflt) => Object.fromEntries(keys.map((k) => [k,
  v !== null && typeof v === "object" ? (v[k] !== undefined ? v[k] : dflt) : (v !== undefined ? v : dflt)]));

// D(o): one v2 decision record. o.point (default detail-skip), o.p (number or {key: p},
// default 0.8), o.sub (subagent answer: boolean or {key: bool}; undefined = answer file absent;
// "no-answer" = file present, nothing parsable), o.mode, o.thr, o.ticket (null = hook record),
// o.orphan, o.missing (input-insufficient sections), o.sf ({section: copy-failed|over-cap}),
// o.override (deterministic.override list), o.wcl (write-code list failsafe kind), o.top (merged last).
function D(o = {}) {
  seq++;
  const point = o.point || "detail-skip";
  const P = POINTS[point];
  const keys = P.keys;
  const thr = o.thr || P.thr;
  const mode = o.mode || "production";
  const missing = o.missing || [];
  const jevUsed = missing.length === 0 && !o.jevDown;
  const p = jevUsed ? perKey(keys, o.p, 0.8) : null;
  const adoptedVals = {};
  let delegated = [];
  for (const k of keys) {
    if (!jevUsed || mode === "shadow") { delegated.push(k); continue; }
    const ans = p[k] >= 0.5;
    const conf = Math.max(p[k], 1 - p[k]);
    if (conf >= thr[String(ans)]) adoptedVals[k] = ans; else delegated.push(k);
  }
  const shortCircuited = P.sc !== null && Object.values(adoptedVals).some((v) => v === P.sc);
  const unjudged = shortCircuited ? delegated : [];
  if (shortCircuited) delegated = [];
  const llmNeeded = delegated.length > 0;
  let llm = null;
  let received = false;
  let subVals = null;
  if (llmNeeded) {
    if (o.sub === undefined || o.orphan) {
      llm = { status: "missing", answer: null, executor: P.sub, executor_model: "opus", latency_ms: null };
    } else if (o.sub === "no-answer") {
      received = true;
      llm = { status: "missing", answer: "NO_ANSWER", executor: P.sub, executor_model: "opus", latency_ms: 900 };
    } else {
      received = true;
      subVals = perKey(keys, o.sub, true);
      const answer = point === "complexity-judge"
        ? "SIGNALS: " + (keys.filter((k) => subVals[k]).join(", ") || "none")
        : "SKIP_CONDITIONS: " + keys.map((k) => k + "=" + subVals[k]).join(", ");
      llm = { status: "ok", answer, executor: P.sub, executor_model: "opus", latency_ms: 900 };
    }
  }
  const agreement = {};
  if (subVals && p) for (const k of keys) agreement[k] = (p[k] >= 0.5) === subVals[k];
  const finalVals = Object.assign({}, adoptedVals, subVals ? Object.fromEntries(delegated.map((k) => [k, subVals[k]])) : {});
  let adopted = delegated.length === 0 ? "jev" : Object.keys(adoptedVals).length === 0 ? "llm" : "mixed";
  let final = point === "complexity-judge"
    ? { signals_csv: keys.filter((k) => finalVals[k]).join(","), contract_line: "SIGNALS: " + (keys.filter((k) => finalVals[k]).join(", ") || "none") }
    : { skip: !shortCircuited && keys.every((k) => finalVals[k] === true), conditions: finalVals };
  let fallback = missing.length ? "input-insufficient" : (llmNeeded && !received ? "answer-file-absent" : null);
  if (o.orphan) { adopted = null; final = null; fallback = "finalize-absent"; }
  let deterministic = point === "complexity-judge"
    ? { status: "ok", values: { "S1b-wide-change": false, "S4-installer": false }, override: o.override || [], source_sha256: null }
    : null;
  if (o.wcl) {
    deterministic = { status: o.wcl, values: { "S1b-wide-change": false, "S4-installer": false }, override: [], source_sha256: null };
    fallback = "write-code-list-" + o.wcl;
  }
  const ticket = o.ticket === null ? null : (o.ticket || nextTicket());
  const sf = o.sf || {};
  const rec = {
    version: 2, record_type: "decision", ts: ts(), point, mode, adopted, threshold: thr,
    short_circuit_answer: P.sc, short_circuited: shortCircuited, unjudged_keys: unjudged,
    session_id: o.sid || "sid-v2", step: o.stage || P.stage, stage: o.stage || P.stage, ticket,
    tool_use_id: ticket === null ? "toolu_v2_" + seq : null,
    input: { bytes: 100, sha256: "0".repeat(64), truncated: false, sections: [], required: ["intent", "issue body"],
      missing, exempt: [], sources_failed: Object.keys(sf), sources_failed_reasons: sf },
    deterministic,
    jev: jevUsed
      ? { status: "ok", probabilities: p, min_confidence: Math.min(...keys.map((k) => Math.max(p[k], 1 - p[k]))),
        latency_ms: 100, model: "jev-1.13.0", input_tokens: 100, est_cost_usd: 0.00001 }
      : { status: missing.length ? "input-insufficient" : "no-key", probabilities: null, min_confidence: null,
        latency_ms: null, model: null, input_tokens: null, est_cost_usd: null },
    llm_needed: llmNeeded, llm_answer_received: received, llm, final,
    agreement_by_signal: agreement, fallback_reason: fallback,
  };
  return Object.assign(rec, o.top || {});
}

// S(o): a settle(superseded) record for o.ticket (o.point, o.detail default newer-owner).
function S(o = {}) {
  seq++;
  const point = o.point || "detail-skip";
  return Object.assign({ version: 2, record_type: "settle", ts: ts(), point, stage: o.stage || POINTS[point].stage,
    session_id: o.sid || "sid-v2", ticket: o.ticket, settle: "superseded", detail: o.detail || "newer-owner",
    owner: o.owner === undefined ? "f".repeat(16) : o.owner }, o.top || {});
}

// V1(o): a v1 (shadow-period) complexity-style record; o.point, o.agr (stored agreement).
function V1(o = {}) {
  seq++;
  const ids = ["S2-architecture", "S3-security", "S5-breaking"];
  return Object.assign({ v: 1, ts: ts(), point: o.point || "complexity-judge", mode: "shadow", adopted: "llm",
    session_id: "sid-v1", step: "outline", stage: "outline", tool_use_id: "toolu_v1_" + seq,
    input: { bytes: 10, sha256: "0".repeat(64), truncated: false, sources: [] },
    jev: { status: "ok", http_status: null, answer: "S2-architecture", probabilities: Object.fromEntries(ids.map((k) => [k, 0.02])),
      min_confidence: 0.98, latency_ms: 100, model: "jev-1.13.0", input_tokens: 100, est_cost_usd: 0.00001 },
    llm: { status: "ok", answer: "S2-architecture", executor: "complexity-judge", executor_model: "opus", latency_ms: 1000 },
    agreement: o.agr === undefined ? true : o.agr,
    agreement_by_signal: Object.fromEntries(ids.map((k) => [k, o.agr === undefined ? true : o.agr])),
    fallback_reason: null }, o.top || {});
}

const range = (n, f) => Array.from({ length: n }, (_, i) => f(i));

function build(out, expr) {
  // eslint-disable-next-line no-new-func
  const v = new Function("D", "S", "V1", "range", "POINTS", "return (" + expr + ");")(D, S, V1, range, POINTS);
  const flat = [].concat(v).flat(Infinity);
  fs.writeFileSync(out, flat.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join("\n") + "\n");
  process.stdout.write(String(flat.length));
}

function query(file, expr) {
  let o;
  try { o = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_e) { o = undefined; }
  const get = (x, ...ks) => ks.reduce((a, k) => (a !== null && a !== undefined && Object.prototype.hasOwnProperty.call(a, k) ? a[k] : undefined), x);
  const A = (pt) => get(o, "adoption", "points", pt) || {};
  const AO = () => get(o, "adoption", "overall") || {};
  const R = (pt) => get(o, "retune", "points", pt) || {};
  const C = (pt, t) => get(o, "retune", "points", pt, "candidates", t) || {};
  const K = (pt, t, k) => get(o, "retune", "points", pt, "candidates", t, "by_key", k) || {};
  const L = (pt) => get(o, "points", pt) || {};
  const f4 = (x) => (typeof x === "number" ? x.toFixed(4) : String(x));
  try {
    // eslint-disable-next-line no-new-func
    const v = new Function("o", "get", "A", "AO", "R", "C", "K", "L", "f4", "return (" + expr + ");")(o, get, A, AO, R, C, K, L, f4);
    process.stdout.write(typeof v === "string" ? v : (v === undefined ? "undefined" : JSON.stringify(v)));
  } catch (e) {
    process.stdout.write("THROW:" + (e && e.message));
  }
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === "build") build(a, b);
else if (cmd === "q") query(a, b);
else { process.stderr.write("report-fx: unknown cmd\n"); process.exit(2); }
