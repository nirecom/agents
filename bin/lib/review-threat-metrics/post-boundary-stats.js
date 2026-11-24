"use strict";
// bin/lib/review-threat-metrics/post-boundary-stats.js — the post boundary measurement (#2020).
// Per boundary version it reports two blocks that are never added together: the full population
// (every concern journal row of sessions created after the boundary, folded by (session, DISCRIM)),
// and the comparison subset (rejected carrier rows and filed-issue findings attributed through the
// journal, sampled by the pre boundary rule, classified and calibrated against the self tags).
// Each version is compared with its boundary baseline vN-1 (v1 with the v0 cache, subset only).
const C = require("./common");
const K = require("./cache");
const { MODEL, classifierId, classify, valid } = require("./classify");
const { discrim } = require("./discrim");
const { issues } = require("./gh");
const { splitIssues, journalIndex, attribute } = require("./issue-source");

const bump = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };
const tagged = (s) => /^A[0-6]$/.test(s.axisA) && /^B[0-3]$/.test(s.axisB);
const kindCounts = (self, n) => ({
  out_of_boundary: self.filter((s) => s.kind === "out-of-boundary").length,
  no_path: self.filter((s) => s.kind === "no-path").length,
  concern: self.filter((s) => s.kind === "concern").length,
  untagged: n - self.length,
});

// postDirs(at, excluded) — control dirs of sessions created at or after the boundary time, and of
// earlier sessions whose journal carries a v1-or-later row (the ones v0Dirs leaves out), so no
// session falls between the two measurements.
function postDirs(at, excluded) {
  return C.controlDirs().filter((d) => {
    const t = C.sessionTime(d.sid);
    if (t === null) bump(excluded, "no-state");
    else if ((at !== null && t >= at) || C.hasPostBoundaryRows(d)) return true;
    else bump(excluded, "out-of-period");
    return false;
  });
}

// journalUnits(idx, excluded) — Map of version to [rows of one (session, DISCRIM)], by the same
// attribution rule as the subset.
function journalUnits(idx, excluded) {
  const byV = new Map();
  for (const rows of idx.values()) {
    const a = attribute(idx, rows[0].sid, rows[0].discrim);
    if (a.excluded) bump(excluded, a.excluded);
    else if (byV.has(a.version)) byV.get(a.version).push(a.rows);
    else byV.set(a.version, [a.rows]);
  }
  return byV;
}

// subsetRows(opts, at, excluded, idx) — [{source, sid, discrim, version, self, text, number?}], each pair once.
function subsetRows(opts, at, excluded, idx) {
  const seen = new Set();
  const out = [];
  const add = (source, sid, d, text, number) => {
    if (seen.has(`${sid}\0${d}`)) return;
    seen.add(`${sid}\0${d}`);
    const a = attribute(idx, sid, d);
    if (a.excluded) bump(excluded, a.excluded);
    else out.push({ source, sid, discrim: d, version: a.version, self: a.rows[0], text, number });
  };
  for (const r of C.readCarrier(opts.dirs)) add("carrier", r.sid, r.id, r.text);
  const gh = issues(opts.repo);
  const sp = splitIssues(gh.items, (t) => at !== null && t >= at);
  for (const [k, n] of Object.entries(sp.excluded)) bump(excluded, k, n);
  for (const it of sp.kept) {
    if (!it.sid) bump(excluded, "no-marker");
    else it.findings.forEach((text, k) => add("issue", it.sid, discrim(it.raws[k]), text, it.number));
  }
  return out;
}

// sampleOf(rows, seed) — the version's subset sample: carrier rows, and issues drawn whole.
function sampleOf(rows, seed) {
  const groups = new Map();
  for (const r of rows.filter((x) => x.source === "issue")) {
    if (!groups.has(r.number)) groups.set(r.number, []);
    groups.get(r.number).push(r);
  }
  const s = C.drawSample(rows.filter((r) => r.source === "carrier"), [...groups.values()], seed);
  return { rows: [...s.carrier, ...s.issues.flat()], carrier: s.carrier.length, issue: s.issues.length };
}

// answers(rows, dir) — the classifier's answer per row: the subset cache, else a fresh call.
function answers(rows, dir) {
  const known = K.readSubset(dir, classifierId);
  const textOf = new Map(rows.map((r) => [K.textKey(r.text), r.text]));
  const todo = [...textOf.keys()].filter((k) => !known.has(k));
  const got = classify(todo.map((k) => textOf.get(k)));
  const fresh = [];
  todo.forEach((k, n) => {
    known.set(k, got[n]);
    if (got[n].valid) fresh.push({ key: k, axisA: got[n].axisA, axisB: got[n].axisB, category: got[n].category });
  });
  K.appendSubset(dir, classifierId, fresh);
  return rows.map((r) => {
    const a = known.get(K.textKey(r.text));
    return { axisA: a.axisA, axisB: a.axisB, category: a.category, valid: valid(a) };
  });
}

