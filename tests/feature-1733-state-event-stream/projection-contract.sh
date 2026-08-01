#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/projection-contract.sh
# Tests: hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/core.js, hooks/workflow-state/is-bugfix-session.js
# Tags: workflow-state, event-stream, projection, deep-freeze, single-source-of-truth, scope:issue-specific, pwsh-not-required, TL2
#
# ~20 readers keep reading `state.steps` after #1733, so readState still PASTES a
# projection on top of the raw state. Two contracts must hold or the migration is a
# silent behaviour change:
#   (1) the pasted view is exactly projectState(raw) — one fold implementation, no
#       second derivation living in a reader (CPR-2);
#   (2) the pasted view is deep-frozen, so a legacy write into it fails LOUDLY at
#       development time rather than becoming a silent no-op.
#
# TL3 gap (what this test does NOT catch):
# - whether every real reader in hooks/ and bin/ actually survives the deep-freeze:
#   a dynamic `state.steps[x] = ...` on a path this file does not drive would still
#   throw only at runtime.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="pcon"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "== P1: every projection key readState pastes equals projectState(raw) =="
if run_case "P1/projection-agreement"; then
    next_sid
    nodejs "$SID" "$PRE"'
const PJ = require("./hooks/workflow-state/state-io/projection");
const CA = require("./hooks/workflow-state/completion-approval");
S.markStep(sid, "workflow_init", "complete");
CA.recordPlanApproval(sid, "outline", { source: "reset-sentinel", reason: "ok" });
S.markStep(sid, "outline", "complete");
S.recordSessionModel(sid, { id: "claude-opus-5", source: "transcript" });
S.recordComplexityEvaluation(sid, "high", ["S1-multi-file"]);
S.markStep(sid, "research", "skipped", { skip_reason: "n/a" });
const st = S.readState(sid);
const norm = S.normalizeStateVersion(S.readRawState(sid));
const want = PJ.projectState(norm);
const bad = [];
for (const k of PJ.PROJECTION_KEYS) {
  if (JSON.stringify(st[k]) !== JSON.stringify(want[k])) bad.push(k);
}
console.log("keys=" + PJ.PROJECTION_KEYS.length + " mismatched=" + (bad.length ? bad.join(",") : "0"));
'
    if printf '%s' "$NODE_OUT" | grep -q " mismatched=0$"; then pass "P1/projection-agreement"
    else fail "P1/projection-agreement" "$NODE_OUT"; fi
fi

echo "== P2: the pasted projection covers every documented key =="
if run_case "P2/projection-key-coverage"; then
    next_sid
    nodejs "$SID" "$PRE"'
const PJ = require("./hooks/workflow-state/state-io/projection");
const WANT = ["steps", "plan_approvals", "worktree_entered_at", "worktree_exited_at",
              "git_branch", "cwd", "is_bugfix", "session_model",
              "complexity_evaluation", "skip_judgment"];
const missing = WANT.filter((k) => !PJ.PROJECTION_KEYS.includes(k));
const extra = PJ.PROJECTION_KEYS.filter((k) => !WANT.includes(k));
S.markStep(sid, "run_tests", "complete");
const st = S.readState(sid);
const absent = WANT.filter((k) => !(k in st));
console.log("missing=" + (missing.join(",") || "0") +
            " extra=" + (extra.join(",") || "0") +
            " not_pasted=" + (absent.join(",") || "0"));
'
    assert_eq "P2/projection-key-coverage" "missing=0 extra=0 not_pasted=0" "$NODE_OUT"
fi

echo "== P3: writing into the pasted projection throws TypeError (deep-frozen) =="
if run_case "P3/deep-freeze"; then
    next_sid
    nodejs "$SID" "$PRE"'
"use strict";
S.markStep(sid, "run_tests", "complete");
const st = S.readState(sid);
const probe = (fn) => { try { fn(); return "MUTATED"; } catch (e) { return e instanceof TypeError ? "TypeError" : "Other:" + e.name; } };
console.log([
  "replace_entry=" + probe(() => { st.steps.run_tests = { status: "pending" }; }),
  "mutate_field=" + probe(() => { st.steps.run_tests.status = "pending"; }),
  "add_step=" + probe(() => { st.steps.brand_new = { status: "complete" }; }),
  "approvals=" + probe(() => { st.plan_approvals.outline = {}; }),
].join(" "));
'
    assert_eq "P3/deep-freeze" \
        "replace_entry=TypeError mutate_field=TypeError add_step=TypeError approvals=TypeError" "$NODE_OUT"
