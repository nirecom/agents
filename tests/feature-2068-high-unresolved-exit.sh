#!/usr/bin/env bash
# tests/feature-2068-high-unresolved-exit.sh
# Tests: bin/run-codex-review-loop, bin/review-loop-verdict, bin/review-loop-summarize-concerns, bin/concern-ledger
# Tags: codex-review-loop, high-unresolved, exit-codes, concern-ledger, table-driven, TL2, scope:issue-specific
#
# #2068: a round that ends with HIGH concerns still open at the budget ceiling
# used to LAND — the wrapper absorbed it as public exit 0, deleted the ledger and
# told the orchestrator the plan was approved. The findings vanished. This suite
# fixes the replacement contract: exit 6 HIGH_UNRESOLVED, ledger kept, artifact
# written, and the terminal round's raw codex output still on stdout so the
# orchestrator can persist it.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
# shellcheck source=./lib/codex-loop-fixture.sh
. "$AGENTS_ROOT/tests/lib/codex-loop-fixture.sh"

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

ROOT="$TMPDIR_BASE/agents"
clf_make_root "$ROOT" "$AGENTS_ROOT"
clf_stub_reviewer "$ROOT"

HIGH_TEXT="a high severity concern that must never be absorbed as approved"
export CLF_HIGH_TEXT="$HIGH_TEXT"

# raw_path <plans> <sid> <format> <n> — the RAW_FILE the orchestrator writes for
# a round. The four names are historically irregular; the table in
# skills/_shared/codex-review-loop.md (d.1) is the SSOT this mirrors.
raw_path() {
    case "$3" in
        detail-plan)   printf '%s/%s-codex-round-%s-raw.md' "$1" "$2" "$4" ;;
        outline-plan)  printf '%s/%s-outline-codex-round-%s-raw.md' "$1" "$2" "$4" ;;
        security-plan) printf '%s/%s-security-plan-codex-round-%s-raw.md' "$1" "$2" "$4" ;;
        test-review)   printf '%s/%s-test-review-codex-round-%s-raw.md' "$1" "$2" "$4" ;;
    esac
}

# save_raw <stdout> <path> — what d.1 tells the orchestrator to do with the
# wrapper's stdout. Never overwrites (#2068 P4-2).
save_raw() {
    [ -f "$2" ] && return 0
    printf '%s\n' "$1" > "$2"
}

check_finalized() {
    AGENTS_CONFIG_DIR="$ROOT" bash "$ROOT/bin/concern-ledger" check-finalized \
        --plans-dir "$1" --session-id "$2" --format "$3" --round "$4" >/dev/null 2>&1
    printf '%s' "$?"
}

# ---------------------------------------------------------------------------
# 1. The terminal itself, across all four formats (CPR-ORTH). Each runs a real
#    round 1 (CONTINUE) and then a round 2 at a budget of zero, which is the
#    only condition under which the old LAND path could fire.
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-1: HIGH still open at the ceiling terminates as exit 6 ---"

