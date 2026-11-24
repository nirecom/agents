"use strict";
// bin/lib/review-threat-metrics/pre-boundary-stats.js — the v0 (pre boundary) measurement (#2020):
// rejected carrier rows of sessions created before the boundary and filed issues of that period,
// sampled 60 rows + 40 issues with a fixed seed (a short side topped up from the other, 100 at
// most), classified, and the answers kept once in the v0 cache under the plans dir.
const C = require("./common");
const K = require("./cache");
const { MODEL, classifierId, classify, valid } = require("./classify");
const { discrim } = require("./discrim");
const { issues } = require("./gh");
const { splitIssues } = require("./issue-source");

const bump = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };

// v0Dirs(at, excluded) — control dirs of sessions created before the boundary time whose concern
// journal has no row of boundary version v1 or later.
function v0Dirs(at, excluded) {
  return C.controlDirs().filter((d) => {
    const t = C.sessionTime(d.sid);
    if (t === null) bump(excluded, "no-state");
    else if (at !== null && t >= at) bump(excluded, "out-of-period");
    else if (C.hasPostBoundaryRows(d)) bump(excluded, "post-boundary-rows");
    else return true;
    return false;
  });
}

// answers(items, dir) — {byKey, status}: the v0 classification runs once. An existing cache is read
// as is and never added to; a text it lacks (another seed, later input) stays unclassified. Every
// answer is cached, an out-of-vocabulary one too, with the number of sampled findings sharing its
// text (count), so post-boundary weighs v0 per finding. A call that answered nothing throws (exit 5)
// before the cache is written: a partial cache would freeze the missing texts as unclassified.
function answers(items, dir) {
  const cache = K.readV0(dir);
  const status = K.comparison(cache, classifierId);
  const store = cache ? { ...cache.items } : {};
  const byKey = new Map(Object.entries(store).map(([k, a]) => [k, { ...a, valid: valid(a) }]));
  if (cache) return { byKey, status };
  const textOf = new Map();
  const count = {};
  for (const it of items) {
    const k = K.textKey(it.text);
    textOf.set(k, it.text);
    bump(count, k);
  }
  const todo = [...textOf.keys()];
  const got = classify(todo.map((k) => textOf.get(k)));
  const missed = got.filter((a) => !a.answered).length;
  if (missed) throw new Error(`the classifier answered no class for ${missed} of ${todo.length} v0 texts; the v0 cache is not written`);
  todo.forEach((k, n) => {
    byKey.set(k, got[n]);
    store[k] = { axisA: got[n].axisA, axisB: got[n].axisB, category: got[n].category, count: count[k] };
  });
  if (todo.length) K.writeV0(dir, { classifierId, model: MODEL, items: store });
  return { byKey, status: "comparable" };
}

function preBoundary(opts) {
  const at = C.boundaryAt();
  const excluded = {};
  const carrier = C.readCarrier(v0Dirs(at, excluded));
  const gh = issues(opts.repo);
  const split0 = splitIssues(gh.items, (t) => at === null || t < at);
  for (const [k, n] of Object.entries(split0.excluded)) bump(excluded, k, n);
  const v0Issues = split0.kept;
  const { carrier: sc, issues: si } = C.drawSample(carrier, v0Issues, opts.seed);
  const items = [...sc.map((r) => ({ source: "carrier", text: r.text })),
    ...si.flatMap((it) => it.findings.map((text) => ({ source: "issue", number: it.number, text })))];
  const { byKey, status } = answers(items, opts.plansDir);
  const table = C.handling();
  const rows = items.map((it) => {
    const a = byKey.get(K.textKey(it.text)) || { axisA: "", axisB: "", category: "", valid: false, missing: true };
    const kind = a.valid ? C.kindOf(a.category, a.axisA, table) : "invalid";
    return { source: it.source, ...(it.number === undefined ? {} : { number: it.number }), discrim: discrim(it.text),
      axisA: a.axisA, axisB: a.axisB, category: a.category, kind, valid: a.valid, unclassified: Boolean(a.missing) };
  });
  const ok = (src) => rows.filter((r) => r.valid && r.source === src);
  const bySource = { carrier: C.stats(ok("carrier")), issue: C.stats(ok("issue")) };
  const findingRows = gh.items.reduce((s, it) => s + it.findings.length, 0);
  return {
    mode: "pre-boundary", model: MODEL, classifierId, seed: opts.seed,
    boundary_version: "v0", boundary_at: at === null ? null : new Date(at).toISOString(),
    population_kind: "v0-population", denominator: "sampled rows with a valid classification", criteria_hash: C.criteriaHash(),
    population: { carrier: carrier.length, issue: v0Issues.length },
    sample: { carrier: sc.length, issue: si.length },
    issues: { repo_total: gh.repo_total, fetched: gh.fetched, with_findings: gh.items.filter((it) => it.findings.length).length,
      finding_rows: findingRows },
    excluded,
    invalid: rows.filter((r) => !r.valid && !r.unclassified).length,
    unclassified: rows.filter((r) => r.unclassified).length,
    v0_cache: { file: K.V0_FILE, status },
    by_source: bySource,
    weighted: C.weighted([{ pop: carrier.length, st: bySource.carrier }, { pop: v0Issues.length, st: bySource.issue }]),
    rows,
  };
}

module.exports = { preBoundary };
