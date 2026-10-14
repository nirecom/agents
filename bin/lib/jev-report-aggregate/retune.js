"use strict";
// bin/lib/jev-report-aggregate/retune.js — the retune section of bin/jev-report: for each
// skip point, how often Jev and the subagent agreed per key, and whether the skip-direction
// threshold could be lowered to a candidate t. Reads only the decisions selectV2Decisions kept.
// A candidate t is judged on the band [t, the record's own threshold.true) alone: those are
// the answers lowering the threshold would newly adopt. An answer at or above the current
// threshold is adopted either way, and a ticket whose every key was adopted has no subagent
// answer, so counting them would weigh the rate toward tickets that happened to have one.
// RETUNE_POLICY is the single owner of the condition's numbers; docs point here.

const path = require("path");
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const { REGISTRY, registryEntry } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "registry.js"));
const { isObj, own, ratio, isNum, fmt } = require("./util");

const RETUNE_POLICY = Object.freeze({
  candidate_thresholds: Object.freeze([0.7, 0.8]),
  min_skip_direction_records: 30,
  min_agreement: 0.95,
});
const SKIP_SIDE = 0.5;

// The skip points (registry entries with a `target`) and their keys, in registry order.
function skipPoints(only) {
  const out = [];
  for (const name of Object.keys(REGISTRY)) {
    const entry = registryEntry(name);
    if (!entry || !own(entry, "target") || (only && name !== only)) continue;
    out.push({ name, entry, keys: require(entry.adapter).keys(entry) });
  }
  return out;
}

const tally = () => ({ n: 0, agree: 0 });
const rated = (t) => ({ n: t.n, agree: t.agree, rate: ratio(t.agree, t.n) });

// Every (key, p, agreed, thresholds) of one record where both sides answered the key.
function answeredKeys(r, keys) {
  const jev = isObj(r.jev) ? r.jev : {};
  if (jev.status !== "ok" || !isObj(jev.probabilities) || !isObj(r.agreement_by_signal)) return [];
  const thr = isObj(r.threshold) ? r.threshold : {};
  const out = [];
  for (const key of keys) {
    if (!own(r.agreement_by_signal, key) || !own(jev.probabilities, key)) continue;
    const agreed = r.agreement_by_signal[key];
    const p = jev.probabilities[key];
    if (typeof agreed !== "boolean" || !isNum(p)) continue;
    out.push({ key, p, agreed, skipAt: thr.true, runAt: thr.false });
  }
  return out;
}

function retunePoint({ entry, keys }, recs) {
  const overall = Object.fromEntries(keys.map((k) => [k, tally()]));
  const run = tally();
  const cands = RETUNE_POLICY.candidate_thresholds.map((t) => ({ t, byKey: Object.fromEntries(keys.map((k) => [k, tally()])) }));
  for (const r of recs) {
    for (const a of answeredKeys(r, keys)) {
      const hit = (t) => { t.n++; if (a.agreed) t.agree++; };
      hit(overall[a.key]);
      if (a.p < SKIP_SIDE) {
        if (isNum(a.runAt) && 1 - a.p >= a.runAt) hit(run);
        continue;
      }
      if (!isNum(a.skipAt)) continue;
      for (const c of cands) if (c.t < a.skipAt && a.p >= c.t && a.p < a.skipAt) hit(c.byKey[a.key]);
    }
  }
  const candidates = {};
  for (const c of cands) {
    const byKey = Object.fromEntries(keys.map((k) => [k, rated(c.byKey[k])]));
    candidates[String(c.t)] = {
      t: c.t,
      by_key: byKey,
      retune_ready: keys.length > 0 && keys.every((k) =>
        byKey[k].n >= RETUNE_POLICY.min_skip_direction_records && byKey[k].rate >= RETUNE_POLICY.min_agreement),
    };
  }
  return {
    current_threshold: entry.confidence_threshold_by_answer.true,
    agreement_by_signal: Object.fromEntries(keys.map((k) => [k, { n: overall[k].n, rate: ratio(overall[k].agree, overall[k].n) }])),
    run_direction: { n: run.n, rate: ratio(run.agree, run.n) },
    candidates,
  };
}

// {points: {<skip point>: ...}} — every skip point is listed, with or without records.
function aggregateRetune(decisions, { point } = {}) {
  const points = {};
  for (const sp of skipPoints(point)) points[sp.name] = retunePoint(sp, decisions.filter((r) => r.point === sp.name));
  return { points };
}

function formatRetune(retune) {
  const names = Object.keys(retune.points);
  if (!names.length) return [];
  const out = ["-- retune (skip points, v2 decisions) --"];
  out.push(`retune_ready: every key has >= ${RETUNE_POLICY.min_skip_direction_records} skip-direction answers in the band ` +
    `and agreement >= ${RETUNE_POLICY.min_agreement}`);
  out.push("answers with p >= current threshold are left out: lowering the threshold does not change " +
    "whether they are adopted, and a ticket whose every key was adopted has no subagent answer");
  for (const name of names) {
    const p = retune.points[name];
    const keys = Object.keys(p.agreement_by_signal);
    out.push(`${name}: agreement_by_signal ${keys.map((k) => `${k}=${fmt(p.agreement_by_signal[k].rate)} (n=${p.agreement_by_signal[k].n})`).join(" ")}`);
    for (const c of Object.values(p.candidates)) {
      out.push(`${name}: candidate t=${c.t} skip-direction p in [${c.t}, ${p.current_threshold}) ` +
        `${keys.map((k) => `${k}=${c.by_key[k].agree}/${c.by_key[k].n} (${fmt(c.by_key[k].rate)})`).join(" ")} retune_ready=${c.retune_ready}`);
    }
    out.push(`${name}: run_direction ` + (p.run_direction.n
      ? `n=${p.run_direction.n} agreement=${fmt(p.run_direction.rate)}`
      : "no data (a production record short-circuits on an adopted run answer; shadow mode fills this)"));
  }
  return out;
}

module.exports = { RETUNE_POLICY, aggregateRetune, formatRetune };