while IFS='|' read -r FMT SID; do
    case "$FMT" in ''|\#*) continue ;; esac

    PLANS="$TMPDIR_BASE/plans-$FMT"
    clf_plans "$PLANS"
    LEDGER="$(clf_ledger_path "$PLANS" "$SID" "$FMT")"
    ROUNDF="$(clf_round_path "$PLANS" "$SID" "$FMT")"
    LASTF="$(clf_last_round_path "$PLANS" "$SID" "$FMT")"
    ARTIFACT="$(clf_artifact_path "$PLANS" "$SID" "$FMT")"

    # Round 1 — the loop must continue, holding the concern in the ledger.
    clf_run "$ROOT" "$PLANS" "$SID" "$FMT" \
        --cap 2 --max-extensions 0 --extensions-used 0 --round 1
    R1_RC="$CLF_RC"
    save_raw "$CLF_OUT" "$(raw_path "$PLANS" "$SID" "$FMT" 1)"
    RAW1="$(raw_path "$PLANS" "$SID" "$FMT" 1)"
    RAW1_DIGEST="$(clf_digest "$RAW1")"

    assert_eq "1 ($FMT): round 1 continues rather than terminating" "1" "$R1_RC"
    assert_eq "1 ($FMT): and the round's concern is held in the ledger" \
        "present" "$(clf_file_state "$LEDGER")"
    assert_eq "1 ($FMT): with no unresolved-concerns artifact yet" \
        "missing" "$(clf_file_state "$ARTIFACT")"

    # Round 2 at budget zero with no risk signal — the old LAND condition.
    clf_run "$ROOT" "$PLANS" "$SID" "$FMT" \
        --cap 2 --max-extensions 0 --extensions-used 0 --round 2
    R2_RC="$CLF_RC"
    R2_OUT="$CLF_OUT"
    save_raw "$R2_OUT" "$(raw_path "$PLANS" "$SID" "$FMT" 2)"
    RAW2="$(raw_path "$PLANS" "$SID" "$FMT" 2)"

    assert_eq "1 ($FMT): the round terminates as HIGH_UNRESOLVED (exit 6)" "6" "$R2_RC"
    # Stated separately and deliberately: exit 0 is the defect this issue is
    # about, so "not approved" is its own observation, not a corollary.
    assert_ne "1 ($FMT): and specifically NOT as APPROVED (exit 0)" "0" "$R2_RC"
    assert_eq "1 ($FMT): the ledger survives the terminal round" \
        "present" "$(clf_file_state "$LEDGER")"
    assert_eq "1 ($FMT): an unresolved-concerns artifact is written" \
        "present" "$(clf_file_state "$ARTIFACT")"
    assert_contains "1 ($FMT): carrying the HIGH concern nobody resolved" \
        "$HIGH_TEXT" "$(cat "$ARTIFACT" 2>/dev/null)"
    assert_eq "1 ($FMT): and check-finalized answers for round 2" \
        "0" "$(check_finalized "$PLANS" "$SID" "$FMT" 2)"

    # The counter settles as a terminal: the round number moves to last-round.txt
    # so the orchestrator can name the terminal RAW without arithmetic (P4-2).
    assert_eq "1 ($FMT): the round counter is retired" "missing" "$(clf_file_state "$ROUNDF")"
    assert_eq "1 ($FMT): and the terminal round number is recorded" "2" "$(clf_read "$LASTF")"

    # The terminal round's raw output must still reach stdout, or the
    # orchestrator has nothing to persist as RAW_FILE.
    assert_contains "1 ($FMT): the terminal stdout still carries the codex block" \
        "<!-- begin-codex-output" "$R2_OUT"
    assert_eq "1 ($FMT): so round 1 and round 2 RAW files coexist under separate names" \
        "present present" "$(clf_file_state "$RAW1") $(clf_file_state "$RAW2")"
    assert_eq "1 ($FMT): and round 1's RAW was not overwritten by round 2" \
        "$RAW1_DIGEST" "$(clf_digest "$RAW1")"

    # P4-3: the summary the orchestrator shows is generated from the LIVE
    # ledger (exit 6 makes no cap snapshot) plus the terminal RAW.
    SUM_RC=0
    SUM_OUT="$(bash "$ROOT/bin/review-loop-summarize-concerns" --budget-remaining 0 \
        --ledger "$LEDGER" --raw "$RAW2" --label "$FMT" 2>/dev/null)" || SUM_RC=$?
    assert_eq "1 ($FMT): the concern summary renders from the live ledger" "0" "$SUM_RC"
    assert_contains "1 ($FMT): and names the unresolved HIGH concern" "HIGH" "$SUM_OUT"
done <<'FORMATS'
detail-plan|hu-detail
outline-plan|hu-outline
security-plan|hu-security
test-review|hu-testrev
FORMATS

# ---------------------------------------------------------------------------
# 2. The neighbouring terminal. A risk signal at the same ceiling is ESCALATE
#    (exit 2), and it must stay that way: exit 6 is the *no-signal* branch, so
#    if both collapsed onto one code the distinction the operator acts on is
#    gone (CPR-SC).
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-2: the same ceiling with a risk signal still escalates ---"

RS_FMT="detail-plan"
RS_SID="hu-risk"
RS_PLANS="$TMPDIR_BASE/plans-risk"
clf_plans "$RS_PLANS"

clf_run "$ROOT" "$RS_PLANS" "$RS_SID" "$RS_FMT" \
    --cap 2 --max-extensions 0 --extensions-used 0 --round 1
assert_eq "2: round 1 continues (precondition)" "1" "$CLF_RC"

clf_run "$ROOT" "$RS_PLANS" "$RS_SID" "$RS_FMT" \
    --cap 2 --max-extensions 0 --extensions-used 0 --round 2 \
    --risk-signal "hook-registration"
assert_eq "2: a risk signal at the ceiling escalates rather than reporting HIGH_UNRESOLVED" \
    "2" "$CLF_RC"
assert_ne "2: and is still not an approval" "0" "$CLF_RC"
assert_eq "2: with an artifact of its own" \
    "present" "$(clf_file_state "$(clf_artifact_path "$RS_PLANS" "$RS_SID" "$RS_FMT")")"

# ---------------------------------------------------------------------------
# 3. Budget available at the same ceiling is the third branch: AUTO_EXTEND
#    (exit 5). It exists so that "HIGH remains" alone cannot be read as a
#    terminal — the ceiling is what makes exit 6 terminal, not the severity.
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-3: HIGH at round 2 with budget left is not a terminal ---"

AE_SID="hu-extend"
AE_PLANS="$TMPDIR_BASE/plans-extend"
clf_plans "$AE_PLANS"

clf_run "$ROOT" "$AE_PLANS" "$AE_SID" detail-plan \
    --cap 2 --max-extensions 1 --extensions-used 0 --round 1
assert_eq "3: round 1 continues (precondition)" "1" "$CLF_RC"

clf_run "$ROOT" "$AE_PLANS" "$AE_SID" detail-plan \
    --cap 2 --max-extensions 1 --extensions-used 0 --round 2
assert_eq "3: an available extension yields AUTO_EXTEND, not HIGH_UNRESOLVED" "5" "$CLF_RC"
assert_eq "3: and the ledger is kept for the extended round" \
    "present" "$(clf_file_state "$(clf_ledger_path "$AE_PLANS" "$AE_SID" detail-plan)")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
