"use strict";
// bin/lib/review-threat-metrics/common.js — shared reading for bin/review-threat-metrics (#2020):
// the state root's control dirs and session times, concern journals, carrier REJECTED lines, the
// boundary introduction time, the `## Threat boundary` table of the criteria SSOT, the delivered criteria
// block's hash, ratios and the sample rule.
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { getStateRoot } = require("../../../hooks/workflow-state/state-io/state-root");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const CRITERIA_REL = "skills/_shared/review-criteria.md";

const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");

// bodyOf(text) — the finding text without its leading axis/cat tags or its marker prefix.
function bodyOf(text) {
  const t = String(text || "").trim();
  if (t.startsWith("[NOT-CONCERN]")) return t.split("|").slice(2).join("|").trim();
  return t.replace(/^(?:(?:axis:[^\s/]*\/\S*|cat:\S+|nfr:in)(?:\s+|$))*/, "").trim();
}

// readFailures — "<path>: <code>" for each source file that existed but could not be read during
// this run; the CLI reports them and exits 5, so a lost source is never counted as empty data.
const readFailures = [];
const readLines = (f) => {
  try {
    return fs.readFileSync(f, "utf8").split(/\r?\n/);
  } catch (e) {
    if (e && e.code !== "ENOENT") readFailures.push(`${f}: ${e.code || e.message}`);
    return [];
  }
};

const isDir = (d) => {
  try {
    return fs.statSync(d).isDirectory();
  } catch {
    return false;
  }
};

// controlDirs() — [{sid, dir}] of every <sid>.control directory under the state root.
function controlDirs() {
  const root = getStateRoot();
  let names;
  try {
    names = fs.readdirSync(root);
  } catch {
    return [];
  }
  return names.filter((n) => n.endsWith(".control"))
    .map((n) => ({ sid: n.slice(0, -".control".length), dir: path.join(root, n) }))
    .filter((c) => isDir(c.dir));
}

// sessionTime(sid) — the created_at (ms) of <state>/<sid>.json; null when there is no state file.
function sessionTime(sid) {
  try {
    const t = Date.parse(JSON.parse(fs.readFileSync(path.join(getStateRoot(), `${sid}.json`), "utf8")).created_at);
    return Number.isNaN(t) ? null : t;
  } catch {
    return null;
  }
}

// boundaryAt() — the boundary introduction time (ms): the env override, else the first commit that
// added the `## Threat boundary` section; null when neither exists (every session is then v0).
function boundaryAt() {
  const env = process.env.REVIEW_THREAT_METRICS_BOUNDARY_AT;
  if (env) {
    const t = Date.parse(env);
    if (!Number.isNaN(t)) return t;
  }
  const r = spawnSync("git", ["-C", ROOT, "log", "--reverse", "--format=%cI", "-S## Threat boundary", "--", CRITERIA_REL],
    { encoding: "utf8" });
  const first = r.status === 0 ? (r.stdout || "").split(/\r?\n/).find(Boolean) : "";
  const t = first ? Date.parse(first) : NaN;
  return Number.isNaN(t) ? null : t;
}

// filesOf(dir, re) — [{file, fmt}] for the names in dir matching re (group 1 = format).
function filesOf(dir, re) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (e) {
    if (e && e.code !== "ENOENT") readFailures.push(`${dir}: ${e.code || e.message}`);
    return [];
  }
  return names.map((n) => [n, n.match(re)]).filter(([, m]) => m).map(([n, m]) => ({ file: path.join(dir, n), fmt: m[1] }));
}

// readJournal(dirs) — every j1 row of every <fmt>-concern-journal.tsv; a 15-column row has no version.
function readJournal(dirs = controlDirs()) {
  const rows = [];
  for (const c of dirs) {
    for (const { file, fmt } of filesOf(c.dir, /^(.+)-concern-journal\.tsv$/)) {
      for (const l of readLines(file)) {
        const f = l.split("\t");
        if (f[0] !== "j1" || f.length < 15) continue;
        rows.push({ sid: f[2], fmt, round: f[4], reviewer: f[6], kind: f[7], category: f[8], axisA: f[9],
          axisB: f[10], discrim: f[11], text: f[14], version: f[15] ?? "unknown" });
      }
    }
  }
  return rows;
}

// hasPostBoundaryRows(dir) — the control dir's journal has a row of boundary version v1 or later.
const hasPostBoundaryRows = (d) => readJournal([d]).some((r) => /^v[1-9]\d*$/.test(r.version));

const REJECTED_RE = /^- (\S+) \[(?:HIGH|MEDIUM|LOW)\] REJECTED (.*)$/;
// readCarrier(dirs) — every REJECTED line of every <fmt>-concern-carrier.md.
function readCarrier(dirs = controlDirs()) {
  const rows = [];
  for (const c of dirs) {
    for (const { file, fmt } of filesOf(c.dir, /^(.+)-concern-carrier\.md$/)) {
      for (const l of readLines(file)) {
        const m = l.match(REJECTED_RE);
        if (m) rows.push({ sid: c.sid, fmt, id: m[1], text: bodyOf(m[2].replace(/\s+— reason:.*$/, "")) });
      }
    }
  }
  return rows;
}

