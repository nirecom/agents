#!/usr/bin/env bash
# tests/feature-2013-step-in-flight-automark.sh
# Tests: hooks/lib/step-in-flight-policy.js, hooks/workflow-state/lifecycle.js, hooks/postuse-step-in-flight-mark.js, hooks/workflow-state/effective-state.js, hooks/stop-premature-stop-guard.js, settings.json
# Tags: stop-hook, c4, step-in-flight, posttooluse, automark, allowlist, matrix, malformed-input, wi-10-lookahead, regression-2013, scope:issue-specific, pwsh-not-required, TL1, TL2

# Issue #2013 — an Agent-tool dispatch during WI-10 tripped the C4 premature-stop
# guard: `research` was never recorded in_progress, so nothing told C4 that work
# was under way. Two halves, both covered here:
#   A (TL1) — the predicate. isStepInFlight / anyStepInFlight over a four-member
#     allowlist inside a 4h TTL, fail-CLOSED, write_code predicate untouched.
#   B (TL2) — the write. The real PostToolUse hook spawned as a child process,
#     including the WI-10 lookahead (absent state / workflow_init-pending both
#     resolve to `research`) and the malformed-payload classes it must survive.
#   C (TL2) — the read, at the consumer that motivated the issue: the real C4
#     Stop guard over all four allowlisted steps x four record states.

# Every positive case is paired with its non-targeted counterpart (CPR-ORTH):
# allowlisted vs not, dispatch tool vs not, main conversation vs subagent, fresh
# vs TTL-expired. A fix that over-reaches into "any in_progress step silences
# C4" fails A5/A6/A7/A12/B8/B9.

# TL3 gap (what this test does NOT catch):
# - Whether Claude Code fires PostToolUse for Agent/Task/Skill with the payload
#   shape assumed here (agent_id presence in particular), or UserPromptSubmit
#   for the mechanism-check hook. A renamed matcher/event/command in settings.json
#   would break host dispatch without any TL2 test failing; a host-process test
#   with claude -p would catch this, but requires RUN_TL3=on.
# - Whether the real Stop chain stays silent across a genuine multi-minute
#   dispatch driven by Claude Code itself

# - Real matcher-string semantics inside the host's hook dispatcher: A14 reads
#   settings.json as data only. No test verifies a main-agent payload where
#   `agent_id` is absent (Claude may omit it in main-conversation PostToolUse).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
CASE_DIR="$AGENTS_DIR/tests/feature-2013-step-in-flight-automark"

# Fixture isolation (rules/test/fixture-isolation.md): never let a spawned node
# resolve the developer's live session or the real ~/.workflow-plans.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# shellcheck source=/dev/null
. "$CASE_DIR/helpers.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/a-predicate.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/b-posttooluse.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/c-guard.sh"

# Sourced-fragment sanity gate (same rationale as the #1794 suite): a fragment
# that dies half-way leaves some functions defined and the rest missing, and
# under `set -u` a call to a missing function only prints to stderr. Verify every
# entrypoint exists BEFORE a single case runs, and abort loudly.
require_defined() {
    local missing="" fn
    for fn in "$@"; do
        declare -f "$fn" >/dev/null 2>&1 || missing="$missing $fn"
    done
    if [ -n "$missing" ]; then
        echo "FATAL: partial source — these functions are not defined:$missing" >&2
        echo ""
        echo "Results: 0 passed, 1 failed, 0 skipped"
        exit 1
    fi
}
require_defined \
    pass fail skip \
    make_tmp node_path seed_step seed_started backdate_step strip_updated_at \
    in_flight_fixture pred_eval assert_pred run_automark run_automark_raw run_c4 \
    trim step_status event_count state_digest settle_through \
    run_A1 run_A2 run_A3 run_A4 run_A5 run_A6 run_A7 run_A8 run_A9 run_A10 \
    run_A11 run_A12 run_A13 run_A14 run_A15 run_A16 \
    run_B1 run_B2 run_B3 run_B4 run_B5 run_B5b run_B6 run_B7 run_B8 run_B9 \
    run_B10 run_B11 run_B12 \
    run_C1 run_C2 run_C3

# A1-A15 — predicate + policy + registration
run_A1
run_A2
run_A3
run_A4
run_A5
run_A6
run_A7
run_A8
run_A9
run_A10
run_A11
run_A12
run_A13
run_A14
run_A15
run_A16

# B1-B12 — the real PostToolUse auto-mark hook
run_B1
run_B2
run_B3
run_B4
run_B5
run_B5b
run_B6
run_B7
run_B8
run_B9
run_B10
run_B11
run_B12

# C1-C3 — the real C4 Stop guard, the consumer the record exists to influence
run_C1
run_C2
run_C3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
