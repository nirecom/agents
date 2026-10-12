#!/usr/bin/env bash
# tests/tests/feature-2501-run-all-report.sh — dispatcher for the #2501 run-all report suite.
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh
# Tags: tests, bin, run-all, report, scope:issue-specific
#
# Members are discovered by glob from tests/tests/feature-2501-run-all-report/*.sh (_*.sh are
# helpers). Member output is masked so no report-shaped line reaches the outer runner unprefixed.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2501-run-all-report"
CASE_TIMEOUT="${FEATURE_2501_CASE_TIMEOUT:-300}"

mask_report() {
    sed -E 's/^([[:blank:]]*)(RUN_CONTRACT:|UNRUNNABLE:|TIMEOUT:|Missing runtimes:)/\1[masked] \2/'
}

MEMBERS_RUN=0
case_begin "dispatch-members" "tests/run-all.sh"
if [ ! -d "$CASE_DIR" ]; then
    fail "member directory missing: $CASE_DIR"
fi
shopt -s nullglob
for member in "$CASE_DIR"/*.sh; do
    name="${member##*/}"
    case "$name" in _*) continue ;; esac
    echo ""
    echo "########## $name ##########"
    run_with_timeout "$CASE_TIMEOUT" bash "$member" 2>&1 | mask_report
    rc=${PIPESTATUS[0]}
    MEMBERS_RUN=$((MEMBERS_RUN + 1))
    case "$rc" in
        0) pass "$name" ;;
        77) skip "$name" ;;
        *) fail "$name" "exit $rc" ;;
    esac
done
[ "$MEMBERS_RUN" -gt 0 ] || fail "no member ran under $CASE_DIR"
case_end

echo ""
echo "=== feature-2501 report dispatcher: pass=$PASS fail=$FAIL skip=$SKIP ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