// handling() — {A0: "no-path", A1: "in", ...} from the `## Threat boundary` table.
function handling() {
  const h = {};
  for (const l of readLines(path.join(ROOT, CRITERIA_REL))) {
    const m = l.match(/^\|\s*(A[0-6])\s*\|.*\|\s*(in|out|no-path)\s*\|\s*$/);
    if (m) h[m[1]] = m[2];
  }
  return h;
}

// kindOf(category, axisA, table) — the bj_kind rule: only security is bounded.
function kindOf(category, axisA, table) {
  if (category !== "security") return "concern";
  const h = table[axisA];
  return h === "out" ? "out-of-boundary" : h === "no-path" ? "no-path" : "concern";
}

const ratio = (a, b) => (b > 0 ? a / b : 0);
// stats(rows) — axis A and axis B class counts and the out-of-boundary / no-path ratios over all and
// security rows.
function stats(rows) {
  const classes = {};
  const classesB = {};
  for (const r of rows) {
    if (/^A[0-6]$/.test(r.axisA)) classes[r.axisA] = (classes[r.axisA] || 0) + 1;
    if (/^B[0-3]$/.test(r.axisB)) classesB[r.axisB] = (classesB[r.axisB] || 0) + 1;
  }
  const sec = rows.filter((r) => r.category === "security");
  const n = (kind, set) => set.filter((r) => r.kind === kind).length;
  return {
    n: rows.length, security: sec.length, classes, classes_b: classesB,
    out_ratio: { all: ratio(n("out-of-boundary", rows), rows.length), security: ratio(n("out-of-boundary", sec), sec.length) },
    nopath_ratio: { all: ratio(n("no-path", rows), rows.length), security: ratio(n("no-path", sec), sec.length) },
  };
}

// weighted(parts) — population-weighted ratios over [{pop, st}]; a security ratio is weighted by the
// part's estimated security population (pop × its sample's security share), not by all of pop.
function weighted(parts) {
  const weight = (p, scope) => (scope === "security" ? p.pop * ratio(p.st.security, p.st.n) : p.pop);
  const w = (k, scope) => ratio(parts.reduce((s, p) => s + weight(p, scope) * p.st[k][scope], 0),
    parts.reduce((s, p) => s + weight(p, scope), 0));
  return { out_ratio: { all: w("out_ratio", "all"), security: w("out_ratio", "security") },
    nopath_ratio: { all: w("nopath_ratio", "all"), security: w("nopath_ratio", "security") } };
}

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// sample(arr, n, seed) — n items drawn by a seeded shuffle; the whole array when it fits.
function sample(arr, n, seed) {
  if (arr.length <= n) return arr.slice();
  const a = arr.slice();
  const r = rng(seed);
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(r() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.slice(0, n);
}

const SAMPLE_CAP = { carrier: 60, issue: 40, total: 100 };
// sampleSizes(nc, ni) — 60 carrier rows + 40 issues, a short side topped up from the other, 100 at most.
function sampleSizes(nc, ni) {
  let c = Math.min(nc, SAMPLE_CAP.carrier);
  let i = Math.min(ni, SAMPLE_CAP.issue);
  c += Math.min(SAMPLE_CAP.total - c - i, nc - c);
  i += Math.min(SAMPLE_CAP.total - c - i, ni - i);
  return { c, i };
}

// drawSample(carrier, issues, seed) — {carrier, issues}: the sample rule shared by pre boundary and the
// post boundary subset; issues are drawn as whole issues.
function drawSample(carrier, issues, seed) {
  const n = sampleSizes(carrier.length, issues.length);
  return { carrier: sample(carrier, n.c, seed), issues: sample(issues, n.i, seed + 1) };
}

// criteriaHash() — line 1 of the side record bin/review-criteria-block writes for the delivered criteria
// block (the hash SSOT is codex_core_sha12); "unknown" when the block cannot be produced.
function criteriaHash() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "review-threat-metrics-"));
  const out = path.join(dir, "criteria-hash.txt");
  const fwd = (p) => p.replace(/\\/g, "/");
  try {
    spawnSync("bash", [fwd(path.join(ROOT, "bin", "review-criteria-block"))],
      { env: { ...process.env, REVIEW_CRITERIA_HASH_OUT: fwd(out) }, stdio: "ignore" });
    const h = readLines(out)[0] || "";
    return /^[0-9a-f]{12}$/.test(h) ? h : "unknown";
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { ROOT, sha, bodyOf, readFailures, controlDirs, sessionTime, boundaryAt, readJournal, hasPostBoundaryRows, readCarrier, handling,
  kindOf, stats, weighted, sample, drawSample, criteriaHash };
