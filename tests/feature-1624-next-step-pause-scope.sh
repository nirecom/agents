#!/usr/bin/env bash
# tests/feature-1624-next-step-pause-scope.sh
# Tests: hooks/lib/next-step-pause-marker.js, hooks/lib/session-markers.js, hooks/workflow-mark/enforce-override-handlers/next-step-pause.js, bin/workflow/lib/next-step/verdict.js, hooks/stop-premature-stop-guard.js, hooks/lib/protected-basenames.js
# Tags: next-step-pause, marker-v2, for-step, ttl, audit, security, parser, regression-1624, scope:issue-specific, pwsh-not-required, TL1, TL2

# Issue #1624 — the NEXT_STEP_PAUSE marker was a bare existence flag: no step
# scope, no expiry, no audit trail. A pause taken to wait out one subagent
# therefore silenced next-step for every LATER step too, and, having no TTL,
# stayed silent until someone remembered to resume by hand.

# v2 fixes all three at once, so the suite is organised by property:
#   C (c-scope.sh)      — shape, for_step scoping, expiry, the real sentinel
#                         handler, the real next-step consumer, the audit trail
#   D (d-consumers.sh)  — the REAL C4 Stop guard and the REAL next-step binary,
#                         one row per scope variant (match / mismatch / any /
#                         untagged / expired), each with a no-marker control
#   E (e-robustness.sh) — malformed markers, the whole expires_at input domain,
#                         and the [for=...] reason parser as a table
#   F (f-security.sh)   — hostile session ids, which become filenames

# TL3 gap (what this test does NOT catch):
# - Whether Claude Code routes a typed PAUSE sentinel through the real
#   PostToolUse chain into the handler (C8 drives the handler directly)
# - Whether a real Stop round trip reaches C4 with the payload shape D1 assumes
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
CASE_DIR="$AGENTS_DIR/tests/feature-1624-next-step-pause-scope"

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
. "$CASE_DIR/c-scope.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/d-consumers.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/e-robustness.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/f-security.sh"

# Sourced-fragment sanity gate: a fragment that dies half-way leaves some
# functions defined and the rest missing, and under `set -u` a call to a missing
# function only prints to stderr. Verify every entrypoint exists BEFORE a single
# case runs, and abort loudly.
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
    make_tmp node_path write_pause marker_path pause_active assert_active \
    seed_started expire_marker patch_marker run_c4 run_next_step ns_action \
    sup_findings_text trim read_marker _drive_row _sid_probe \
    run_C1 run_C2 run_C3 run_C4 run_C5 run_C6 run_C7 run_C8 run_C8_audit run_C8_resume run_C9 run_C10 \
    run_D1 run_D2 \
    run_E1 run_E2 run_E3 \
    run_F1 run_F2 run_F2b run_F3

# C1-C10 — marker shape, scoping, expiry, real handler/consumer, audit
run_C1
run_C2
run_C3
run_C4
run_C5
run_C6
run_C7
run_C8
run_C8_audit
run_C8_resume
run_C9
run_C10

# D1-D2 — the real C4 guard and the real next-step binary, per scope variant
run_D1
run_D2

# E1-E3 — malformed markers, expires_at domain, [for=...] parser
run_E1
run_E2
run_E3

# F1-F3 — hostile session ids
run_F1
run_F2
run_F2b
run_F3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
