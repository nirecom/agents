"use strict";
// The registry's parts as the gates call them (#2507 D7), resolved through each entry's `node`
// item. Two part shapes are not the gates' own and are adapted here by name: a line scanner
// (`scanLines`, the js reader: it takes the lines, not the file) and an analyzer (`analyze` /
// `analyzer`: answered through case-embed-dispatch.js, as the bash cec_dispatch wraps them).
//   readCases(entry, file) -> { rc, g }   rc 70 part unreachable, 79 no runtime, 1 reader failed
//   embed(entry, op, file, { cases }) -> { rc, stdout, stderr }   rc 70 part unreachable

const fs = require("fs");
const path = require("path");
const R = require("../registry");
const { bridge } = require("./reader-records");
const { dispatch } = require("./case-embed-dispatch");
const X = require("./external-runtime");
const S = require("../source");

// local(file) — what an in-process part reads: an in-memory file as is, a path in native form.
const local = (f) => (S.isMem(f) ? f : X.native(f));

const LINE_SCANNERS = new Set(["scanLines"]);
const ANALYZERS = new Set(["analyze", "analyzer"]);

// part(entry, field) — { mod, fn, name } of the part, or null when it cannot be reached.
function part(entry, field) {
  const p = R.partOf(entry, field);
  if (!p) return null;
  const abs = path.join(R.REPO_ROOT, ...p.file.split("/"));
  if (!fs.existsSync(abs)) return null;
  try {
    const mod = require(abs);
    return typeof mod[p.function] === "function" ? { mod, fn: mod[p.function], name: p.function } : null;
  } catch {
    return null;
  }
}

// The in-process line scanner read as its reader child prints (js-case-reader.js), then bridged.
function scanAsChild(p, file) {
  let v;
  try {
    v = p.fn(p.mod.readLines(local(file)));
  } catch {
    return { rc: 1 };
  }
  const rows = [["FILE", v.state, v.line, v.reason].join("\t")];
  for (const c of v.cases) rows.push(["CASE", c.name, c.target, c.begin, c.end, "", ""].join("\t"));
  return bridge(`${rows.join("\n")}\n`);
}

function readCases(entry, file) {
  const p = part(entry, "caseMarkerReader");
  if (!p) return { rc: 70 };
  try {
    if (LINE_SCANNERS.has(p.name)) return scanAsChild(p, file);
    const r = p.fn(file, { id: entry.id });
    return r && typeof r.rc === "number" ? r : { rc: 1 };
  } catch {
    return { rc: 1 };
  }
}

function helperOf(entry) {
  const rel = R.fieldValue(entry, "helperLibrary.path");
  return rel ? X.native(path.join(R.REPO_ROOT, ...rel.split("/"))) : "";
}

function embed(entry, op, file, opts = {}) {
  const p = part(entry, "caseEmbedRules");
  if (!p) return { rc: 70, stdout: "", stderr: `${entry.id}.caseEmbedRules: part not reachable\n` };
  if (!ANALYZERS.has(p.name)) return p.fn(op, file, undefined, { cases: opts.cases || [] });
  const external = p.name === "analyzer";
  const ctx = {
    id: entry.id,
    cases: opts.cases || [],
    helper: helperOf(entry),
    runtimeMissing: () => external && !R.which((X.LAUNCH[entry.id] || {}).command || entry.id),
    readCases: (f) => readCases(entry, f),
    call: (o, f, h) => (external ? p.fn(o, f, h, { id: entry.id }) : p.fn(o, local(f), h)),
  };
  return dispatch(ctx, op, file);
}

module.exports = { part, readCases, embed };