// v0Stats(cache, table) — the classifier's v0 ratios over every cached v0 finding: an answer counts
// once per sampled finding sharing its text (count; an entry without one counts once).
function v0Stats(cache, table) {
  const rows = Object.values(cache.items).filter(valid).flatMap((a) => {
    const n = Number.isInteger(a.count) && a.count > 0 ? a.count : 1;
    return Array(n).fill({ ...a, kind: C.kindOf(a.category, a.axisA, table) });
  });
  return C.stats(rows);
}

// fullBlock(units) — the full-population block over every attributed (session, DISCRIM) of a version.
function fullBlock(units) {
  const self = units.map((rows) => rows[0]).filter(tagged);
  return { population_kind: "all", denominator: "attributed journal findings (self tags: tagged findings)",
    journal_rows: units.reduce((s, rows) => s + rows.length, 0), findings: units.length,
    counts: kindCounts(self, units.length), self: C.stats(self) };
}

// subsetBlock(all, sampled, cls, table) — the comparison subset block; cls answers the sampled rows.
function subsetBlock(all, sampled, cls, table) {
  const self = sampled.rows.filter((r) => tagged(r.self)).map((r) => r.self);
  const byCls = cls.filter((a) => a.valid).map((a) => ({ ...a, kind: C.kindOf(a.category, a.axisA, table) }));
  const pairs = sampled.rows.map((r, k) => [r, cls[k]]).filter(([r, a]) => tagged(r.self) && a.valid);
  const agree = (f) => (pairs.length ? pairs.filter(([r, a]) => f(r, a)).length / pairs.length : 0);
  const selfStats = C.stats(self);
  return {
    population_kind: "sample", denominator: "sampled attributed rows (self tags: tagged rows; classifier: valid answers)",
    population: { carrier: all.filter((r) => r.source === "carrier").length, issue: all.filter((r) => r.source === "issue").length },
    sample: { carrier: sampled.carrier, issue: sampled.issue },
    counts: kindCounts(self, sampled.rows.length),
    classes: selfStats.classes,
    self: selfStats,
    classified: { ...C.stats(byCls), invalid: cls.length - byCls.length },
    calibration: { compared: pairs.length, agree_axisA: agree((r, a) => r.self.axisA === a.axisA),
      agree_kind: agree((r, a) => r.self.kind === C.kindOf(a.category, a.axisA, table)) },
  };
}

// `boundaryBaseline(v, byVersion, v0)` — the boundary baseline of vN is vN-1: v1 against the v0 cache (subset only), v2 and
// later against vN-1's subset block and full-population block.
function boundaryBaseline(v, byVersion, v0) {
  const n = Number(v.slice(1));
  if (n <= 1) return { version: "v0", population_kind: "sample", ...v0 };
  const version = `v${n - 1}`;
  const prev = byVersion[version];
  if (!prev) return { version, status: "no-data" };
  return { version, status: "available", population_kind: "sample", ...prev.self, classified: prev.classified,
    all: prev.all.self };
}

function postBoundary(opts) {
  const at = C.boundaryAt();
  const excluded = {};
  const dirs = postDirs(at, excluded);
  const journal = C.readJournal(dirs);
  const idx = journalIndex(journal);
  const journalExcluded = {};
  const units = journalUnits(idx, journalExcluded);
  const rows = subsetRows({ ...opts, dirs }, at, excluded, idx);
  const versions = [...new Set([...units.keys(), ...rows.map((r) => r.version)])]
    .sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));
  const sampled = new Map(versions.map((v) => [v, sampleOf(rows.filter((r) => r.version === v), opts.seed)]));
  const flat = versions.flatMap((v) => sampled.get(v).rows);
  const clsAll = answers(flat, opts.plansDir);
  const table = C.handling();
  const cache = K.readV0(opts.plansDir);
  const status = K.comparison(cache, classifierId);
  const v0 = status === "comparable" ? { status, ...v0Stats(cache, table) } : { status };
  const byVersion = {};
  let at0 = 0;
  for (const v of versions) {
    const s = sampled.get(v);
    const cls = clsAll.slice(at0, at0 + s.rows.length);
    at0 += s.rows.length;
    const all = fullBlock(units.get(v) || []);
    byVersion[v] = { journal_rows: all.journal_rows, all, ...subsetBlock(rows.filter((r) => r.version === v), s, cls, table) };
    byVersion[v].boundary_baseline = boundaryBaseline(v, byVersion, v0);
  }
  return {
    mode: "post-boundary", model: MODEL, classifierId, seed: opts.seed,
    boundary_at: at === null ? null : new Date(at).toISOString(),
    boundary_versions_seen: [...new Set(journal.map((r) => r.version))].sort(),
    journal_rows: journal.length,
    excluded,
    journal_excluded: journalExcluded,
    v0_comparison: v0,
    by_version: byVersion,
    rows: flat.map((r, k) => ({ source: r.source, discrim: r.discrim, version: r.version, self_axisA: r.self.axisA,
      self_axisB: r.self.axisB, self_kind: r.self.kind, axisA: clsAll[k].axisA, axisB: clsAll[k].axisB,
      category: clsAll[k].category, valid: clsAll[k].valid })),
  };
}

module.exports = { postBoundary };
