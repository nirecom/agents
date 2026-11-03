"use strict";
// bin/workflow/lib/run-tests-baseline-evidence/rerun-list.js — the paths a partial rerun must
// cover (#2803): the latest run's failing tests plus the test id of each worktree-change HIT.
// A HIT with no test id cannot be narrowed, so only a full rerun is safe (exit 9). Read-only.

const path = require("path");

const HOOKS = path.join(__dirname, "..", "..", "..", "..", "hooks");
const EXIT = { OK: 0, STATE: 3, FULL: 9 };

function stateIo() {
  return require(path.join(HOOKS, "workflow-state", "state-io"));
}

function hitTestId(line) {
  return require(path.join(HOOKS, "workflow-run-tests", "hit-summary")).hitTestId(line);
}

// -> { code, stdout, stderr }.
function rerunList(sessionId) {
  let entry;
  try {
    const state = stateIo().readState(sessionId);
    entry = state && state.steps ? state.steps.run_tests || null : null;
  } catch (e) {
    return { code: EXIT.STATE, stdout: null, stderr: `state read failed: ${e.message}` };
  }
  if (!entry) return { code: EXIT.STATE, stdout: null, stderr: "run_tests has no state entry" };
  const failing = Array.isArray(entry.failing_tests) ? entry.failing_tests : [];
  const hits = Array.isArray(entry.hit_summary) ? entry.hit_summary : [];
  const ids = [];
  for (const line of hits) {
    const id = typeof line === "string" ? hitTestId(line) : null;
    if (id === null) {
      return { code: EXIT.FULL, stdout: null, stderr: `a HIT names no test; rerun the full suite: ${String(line)}` };
    }
    ids.push(id);
  }
  const paths = [...new Set([...failing, ...ids].filter((p) => typeof p === "string" && p !== ""))];
  return { code: EXIT.OK, stdout: paths.map((p) => `${p}\n`).join(""), stderr: null };
}

module.exports = { EXIT, rerunList };
