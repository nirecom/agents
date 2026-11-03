"use strict";
// Tests: hooks/workflow-run-tests/run-parts.js
// Tags: TL2, hooks, run-tests, run-parts, dispatch-outcome, scope:issue-specific
// Shared driver for the run-parts cases: a fixture repo holding three committed tests
// (the outcome cwd, so failing names pass the exists-under-cwd check), and a dispatch step
// that places one trusted outcome and lets the real hook ingest it on the next Bash call.

const F = require("../../lib/run-tests-outcome-fixture");

const A = "tests/hooks/a.js";
const B = "tests/hooks/b.js";
const C = "tests/hooks/c.js";
const BODY = "#!/usr/bin/env node\n\"use strict\";\n";

let n = 0;

// opts.branch: the only branch of the repo (default main, which gives a merge base).
function repo(opts) {
  return F.makeRepo(`rp-${++n}`, { [A]: BODY, [B]: BODY, [C]: BODY }, opts || {});
}

function session(tag) {
  const sid = `s-2688-rp-${tag}-${++n}`;
  F.seedPrefix(sid);
  return sid;
}

// dispatch(sid, cwd, seq, testArgs, contract, failing, hits) — one worker dispatch, ingested.
function dispatch(sid, cwd, seq, testArgs, contract, failing, hits) {
  const stem = F.placeOutcome(sid, { seq, cwd, testArgs, contract, failing: failing || [], hits: hits || [] });
  F.hook(sid, "git status", 0, "");
  if (!F.isIngested(sid, stem)) throw new Error(`fixture: ${stem} was not ingested`);
  return stem;
}

const parts = (sid) => {
  const p = F.runTests(sid).run_parts;
  return Array.isArray(p) ? p : null;
};
const selections = (sid) => {
  const p = parts(sid);
  return p === null ? null : p.map((e) => (Array.isArray(e.selection) ? e.selection.slice().sort() : e.selection));
};
const failing = (sid) => {
  const f = F.runTests(sid).failing_tests;
  return Array.isArray(f) ? f.slice().sort() : f;
};

module.exports = { A, B, C, repo, session, dispatch, parts, selections, failing };
