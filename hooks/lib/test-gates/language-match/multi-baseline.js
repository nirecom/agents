"use strict";
// The merge 3-way of the language-match judgment (#2812, a path whose two merge parents differ;
// ports tlm_judge_multi of the former bash multi-baseline library). judge runs once per
// baseline (h1, h2 and the merge-base, null when it lacks the path); the occurrences each run
// judged not existing are combined per key. judgeMulti(...) -> { rc, lines } as judge.
// Rules and the accepted edges: docs/architecture/claude-code/case-marker-gate.md.

const R = require("../registry");
const { judge } = require("./judge");
const { caseAddition3way } = require("./case-addition");

const count = (key, list) => list.filter((k) => k.key === key).length;
const excess = (p, s) => Math.max(0, p - s);

// A key (hdr:<target> or case:<target>) is reported when a + b - c > 0, where a / b / c are its
// not-existing occurrences against h1 / h2 / base, each given back max(0, P - S) where a baseline
// holds more occurrences (P) than the staged file (S); one line per target, h1's line first, then
// h2's, then the staged file's.
function judgeMulti(file, match, base, h1, h2, opts = {}) {
  const runs = [];
  const run = (f, h) => {
    const j = judge(f, match, h || null, opts);
    if (j.rc > 1) throw j;
    return j;
  };
  try {
    const r1 = run(file, h1);
    const r2 = run(file, h2);
    const rb = run(file, base);
    const all = (f) => (f ? run(f, null).keys : []);
    runs.push(r1, r2, rb, run(file, null), all(h1), all(h2), all(base));
  } catch (j) {
    if (j && typeof j.rc === "number") return { rc: j.rc, lines: [] };
    throw j;
  }
  const [r1, r2, rb, rs, p1, p2, pb] = runs;
  const [k1, k2, kb, ks] = [r1.keys, r2.keys, rb.keys, rs.keys];
  const lines = [];
  const seen = new Set();
  for (const { key } of [...k1, ...k2, ...ks]) {
    const target = key.slice(key.indexOf(":") + 1);
    if (seen.has(target)) continue;
    const s = count(key, ks);
    const a = count(key, k1) - excess(count(key, p1), s);
    const b = count(key, k2) - excess(count(key, p2), s);
    const c = count(key, kb) - excess(count(key, pb), s);
    if (a + b - c <= 0) continue;
    seen.add(target);
    lines.push([k1, k2, ks].map((l) => l.find((k) => k.key === key)).find(Boolean).text);
  }
  if ((r1.reached || r2.reached) && R.match(match)) {
    const l = caseAddition3way(file, match, h1, h2, base || null);
    if (l) lines.push(l);
  }
  return { rc: lines.length ? 1 : 0, lines };
}

module.exports = { judgeMulti };
