"use strict";
// A test file's case records as TSV (#2507 D7; ports crr_read of bin/lib/case-record-reader.sh).
//   FILE\t<state>\t<malformed_line>\t<malformed_reason>
//   CASE\t<name>\t<target>\t<begin>\t<end>\t<deps>\t   (conforming only, one per case)
// read(file, matchPath) -> that text; records(file, matchPath) -> { state, line, reason, cases }
// with each case's deps (`?` when the entry has no caseEmbedRules).

const R = require("./registry");
const P = require("./parts");
const { markerState } = require("./parts/reader-records");

const fileRec = (state, line = "", reason = "") => ({ state, line, reason, cases: [] });

// deps rows `<idx>\t<csv>` for n cases, as _crr_deps_rows checks them; null when they break it.
function depsRows(n, out) {
  const s = String(out).replace(/\n+$/, "");
  if (!s || s.includes("\r")) return null;
  const deps = new Map();
  for (const row of s.split("\n")) {
    const parts = row.split("\t");
    if (parts.length !== 2) return null;
    const [idx, csv] = parts;
    if (!/^[0-9]+$/.test(idx)) return null;
    const i = Number.parseInt(idx, 10);
    if (i >= n || deps.has(i) || !/^([^,]+(,[^,]+)*)?$/.test(csv)) return null;
    deps.set(i, csv);
  }
  return deps.size === n ? deps : null;
}

function records(file, matchPath) {
  let m;
  try {
    R.reg();
    m = R.match(matchPath === undefined ? file : matchPath);
  } catch {
    return fileRec("malformed", "", "reader");
  }
  if (!m || m.status !== "supported" || !R.partOf(m.entry, "caseMarkerReader")) return fileRec("unsupported");
  const requires = () => R.fieldValue(m.entry, "launch.requires") || "";
  const rd = P.readCases(m.entry, file);
  if (rd.rc === 79) return fileRec("unavailable", "", requires());
  if (rd.rc !== 0) return fileRec("malformed", "", "reader");
  const v = markerState(rd.g);
  if (v.state !== "conforming") return fileRec(v.state, v.line, v.reason);
  const cases = v.cases.map((c) => ({ ...c, deps: "?" }));
  if (R.partOf(m.entry, "caseEmbedRules")) {
    const r = P.embed(m.entry, "deps", file, { cases: rd.g.cases });
    if (r.rc === 69) return fileRec("unavailable", "", requires());
    const deps = r.rc === 0 ? depsRows(cases.length, r.stdout) : null;
    if (!deps) return fileRec("uncertain", "", "case-embed");
    cases.forEach((c, i) => { c.deps = deps.get(i); });
  }
  return { state: "conforming", line: "", reason: "", cases };
}

function format(rec) {
  const rows = [`FILE\t${rec.state}\t${rec.line}\t${rec.reason}\n`];
  for (const c of rec.cases) rows.push(`CASE\t${c.name}\t${c.target}\t${c.begin}\t${c.end}\t${c.deps}\t\n`);
  return rows.join("");
}

const read = (file, matchPath) => format(records(file, matchPath));

module.exports = { read, records, format, depsRows };
