# shellcheck shell=bash
# tests/feature-1665-run-outcome/h-dispatcher-basename-parity.sh
# Tests: hooks/workflow-run-tests/exec-model.js, hooks/enforce-worktree/worker-dispatch-write.js
# Tags: workflow, run-outcome, drift-detection, worker-dispatch, parity, TL1, scope:issue-specific
#
# TL1 — both modules required directly.
#
# WHY (CPR-WPH): two independent modules each hold the literal "worker-dispatch.js".
#   exec-model.js DISPATCHER_SCRIPTS  — "which script names emit a worker payload,
#                                       and for which workers?"  (a routing table)
#   worker-dispatch-write.js DISPATCH_BASENAME
#                                     — "is this Write call the dispatcher writing
#                                        its own result file?" (a guard predicate)
# They answer DIFFERENT questions and legitimately have different shapes, so this is
# deliberately NOT an SSOT-ization: collapsing them would couple a hook guard to a
# routing table for the sake of one shared string. What they do share is that string,
# and renaming bin/worker-dispatch.js updates one and silently strands the other —
# the outcome axis would then be read from an unrouted emitter and never recorded.
#
# So this is a DRIFT TEST: it asserts the overlap, not the ownership. If a future
# refactor genuinely unifies them, this file becomes redundant and should be deleted
# rather than weakened.

run_h_dispatcher_basename_parity_cases() {
    echo ""
    echo "=== h-dispatcher-basename-parity (TL1: drift detection) ==="

    local out
    out="$(run_with_timeout 30 node -e '
const em = require(process.argv[1] + "/hooks/workflow-run-tests/exec-model");
const wd = require(process.argv[2] + "/hooks/enforce-worktree/worker-dispatch-write");
const parts = [];
const scripts = em.DISPATCHER_SCRIPTS;
parts.push("is-map=" + (scripts instanceof Map));
parts.push("keys=" + (scripts instanceof Map ? [...scripts.keys()].sort().join(";") : "(absent)"));
parts.push("basename=" + (typeof wd.DISPATCH_BASENAME === "string" ? wd.DISPATCH_BASENAME : "(absent)"));
parts.push("contains=" + (scripts instanceof Map && typeof wd.DISPATCH_BASENAME === "string"
  ? String(scripts.has(wd.DISPATCH_BASENAME)) : "false"));
const workers = (scripts instanceof Map && scripts.get(wd.DISPATCH_BASENAME)) || null;
parts.push("workers=" + (workers ? [...workers].sort().join(";") : "(absent)"));
process.stdout.write(parts.join("\n"));
' "$AGENTS_WIN" "$AGENTS_WIN" 2>/dev/null || echo "ERR:require-failed")"

    field() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

    assert_eq "H1/DISPATCHER_SCRIPTS-is-a-Map" "true" "$(field is-map)"
    assert_eq "H2/DISPATCH_BASENAME-exported" "worker-dispatch.js" "$(field basename)"
    assert_eq "H3/basename-is-a-routed-dispatcher" "true" "$(field contains)"

    # The routed worker set must actually contain the test runner, otherwise the
    # basename is registered but no test payload is ever attributed to it —
    # parity on the key alone would be a false green (CPR-E2E).
    assert_contains "H4/test-runner-is-routed" "test-runner" "$(field workers)"

    # Negative control: an unrelated script name must NOT be routed. Without this,
    # a DISPATCHER_SCRIPTS that matched everything would pass H3.
    local anyname
    anyname="$(run_with_timeout 30 node -e '
const { DISPATCHER_SCRIPTS } = require(process.argv[1] + "/hooks/workflow-run-tests/exec-model");
process.stdout.write(String(DISPATCHER_SCRIPTS.has("run-all.sh")));
' "$AGENTS_WIN" 2>/dev/null || echo "ERR")"
    assert_eq "H5/unrelated-script-not-routed" "false" "$anyname"
}
