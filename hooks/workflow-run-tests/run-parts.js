"use strict";
// hooks/workflow-run-tests/run-parts.js — partial reruns merged into one run_tests verdict (#2688 T7).
// run_tests.run_parts lists the runs since the last full run. A selection the run's own evidence
// cannot prove is "unknown": kept in the merge window with its failures, holding it open until a
// full run rebuilds it (#3063). Parts whose input_version differs from the latest are dropped;
// a null latest merges nothing.

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

// The option prefix of tests/run-all.sh, which owns it (its `case "$1"` loop; a drift test
// binds the two). Labels in the parser's order; a trailing `*` is a prefix. "skip" / "value"
// only set parallelism; "all" runs the full suite whatever follows; "end" is `--`; "unknown"
// cannot prove a full run (a deadline can cut it, a plan runs nothing, an unknown option exits 2).
const RUN_ALL_OPTIONS = Object.freeze({
  "--all": "all",
  "--print-plan": "unknown",
  "-j": "value",
  "--jobs": "value",
  "--jobs=*": "skip",
  "--deadline": "unknown",
  "--deadline=*": "unknown",
  "--": "end",
  "-*": "unknown",
});

// The RUN_ALL_OPTIONS kind of one argument; null for a non-option (the parser stops there).
function optionKind(arg) {
  for (const [label, kind] of Object.entries(RUN_ALL_OPTIONS)) {
    if (label.endsWith("*") ? arg.startsWith(label.slice(0, -1)) : arg === label) return kind;
  }
  return null;
}

// The arguments after the option prefix, "full" when --all was given, or "unknown".
function afterOptions(args) {
  let all = false;
  let i = 0;
  while (i < args.length) {
    const kind = typeof args[i] === "string" ? optionKind(args[i]) : "unknown";
    if (kind === null) break;
    if (kind === "unknown") return "unknown";
    if (kind === "end") return all ? "full" : args.slice(i + 1);
    if (kind === "value" && i + 1 >= args.length) return "unknown";
    if (kind === "all") all = true;
    i += kind === "value" ? 2 : 1;
  }
  return all ? "full" : args.slice(i);
}

// "full" for no test path, the sorted test paths when every remaining argument is one, else
// "unknown". Options are read as run-all reads them (RUN_ALL_OPTIONS).
function selectionFromArgs(args, root) {
  if (!Array.isArray(args)) return "unknown";
  const rest = afterOptions(args);
  if (!Array.isArray(rest)) return rest;
  if (rest.length === 0) return "full";
  const out = [];
  for (const a of rest) {
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

const isRebuild = (e) => e.selection === "full" && e.late !== true;

// The merged verdict of the parts that share the latest input_version, from the last full one
// on; null when the latest run must be recorded alone. An unknown part in the window holds it
// open and its failures are kept whatever follows; so does a truncated part; a late part only adds (#3063).
function mergeParts(parts) {
  const latest = parts[parts.length - 1];
  if (!latest || latest.input_version === null) return null;
  const same = parts.filter((e) => e.input_version === latest.input_version);
  const full = same.map(isRebuild).lastIndexOf(true);
  const use = same.slice(Math.max(full, 0));
  const open = use.some((e) => e.selection === "unknown" || e.truncated === true);
  // A lone run has nothing to merge: its own values stand, an unknown one only holds it open.
  if (use.length < 2) return open ? { open: true } : null;
  const m = { failing: [], exits: {}, hits: [], unlisted: 0, unrunnable: 0 };
  const kept = { failing: [], exits: {} };
  for (const e of use) {
    if (isRebuild(e)) {
      Object.assign(m, { failing: [], exits: {}, hits: [], unlisted: 0 });
    } else if (Array.isArray(e.selection) && e.late !== true) {
      m.failing = m.failing.filter((p) => !e.selection.includes(p));
      for (const p of e.selection) delete m.exits[p];
      if (e.hits === 0) m.hits = m.hits.filter((h) => !e.selection.includes(hitTestId(h)));
    }
    for (const p of e.failing) if (!m.failing.includes(p)) m.failing.push(p);
    Object.assign(m.exits, e.exits);
    if (e.selection === "unknown") {
      kept.failing.push(...e.failing);
      Object.assign(kept.exits, e.exits);
    }
    addHits(m, e);
    m.unrunnable += e.unrunnable;
  }
  return {
    failingTests: [...new Set(m.failing.concat(kept.failing))].sort(),
    failingExits: Object.assign(m.exits, kept.exits),
    hitCount: m.hits.length + m.unlisted,
    hitSummary: m.hits,
    unrunnableCount: m.unrunnable,
    open,
  };
}

// recordParts({ sessionId, part, run }) -> { runParts, merged, selection }.
// part: { args, root, cwd, results, late }; run: { trusted, contract, failing, exits, hitCount,
// hitSummary, unrunnable } of this run alone. A late part never rebuilds run_parts.
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
    ...(part.late === true ? { late: true } : {}),
  };
  if (isRebuild(element)) return { runParts: [element], merged: mergeParts([element]), selection };
  const all = prev.concat([element]);
  const dropped = all.slice(0, Math.max(0, all.length - MAX_PARTS));
  // A same-version part pushed out of the window takes its failures with it: mark the pusher so
  // the window stays open until a full run (#3063). Re-marked each time a marked part is dropped.
  if (element.input_version !== null && dropped.some((e) => e.input_version === element.input_version)) {
    element.truncated = true;
  }
  const runParts = all.slice(-MAX_PARTS);
  return { runParts, merged: mergeParts(runParts), selection };
}

module.exports = {
  RUN_ALL_OPTIONS, runAllArgs, selectionFromArgs, resultPaths, proveSelection, mergeParts, recordParts,
};
