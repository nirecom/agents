"use strict";
// Tools rows.js uses to build a row's when: a predicate is an array of conj (feature name -> { in } | { notIn }), in DNF.
// and takes the product, intersects conditions on the same feature, and drops unsatisfiable conj. Output is plain data only.

const C = (conj) => [conj];
const IN = (vals) => ({ in: vals });
const NOT_IN = (vals) => ({ notIn: vals });

function mergeCond(a, b) {
  if (a.in && b.in) return IN(a.in.filter((x) => b.in.includes(x)));
  if (a.in) return IN(a.in.filter((x) => !b.notIn.includes(x)));
  if (b.in) return IN(b.in.filter((x) => !a.notIn.includes(x)));
  return NOT_IN([...a.notIn, ...b.notIn.filter((x) => !a.notIn.includes(x))]);
}

function mergeConj(x, y) {
  const o = Object.assign({}, x);
  for (const k of Object.keys(y)) o[k] = k in o ? mergeCond(o[k], y[k]) : y[k];
  return Object.values(o).some((c) => c.in && c.in.length === 0) ? null : o;
}

const and = (...ps) => ps.reduce((acc, p) => acc.flatMap((x) => p.map((y) => mergeConj(x, y)).filter(Boolean)), [{}]);
const or = (...ps) => [].concat(...ps);

const KILL = [137, 143];
const INTERRUPT = [124, 142];
const AMBIGUOUS = [124, 137, 142, 143];
const DECOY = "root-decoy-or-worktree-change";
const GUARD = "command-guard-hit-only";

// How one comparison side result is read (order shared by `rtb_branch_run_one` and the merge base side case statement).
// A hit made of guard lines only is not a decoy only when the test itself FAILs (`rtb_branch_guard_only_fail`).
function sidePredicates(name) {
  const t = `${name}.termination`;
  const v = `${name}.verdict`;
  const h = `${name}.hitKind`;
  const rcIn = (vals) => C({ [`${name}.exitCode`]: IN(vals) });
  const rcNotIn = (vals) => C({ [`${name}.exitCode`]: NOT_IN(vals) });
  const rest0 = C({ [t]: NOT_IN(["launcher-setup-failed", "timeout", "interrupted-by-outer-watchdog", "unsupported"]) });
  const notDecoy = and(rest0, or(C({ [h]: NOT_IN([DECOY, GUARD]) }), C({ [h]: IN([GUARD]), [v]: IN(["FAIL"]) })));
  const rest1 = and(notDecoy, C({ [t]: NOT_IN(["unrunnable"]) }));
  const verdict = (vals) => and(rest1, C({ [v]: IN(vals) }));
  const stateLess = and(rest1, C({ [v]: NOT_IN(["PASS", "FAIL", "SKIP"]) }));
  return {
    setup: C({ [t]: IN(["launcher-setup-failed"]) }),
    timeout: C({ [t]: IN(["timeout", "interrupted-by-outer-watchdog"]) }),
    unsupported: C({ [t]: IN(["unsupported"]) }),
    decoy: and(rest0, or(C({ [h]: IN([DECOY]) }), C({ [h]: IN([GUARD]), [v]: NOT_IN(["FAIL"]) }))),
    unrunnable: and(notDecoy, C({ [t]: IN(["unrunnable"]) })),
    verdict, stateLess, rcIn, rcNotIn,
  };
}

module.exports = { C, IN, NOT_IN, and, or, sidePredicates, KILL, INTERRUPT, AMBIGUOUS };
