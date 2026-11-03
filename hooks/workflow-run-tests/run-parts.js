"use strict";
// hooks/workflow-run-tests/run-parts.js — partial reruns merged into one run_tests verdict (#2688 T7).
// run_tests.run_parts lists the runs since the last full run. A selection the run's own evidence
// cannot prove is "unknown": kept in the list, never merged, and that run is recorded alone.
// Parts whose input_version differs from the latest are dropped; a null latest merges nothing.

const { parse, resolveEffectiveSegment } = require("../lib/command-ir");
const { computeInputVersion } = require("../lib/diff-fingerprint");
const { normalizeCwd } = require("../lib/path-normalize");
const { readState } = require("../workflow-state");
const { normalizeTestPath } = require("./failing-list");
const { hitTestId } = require("./hit-summary");

const MAX_PARTS = 50;
const RUN_ALL_SUFFIX = "tests/run-all.sh";
const SHELL_EXPANSION_RE = /[$`*?[\]{}~]/;
const RESULT_LINE_RES = [
  /^PASS: (.+)$/, /^SKIP: (.+)$/, /^FAIL: (.+) \(exit -?\d+\)$/, /^UNRUNNABLE: (.+) \(missing: [^)]*\)$/,
];

// The tokens after tests/run-all.sh in the one segment that runs it; null when there is not
// exactly one such position or a token is left to shell expansion.
function runAllArgs(command) {
  const ir = parse(typeof command === "string" ? command.trim() : "");
  if (ir.parseFailure) return null;
  let found = null;
  for (const seg of ir.segments) {
    const eff = resolveEffectiveSegment(seg);
    if (eff === null || !Array.isArray(eff.argv)) continue;
    const tokens = [eff.cmd0].concat(eff.argv);
    const raws = [eff.cmd0Raw].concat(eff.argvRaw || eff.argv);
    tokens.forEach((t, i) => {
      const norm = String(t).replace(/\\/g, "/");
      if (norm !== RUN_ALL_SUFFIX && !norm.endsWith(`/${RUN_ALL_SUFFIX}`)) return;
      found = found === null ? { args: tokens.slice(i + 1), raws: raws.slice(i + 1) } : false;
    });
  }
  if (!found) return null;
  return found.raws.some((r) => SHELL_EXPANSION_RE.test(String(r))) ? null : found.args;
}

// "full" for no arguments, the sorted test paths when every argument is one, else "unknown".
function selectionFromArgs(args, root) {
  if (!Array.isArray(args)) return "unknown";
  if (args.length === 0) return "full";
  const out = [];
  for (const a of args) {
    const rel = typeof a === "string" ? normalizeTestPath(a, root) : null;
    if (rel === null) return "unknown";
    if (!out.includes(rel)) out.push(rel);
  }
  return out.sort();
}

// The paths run-all printed a PASS/SKIP/FAIL/UNRUNNABLE line for.
function resultPaths(stdout, root) {
  const out = [];
  for (const line of String(stdout || "").replace(/\r\n/g, "\n").split("\n")) {
    for (const re of RESULT_LINE_RES) {
      const m = re.exec(line);
      const rel = m === null ? null : normalizeTestPath(m[1], root);
      if (rel !== null && !out.includes(rel)) out.push(rel);
    }
  }
  return out;
}

// The selection the run proves, given its trusted counts. results: null off the stdout route.
function proveSelection(selection, run, results) {
  if (selection === "unknown" || !run.trusted || !Array.isArray(run.failing)) return "unknown";
  if (selection === "full") return "full";
  const c = run.contract;
  if (c.executed + c.unrunnable !== selection.length) return "unknown";
  if (run.failing.some((p) => !selection.includes(p))) return "unknown";
  if (Array.isArray(results) && selection.some((p) => !results.includes(p))) return "unknown";
  return selection;
}

function previousParts(sessionId) {
  const state = readState(sessionId);
  const rt = state && state.steps ? state.steps.run_tests : null;
  return rt && Array.isArray(rt.run_parts) ? rt.run_parts.filter((e) => e && typeof e === "object") : [];
}

function inputVersionOf(cwd) {
  if (typeof cwd !== "string" || cwd === "") return null;
  return computeInputVersion(normalizeCwd(cwd) || cwd);
}

function addHits(m, e) {
  for (const h of e.hit_summary) if (!m.hits.includes(h)) m.hits.push(h);
  m.unlisted += Math.max(0, e.hits - e.hit_summary.length);
}

// The merged verdict of the parts that share the latest input_version, from the last full one
// on; null when the latest run must be recorded alone.
function mergeParts(parts) {
  const latest = parts[parts.length - 1];
  if (!latest || latest.selection === "unknown" || latest.input_version === null) return null;
  const same = parts.filter((e) => e.selection !== "unknown" && e.input_version === latest.input_version);
  const full = same.map((e) => e.selection).lastIndexOf("full");
  const use = same.slice(Math.max(full, 0));
  if (use.length < 2) return null;
  const m = { failing: [], exits: {}, hits: [], unlisted: 0, unrunnable: 0 };
  for (const e of use) {
    if (e.selection === "full") {
      Object.assign(m, { failing: [], exits: {}, hits: [], unlisted: 0 });
    } else {
      m.failing = m.failing.filter((p) => !e.selection.includes(p));
      for (const p of e.selection) delete m.exits[p];
      if (e.hits === 0) m.hits = m.hits.filter((h) => !e.selection.includes(hitTestId(h)));
    }
    for (const p of e.failing) if (!m.failing.includes(p)) m.failing.push(p);
    Object.assign(m.exits, e.exits);
    addHits(m, e);
    m.unrunnable += e.unrunnable;
  }
  return {
    failingTests: m.failing.sort(),
    failingExits: m.exits,
    hitCount: m.hits.length + m.unlisted,
    hitSummary: m.hits,
    unrunnableCount: m.unrunnable,
  };
}

// recordParts({ sessionId, part, run }) -> { runParts, merged }.
// part: { args, root, cwd, results }; run: { trusted, contract, failing, exits, hitCount,
// hitSummary, unrunnable } of this run alone.
function recordParts({ sessionId, part, run }) {
  const prev = previousParts(sessionId);
  const selection = proveSelection(selectionFromArgs(part.args, part.root), run, part.results);
  const hitSummary = Array.isArray(run.hitSummary) ? run.hitSummary : [];
  const element = {
    seq: prev.reduce((n, e) => Math.max(n, Number.isInteger(e.seq) ? e.seq : 0), 0) + 1,
    selection,
    failing: Array.isArray(run.failing) ? run.failing : [],
    exits: run.exits && typeof run.exits === "object" ? run.exits : {},
    hits: Number.isInteger(run.hitCount) ? run.hitCount : 0,
    hit_ids: hitSummary.map(hitTestId).filter((id) => id !== null),
    hit_summary: hitSummary,
    unrunnable: Number.isInteger(run.unrunnable) ? run.unrunnable : 0,
    input_version: inputVersionOf(part.cwd),
  };
  const runParts = selection === "full" ? [element] : prev.concat([element]).slice(-MAX_PARTS);
  return { runParts, merged: mergeParts(runParts) };
}

module.exports = { runAllArgs, selectionFromArgs, resultPaths, proveSelection, mergeParts, recordParts };
