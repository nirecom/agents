#!/usr/bin/env bash
# tests/agents/feature-clarify-intent-aggregate.sh
# Tests: tests/agents/feature-clarify-intent.sh
# Tags: workflow, clarify-intent, aggregate, exit-contract, scope:issue-specific
# #2649 review C1: the clarify-intent dispatcher's exit contract, run against fixture children
# through its CLARIFY_INTENT_SPLIT_DIR seam. A child that exits non-zero, a child with no Results
# line, or a child that reports failures must each make the parent exit non-zero; an all-green
# pair must exit 0. Each scenario's fixtures live in their own temp dir.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

readonly TMPROOT="$(make_tmp)"
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
unset CLAUDE_CODE_SESSION_ID

PARENT="$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-clarify-intent.sh"
GROUP_A="static-series.sh"
GROUP_B="companion-precheck-series.sh"

# child_fixture <path> <kind>: the shapes a split group can end in.
child_fixture() {
    case "$2" in
        green)        printf '%s\n' 'echo "Results: 3 passed, 0 failed"' 'exit 0' > "$1" ;;
        crash)        printf '%s\n' 'echo "Results: 3 passed, 0 failed"' 'exit 3' > "$1" ;;
        silent)       printf '%s\n' 'echo "no summary here"' 'exit 0' > "$1" ;;
        reports-fail) printf '%s\n' 'echo "Results: 2 passed, 1 failed"' 'exit 0' > "$1" ;;
    esac
}

# scenario <name> <kind-A|absent> <kind-B|absent>: builds the fixture dir, runs the parent once,
# and leaves "<rc>" and the parent's output under $TMPROOT/<name>.
scenario() {
    local d="$TMPROOT/$1"
    mkdir -p "$d/split"
    [ "$2" = absent ] || child_fixture "$d/split/$GROUP_A" "$2"
    [ "$3" = absent ] || child_fixture "$d/split/$GROUP_B" "$3"
    local rc=0
    _TIMEOUT_WRAPPED=1 CLARIFY_INTENT_SPLIT_DIR="$d/split" \
        run_with_timeout 60 bash "$PARENT" > "$d/out" 2>&1 || rc=$?
    printf '%s' "$rc" > "$d/rc"
}

rc_of() { cat "$TMPROOT/$1/rc" 2>/dev/null || printf 'NO-RC'; }
rc_class() { [ "$(rc_of "$1")" = "0" ] && printf 'zero' || printf 'non-zero'; }
summary_of() { grep -E '^PASS: [0-9]+  FAIL:' "$TMPROOT/$1/out" 2>/dev/null | tail -1; }

scenario green        green        green
scenario crash        crash        green
scenario silent       silent       green
scenario reports-fail reports-fail green
scenario all-silent   silent       silent
scenario missing      green        absent

ROWS=0
check() { # <label> <want> <got>
    ROWS=$((ROWS + 1))
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi
}

case_begin "clarify-intent-aggregate-exit" "tests/agents/feature-clarify-intent.sh"
while IFS='|' read -r id name want label; do
    [ -n "$id" ] || continue
    check "$id: $label" "$want" "$(rc_class "$name")"
done <<'AGG_CASES'
AG1|green|zero|CONTROL: two children that both exit 0 with a 0-failed Results line → parent exits 0
AG2|crash|non-zero|a child that prints "0 failed" and then exits 3 → parent non-zero (its exit status is authoritative)
AG3|silent|non-zero|a child that exits 0 but prints no Results line → parent non-zero
AG4|reports-fail|non-zero|a child whose Results line reports 1 failed (exit 0) → parent non-zero
AG5|all-silent|non-zero|no child prints a Results line at all → parent non-zero
AG6|missing|non-zero|a split group file that does not exist → parent non-zero
AGG_CASES

# The summary pins WHICH guard fired, so a row above cannot pass for the wrong reason.
check "AG1s: the green control aggregates both children's counts" \
    "PASS: 6  FAIL: 0  GROUP_RC_FAIL: 0  RESULTS_SEEN: 2" "$(summary_of green)"
check "AG2s: the crash is caught by the exit-status guard alone (FAIL stays 0)" \
    "PASS: 6  FAIL: 0  GROUP_RC_FAIL: 1  RESULTS_SEEN: 2" "$(summary_of crash)"
check "AG3s: the missing Results line counts as one failure" \
    "PASS: 3  FAIL: 1  GROUP_RC_FAIL: 0  RESULTS_SEEN: 1" "$(summary_of silent)"
check "AG4s: the reported failure is carried into the total" \
    "PASS: 5  FAIL: 1  GROUP_RC_FAIL: 0  RESULTS_SEEN: 2" "$(summary_of reports-fail)"
check "AG5s: no Results line from any child leaves RESULTS_SEEN at 0" \
    "PASS: 0  FAIL: 2  GROUP_RC_FAIL: 0  RESULTS_SEEN: 0" "$(summary_of all-silent)"
case_end

ROWS_EXPECTED=11
if [ "$ROWS" -eq "$ROWS_EXPECTED" ]; then pass "TOTAL: all $ROWS_EXPECTED rows ran"
else fail "TOTAL" "rows ran=$ROWS expected=$ROWS_EXPECTED"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
