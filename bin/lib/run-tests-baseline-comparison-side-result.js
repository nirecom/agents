"use strict";
// comparison side result: builds {verdict, termination, exitCode, hitKind} from the return value of
// `rtb_exec_one`, RTB_EXEC_*, and the err hit lines. Takes no argument naming which comparison side it is.
// Contract: docs/architecture/claude-code/test-result-contract.md

const REQUIRED = ["RTB_EXEC_STATE", "RTB_EXEC_DECOY", "returnCode"];
// Same regex as `rtb_branch_guard_only_fail` (tells apart a hit made of guard lines only).
const GUARD_RE = /^\[run-all\] command guard hit: /;
const OTHER_HIT_RE = /^\[run-all\] (root decoy hit|worktree change:|[0-9]+ (root decoy hit|worktree change|command guard hit))/;

function flag(v) {
  return String(v === undefined || v === null ? "" : v) === "1";
}

function hitKindOf(e, errHitLines) {
  if (!flag(e.RTB_EXEC_DECOY)) return "none";
  const guard = errHitLines.some((l) => GUARD_RE.test(String(l)));
  const other = errHitLines.some((l) => OTHER_HIT_RE.test(String(l)));
  return guard && !other ? "command-guard-hit-only" : "root-decoy-or-worktree-change";
}

function exitCodeOf(e) {
  const s = String(e.RTB_EXEC_RC === undefined || e.RTB_EXEC_RC === null ? "" : e.RTB_EXEC_RC);
  if (/^[0-9]+$/.test(s)) return parseInt(s, 10);
  // On setup failure the launcher leaves no rc, so null is allowed.
  if (Number(e.returnCode) === 2) return null;
  throw new Error(`comparison side result: RTB_EXEC_RC is not numeric: ${JSON.stringify(s)}`);
}

function parseComparisonSideResult(execOutputs, errHitLines) {
  if (!execOutputs || typeof execOutputs !== "object") throw new Error("comparison side result: execOutputs must be an object");
  if (!Array.isArray(errHitLines)) throw new Error("comparison side result: errHitLines must be an array");
  for (const k of REQUIRED) {
    if (!(k in execOutputs)) throw new Error(`comparison side result: missing ${k}`);
  }
  const e = execOutputs;
  const hitKind = hitKindOf(e, errHitLines);
  if (Number(e.returnCode) === 2) return { verdict: "-", termination: "launcher-setup-failed", exitCode: null, hitKind };
  const exitCode = exitCodeOf(e);
  const state = String(e.RTB_EXEC_STATE);
  const out = (verdict, termination) => ({ verdict, termination, exitCode, hitKind });
  if (flag(e.RTB_EXEC_TIMEDOUT)) return state === "TIMEOUT" ? out("-", "timeout") : out("-", "interrupted-by-outer-watchdog");
  if (flag(e.RTB_EXEC_UNSUPPORTED)) return out("-", "unsupported");
  if (flag(e.RTB_EXEC_UNRUNNABLE)) return out("-", "unrunnable");
  if (state === "PASS" || state === "FAIL" || state === "SKIP") return out(state, "completed");
  // TIMEOUT with TIMEDOUT=0, an unknown state, and no state all map to ?/? (the state string is not kept).
  return out("?", "?");
}

module.exports = { parseComparisonSideResult };
