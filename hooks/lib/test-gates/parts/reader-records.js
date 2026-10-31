"use strict";
// What a case reader leaves, and the shared rules read over it (#2507 D7; ports
// bin/lib/case-target-path-rule.sh, bin/lib/case-reader-bridge.sh crb_run's record check and
// bin/lib/test-retire-predicate/case-state-rules.sh with trp_marker_state_from_globals).
// A reader result is { rc, g }; g = { hasMarkers, malformed, line, reason, uncertain, cases }.

const emptyGlobals = () => ({ hasMarkers: false, malformed: false, line: "", reason: "", uncertain: false, cases: [] });

// targetValid(v) — ctp_target_path_valid: a usable repo-relative case target.
function targetValid(v) {
  if (!/^[A-Za-z0-9._/-]+$/.test(v)) return false;
  if (v.startsWith("/") || v.startsWith("./") || v === ".") return false;
  return !(v === ".." || v.startsWith("../") || v.endsWith("/..") || v.includes("/../"));
}

// bridge(out) — crb_run's reading of a reader child's stdout: { rc: 0, g } or { rc: 1 }.
function bridge(out) {
  const g = emptyGlobals();
  let files = 0;
  let state = "";
  const cases = [];
  for (const raw of String(out).replace(/\n+$/, "").split("\n")) {
    const col = raw.replace(/\r$/, "").split("\t");
    if (col[0] === "FILE") {
      if (col.length !== 4) return { rc: 1 };
      files += 1;
      [, state, g.line, g.reason] = col;
    } else if (col[0] === "CASE") {
      if (col.length !== 7 || !col[1] || !col[2]) return { rc: 1 };
      if (!/^[0-9]+$/.test(col[3]) || !/^[0-9]+$/.test(col[4]) || !targetValid(col[2])) return { rc: 1 };
      cases.push({ name: col[1], target: col[2], begin: col[3], end: col[4] });
    } else return { rc: 1 };
  }
  if (files !== 1) return { rc: 1 };
  if (state === "none") {
    if (cases.length) return { rc: 1 };
    return { rc: 0, g: emptyGlobals() };
  }
  if (state === "conforming") {
    if (!cases.length) return { rc: 1 };
    return { rc: 0, g: { ...emptyGlobals(), hasMarkers: true, cases } };
  }
  if (state === "malformed" || state === "uncertain") {
    if (cases.length) return { rc: 1 };
    return { rc: 0, g: { hasMarkers: true, malformed: true, line: g.line, reason: g.reason, uncertain: state === "uncertain", cases: [] } };
  }
  return { rc: 1 };
}

function reject(g, line, reason) {
  return { ...g, malformed: true, line: line === undefined ? "" : String(line), reason, cases: [] };
}

// markerState(g) -> { state, line, reason, cases }: the delimiter and duplicate-name rules, then
// the verdict trp_marker_state_from_globals gives.
function markerState(g0) {
  let g = g0;
  if (!g.malformed && g.hasMarkers) {
    const bad = g.cases.find((c) => /[\t\r\n]/.test(`${c.name}${c.target}`));
    if (bad) g = reject(g, bad.begin, "grammar");
  }
  if (!g.malformed && g.hasMarkers) {
    const seen = new Set();
    for (const c of g.cases) {
      if (seen.has(c.name)) {
        g = reject(g, c.begin, "duplicate-name");
        break;
      }
      seen.add(c.name);
    }
  }
  let state = "none";
  if (g.malformed) state = g.uncertain ? "uncertain" : "malformed";
  else if (g.hasMarkers) state = "conforming";
  return { state, line: String(g.line), reason: g.reason, cases: g.cases };
}

module.exports = { emptyGlobals, targetValid, bridge, markerState };