fi

echo "== P4: __projectionSnapshot is present but non-enumerable (invisible to JSON) =="
if run_case "P4/snapshot-non-enumerable"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
const st = S.readState(sid);
console.log("present=" + (st.__projectionSnapshot !== undefined) +
            " enumerable=" + Object.keys(st).includes("__projectionSnapshot") +
            " in_json=" + /__projectionSnapshot/.test(JSON.stringify(st)));
'
    assert_eq "P4/snapshot-non-enumerable" "present=true enumerable=false in_json=false" "$NODE_OUT"
fi

echo "== P5: a structuredClone-then-reassign bypass is caught by assertProjectionUnmutated =="
if run_case "P5/projection-mutated-error"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "run_tests", "complete");
const st = S.readState(sid);
// The documented mutable-copy route (structuredClone) is fine — reassigning the
// TOP-LEVEL projection key from it is the abuse this guard exists for.
const mutable = structuredClone(st.steps);
mutable.run_tests.status = "pending";
Object.defineProperty(st, "steps", { value: mutable, writable: true, enumerable: true, configurable: true });
let verdict = "NO-THROW";
try { S.writeState(sid, st); } catch (e) { verdict = e && e.name === "ProjectionMutatedError" ? "ProjectionMutatedError" : "Other:" + (e && e.name); }
console.log(verdict + " on_disk=" + cur().steps.run_tests.status);
'
    assert_eq "P5/projection-mutated-error" "ProjectionMutatedError on_disk=complete" "$NODE_OUT"
fi

echo "== P6: is_bugfix is derived from the projected git_branch, not a frozen init flag =="
if run_case "P6/is-bugfix-derived"; then
    next_sid
    nodejs "$SID" "$PRE"'
const E = require("./hooks/workflow-state/state-io/events");
S.writeState(sid, S.createInitialState(sid, { cwd: "C:\\git\\agents", git_branch: "main" }));
const before = S.readState(sid);
E.appendEvents(sid, [{
  kind: "worktree", transition: "entered", git_branch: "fix/some-bug",
  cwd: "C:\\wt\\x", worktree_path: "C:\\wt\\x", path_source: "tool_input",
  provenance: "observed", origin: "worktree-postuse",
}]);
const after = S.readState(sid);
console.log("before=" + before.git_branch + "/" + before.is_bugfix +
            " after=" + after.git_branch + "/" + after.is_bugfix);
'
    assert_eq "P6/is-bugfix-derived" "before=main/false after=fix/some-bug/true" "$NODE_OUT"
fi

echo "== P7: a step never marked projects as pending/updated_at:null (default, not stored) =="
if run_case "P7/pending-default"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const st = S.readState(sid);
const e = st.steps.docs || {};
const stored = rd().events.some((x) => x.step === "docs");
console.log("status=" + e.status + " updated_at=" + e.updated_at + " stored_event=" + stored);
'
    assert_eq "P7/pending-default" "status=pending updated_at=null stored_event=false" "$NODE_OUT"
fi

echo "== P8: skip_judgment is a convenience view over steps[*].skip_judgment =="
if run_case "P8/skip-judgment-view"; then
    next_sid
    nodejs "$SID" "$PRE"'
const R = require("./hooks/workflow-state/skip-signal-resolver");
S.markStep(sid, "research", "skipped", { skip_judgment: { decision: "skip", recorded_at: "2026-06-20T10:00:00.000Z" } });
const st = S.readState(sid);
console.log("view=" + JSON.stringify(st.skip_judgment.research) +
            " matches_step=" + (JSON.stringify(st.skip_judgment.research) === JSON.stringify(st.steps.research.skip_judgment)) +
            " resolver_loaded=" + (typeof R === "object"));
'
    if printf '%s' "$NODE_OUT" | grep -q "matches_step=true resolver_loaded=true"; then
        pass "P8/skip-judgment-view"
    else fail "P8/skip-judgment-view" "$NODE_OUT"; fi
fi

finish "projection-contract"
