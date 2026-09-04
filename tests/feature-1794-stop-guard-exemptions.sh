#!/usr/bin/env bash
# tests/feature-1794-stop-guard-exemptions.sh
# Tests: hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, hooks/supervisor-guard/detect.js, hooks/lib/stop-exemption-policy.js, hooks/lib/session-markers.js, hooks/lib/sentinel-patterns.js, hooks/workflow-state/lifecycle.js, hooks/workflow-state/state-io/zombie-cleanup.js, hooks/workflow-mark/enforce-override-handlers.js, bin/workflow/lib/next-step/verdict.js, hooks/session-start.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/effective-state.js, settings.json, hooks/user-prompt-submit-mechanism-check.js
# Tags: stop-hook, supervisor-guard, exemption, session-marker, session-inherit, provenance, regression-1794, prompt-notify, regression-2169, scope:issue-specific, pwsh-not-required, TL1, TL2

# Issues #1794 (isWorkflowStarted + C4_EXEMPTIONS/C2 pre-workflow-init gate), #1665 (background-work marker removal, replaced by state-derived write-code-in-flight), and #2169 (the promptNotify column) — the Stop-guard exemption layer. X/T/Z are TL2 real hook/next-step runs; M/N is TL1 plus a TL2 cross-check of EXEMPTION_MATRIX; Z1 is the marker-suffix sweep-containment/resilience row; I1-I14 are the #1794 session-inheritance adoption regression (real session-start.js against a donor state + transcript), with I4/I7/I8/I12 as over-suppression guards and I10/I10b/I11/I13/I14 as the TL1 predicate and idempotency tables.

# TL3 gap: real Claude Code Stop/PostToolUse/SessionStart/UserPromptSubmit hook wiring and a real stop_hook_active auto-resume round trip are not exercised here. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
CASE_DIR="$AGENTS_DIR/tests/feature-1794-stop-guard-exemptions"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# shellcheck source=/dev/null
. "$CASE_DIR/helpers.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/x-lifecycle.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/m-policy-matrix.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/n-prompt-notify-matrix.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/i-inherited-adoption.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/i-adoption-predicate.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/i-guard-robustness.sh"

# Sourced-fragment sanity gate. `.` on a path that does not exist, or a fragment
# that dies half-way through (syntax error in a later function, a helper renamed
# on one side of a split), leaves SOME functions defined and the rest missing —
# and with `set -u` alone a case body calling a missing function just prints a
# "command not found" line to stderr and carries on, which a grep-based
# assertion can silently read as a pass. Verify every helper and every case
# entrypoint is actually defined BEFORE a single case runs, and abort loudly.
require_defined() {
    local missing="" fn
    for fn in "$@"; do
        declare -f "$fn" >/dev/null 2>&1 || missing="$missing $fn"
    done
    if [ -n "$missing" ]; then
        echo "FATAL: partial source — these functions are not defined:$missing" >&2
        echo "       (check the '. \$CASE_DIR/...' lines above and each fragment's syntax)" >&2
        echo ""
        echo "Results: 0 passed, 1 failed, 0 skipped"
        exit 1
    fi
}
require_defined \
    pass fail skip \
    make_tmp node_path seed_started seed_preinit seed_raw_state seed_corrupt_state \
    seed_sup_armed seed_sup_error seed_write_code_in_flight seed_pause_marker age_file \
    run_c4 run_c2 run_mark run_next_step hostile_sid_probe no_new_finding \
    mk_fixture_repo inh_node seed_donor_and_inherit seed_recording_only \
    inh_wf inh_guard inh_probe inh_anchor write_hang_transcript pred_eval \
    run_X1 run_X2 run_X3 run_X4 run_X5 run_X6 run_X7 run_T17 run_T18 run_Z1 \
    run_M1a run_M1b run_M1c run_M1d run_M1e run_M2 run_M3a run_M3b run_M3c \
    run_N1 run_N2 run_N3 \
    run_I1 run_I2 run_I3 run_I4 run_I5 run_I6 run_I7 run_I8 run_I9 \
    run_I10 run_I10b run_I11 run_I12 run_I13 run_I14

# X1-X7 + T17/T18 — isWorkflowStarted and the C4/C2 restructuring
run_X1
run_X2
run_X3
run_X4
run_X5
run_X6
run_X7
run_T17
run_T18
run_Z1

# M1-M3 — EXEMPTION_MATRIX cross-checks (M1-e is the #1665 write-code-in-flight
# row that replaced background-work)
run_M1a
run_M1b
run_M1c
run_M1d
run_M1e
run_M2
run_M3a
run_M3b
run_M3c

# N1-N3 — the promptNotify column (#2169) cross-checked against
# hooks/user-prompt-submit-mechanism-check.js
run_N1
run_N2
run_N3

# I1-I14 — session-inheritance adoption regression (#1794)
run_I1
run_I2
run_I3
run_I4
run_I5
run_I6
run_I7
run_I8
run_I9
run_I10
run_I10b
run_I11
run_I12
run_I13
run_I14

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
