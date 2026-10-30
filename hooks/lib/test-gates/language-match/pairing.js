"use strict";
// A test's cases and their pairing with the HEAD version (#2507 D7; ports _tlm_cases / _tlm_pair
// of bin/lib/test-language-match.sh).
//   cases(file, name) -> { state, cases: [{ name, target, line }] }   cases only when conforming
//   pair(head, work, name) -> [{ name, target, line, kind: added|paired, headTarget }] | null

const { records } = require("../case-records");

function cases(file, name) {
  const rec = records(file, name);
  if (rec.state !== "conforming") return { state: rec.state, cases: [] };
  return { state: rec.state, cases: rec.cases.map((c) => ({ name: c.name, target: c.target, line: String(c.begin) })) };
}

// Same name: paired. A name HEAD lacks pairs, in file order and 1:1, with a vanished HEAD case
// (its name gone from the work version) of the same target; anything left is added.
function pair(head, work, name) {
  const h = cases(head, name);
  if (h.state !== "conforming") return null;
  const w = cases(work, name);
  if (w.state !== "conforming") return null;
  const used = h.cases.map((hc) => w.cases.some((wc) => wc.name === hc.name));
  return w.cases.map((wc) => {
    let found = h.cases.findIndex((hc) => hc.name === wc.name);
    if (found === -1) {
      found = h.cases.findIndex((hc, j) => !used[j] && hc.target === wc.target);
      if (found !== -1) used[found] = true;
    }
    return found === -1 ? { ...wc, kind: "added", headTarget: "" } : { ...wc, kind: "paired", headTarget: h.cases[found].target };
  });
}

module.exports = { cases, pair };
