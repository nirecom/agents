#!/usr/bin/env bash
# tests/bin/feature-2434-review-loop-control-paths.sh
# Tests: skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, bin/run-codex-review-loop, skills/_shared/codex-review-loop/exit-codes.md, skills/_shared/codex-review-loop.md
# Tags: feature-2434, control-dir, codex-review-loop, escalation-table, TL2, scope:issue-specific, pwsh-not-required
#
# #2434 Step 5-9 / Step 10: the five stage wrappers keep their control files in
# $WORKFLOW_STATE_DIR/<sid>.control/ and leave only artifacts in PLANS_DIR;
# exit-codes.md owns the one format x exit-code escalation table.
set -uo pipefail

# TL2 — the real wrappers and loop, reviewers stubbed (shared fixture below).
# TL3 gap: the real codex CLI wording. Sibling suites of the same fixture:
# feature-2434-review-loop-control-halt.sh, -legacy-state.sh, -risk-signal.sh.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2434-review-loop/fixture.sh
. "$AGENTS_DIR/tests/bin/feature-2434-review-loop/fixture.sh"

for f in bin/workflow-control-dir hooks/workflow-state/state-io/control-dir.js; do
    [ -f "$AGENTS_DIR/$f" ] || fail "implementation missing: $f"
done

case_begin "all-five-formats-write-control-dir-only" "bin/run-codex-review-loop"
while IFS='|' read -r NAME SKILL FMT LFMT PROD; do
    SID="cp-$NAME"
    seed_sid "$SID"
    wrap "$SKILL" "$SID"
    C="$(ctl "$SID")"
    assert_eq "$NAME: round 1 with an open HIGH continues (rc 1)" "1" "$W_RC"
    assert_eq "$NAME: <sid>.control/ exists" "dir" "$(state "$C")"
    assert_eq "$NAME: round counter in the control dir" "present" "$(state "$C/$FMT-round-number.txt")"
    assert_eq "$NAME: concern ledger in the control dir" "present" "$(state "$C/$LFMT-concern-ledger.txt")"
    assert_eq "$NAME: round-1 delta in the control dir" "present" "$(state "$C/$LFMT-round-1-delta-$PROD.txt")"
    assert_eq "$NAME: context-built marker in the control dir" "present" "$(state "$C/codex-context.$FMT.built")"
    assert_eq "$NAME: PLANS_DIR keeps artifacts only" "" "$(plans_leftovers "$SID")"
done <<EOF
$FORMATS
EOF
assert_eq "test-review: changed-files scope list in the control dir" "present" \
    "$(state "$(ctl cp-test-review)/changed-files.txt")"
assert_eq "no reviewer log at the PLANS_DIR root" "absent" "$(state "$P/plan.jsonl")"
TEMPS=""
for f in "$P"/.sg-* "$P"/.prev-*; do [ -e "$f" ] && TEMPS="$TEMPS ${f##*/}"; done
assert_eq "no .sg-/.prev- temp file in PLANS_DIR" "" "${TEMPS# }"
case_end

case_begin "escalation-by-format-table" "skills/_shared/codex-review-loop/exit-codes.md"
EC="$AGENTS_DIR/skills/_shared/codex-review-loop/exit-codes.md"
CRL="$AGENTS_DIR/skills/_shared/codex-review-loop.md"
row() { grep -E "^\| *$1( |$)" "$EC" | head -n 1; }
assert_eq "exit-codes.md has an 'Escalation by format' heading" "1" \
    "$(grep -cE '^#+ .*Escalation by format' "$EC")"
for X in 2 6 8 9 4; do
    assert_ne "the table has an exit $X row" "" "$(row "$X")"
done
assert_not_contains "exit 2 (outline/detail ESCALATE) never points at the accept CLI" \
    "accept-exit6-residual" "$(row 2)"
assert_contains "exit 6 names bin/accept-exit6-residual for the three accept formats" \
    "accept-exit6-residual" "$(row 6)"
assert_contains "the Outcomes exit 9 line names the accept CLI, not a marker file" \
    "accept-exit6-residual" "$(grep -m1 'Public exit 9' "$EC")"
assert_not_contains "no control path is spelled under PLANS_DIR" \
    "<PLANS_DIR>/<session-id>-<format>-" "$(cat "$EC")"
assert_eq "exit-codes.md stays within the 100-line prompt WARN" "yes" \
    "$([ "$(wc -l < "$EC")" -le 100 ] && printf yes || printf no)"
assert_contains "codex-review-loop.md defers to the table" "Escalation by format" "$(cat "$CRL")"
assert_not_contains "codex-review-loop.md spells no PLANS_DIR round counter" \
    "<PLANS_DIR>/<session-id>-<format>-round-number.txt" "$(cat "$CRL")"
DUPS=""
for f in "$AGENTS_DIR"/skills/*/SKILL.md; do
    grep -qE '^#+ .*Escalation by format' "$f" && DUPS="$DUPS ${f#"$AGENTS_DIR/"}"
done
assert_eq "no SKILL.md duplicates the table" "" "${DUPS# }"
case_end

case_begin "terminal-guard-all-five-formats" "bin/run-codex-review-loop"
# C9: every format honours a terminal already written to its control dir (exit 8).
[ -f "$AGENTS_DIR/hooks/workflow-state/state-io/control-dir.js" ] || \
    fail "implementation missing: hooks/workflow-state/state-io/control-dir.js"
while IFS='|' read -r NAME SKILL FMT LFMT PROD; do
    SID="tg-$NAME"
    seed_sid "$SID"
    mkdir -p "$(ctl "$SID")"
    printf '2\n\n' > "$(ctl "$SID")/$FMT-terminal.txt"
    wrap "$SKILL" "$SID"
    assert_eq "$NAME: re-run after terminal in control dir -> exit 8" "8" "$W_RC"
    assert_eq "$NAME: terminal still present in control dir" "present" \
        "$(state "$(ctl "$SID")/$FMT-terminal.txt")"
done <<EOF
$FORMATS
EOF
case_end

case_begin "legacy-terminal-outline-detail" "skills/make-outline-plan/scripts/run-codex-review-loop.sh"
# C9: outline-plan and detail-plan legacy terminals (PLANS_DIR name) are migrated
# and honoured (exit 8); the review-only counterpart is legacy-terminal-keeps-the-guard in
# feature-2434-review-loop-control-halt.sh.
[ -f "$AGENTS_DIR/hooks/workflow-state/state-io/control-dir.js" ] || \
    fail "implementation missing: hooks/workflow-state/state-io/control-dir.js"
for FMT_SKILL in "outline-plan:make-outline-plan" "detail-plan:make-detail-plan"; do
    FMT="${FMT_SKILL%%:*}"; SKILL="${FMT_SKILL#*:}"
    SID="lt2-$FMT"
    seed_sid "$SID"
    printf '2\n\n' > "$P/$SID-$FMT-terminal.txt"
    export CLF_ARGV_LOG="$TMP/lt2-argv-$FMT.txt"
    : > "$CLF_ARGV_LOG"
    wrap "$SKILL" "$SID"
    assert_eq "$FMT: legacy terminal -> exit 8" "8" "$W_RC"
    assert_eq "$FMT: no review round ran" "" "$(tr -d '\r\n' < "$CLF_ARGV_LOG")"
    assert_eq "$FMT: legacy terminal moved out of PLANS_DIR" "absent" \
        "$(state "$P/$SID-$FMT-terminal.txt")"
    assert_eq "$FMT: terminal now in the control dir" "present" \
        "$(state "$(ctl "$SID")/$FMT-terminal.txt")"
    unset CLF_ARGV_LOG
done
case_end

case_begin "ask-user-question-instructions" "skills/_shared/codex-review-loop.md"
# C9: the shared instructions must explicitly require AskUserQuestion for exit 8
# (re-invoked after terminal) and for unresolved concerns after the 2+1 budget.
# Grep for actual AskUserQuestion text, not just table headings.
CRL="$AGENTS_DIR/skills/_shared/codex-review-loop.md"
EC="$AGENTS_DIR/skills/_shared/codex-review-loop/exit-codes.md"
AUQ_FOUND=0
grep -Fq 'AskUserQuestion' "$CRL" 2>/dev/null && AUQ_FOUND=1
grep -Fq 'AskUserQuestion' "$EC"  2>/dev/null && AUQ_FOUND=1
if [ "$AUQ_FOUND" = "1" ]; then
    pass "AskUserQuestion appears in shared review-loop instructions"
else
    fail "implementation missing: AskUserQuestion not yet in codex-review-loop.md or exit-codes.md"
fi
# Exit 8: context around exit 8 must require AskUserQuestion.
AUQ_E8=0
grep -A5 '| 8 ' "$EC" 2>/dev/null | grep -Fq 'AskUserQuestion' && AUQ_E8=1
grep -A5 'exit 8' "$CRL" 2>/dev/null | grep -Fq 'AskUserQuestion' && AUQ_E8=1
if [ "$AUQ_E8" = "1" ]; then
    pass "AskUserQuestion: exit-8 row/context names AskUserQuestion"
else
    fail "implementation missing: exit 8 / reinvoke-after-terminal does not yet require AskUserQuestion"
fi
# Exit 2/6 at cap: unresolved concerns after 2+1 budget must require AskUserQuestion.
AUQ_BUDGET=0
grep -A5 '| 2 ' "$EC" 2>/dev/null | grep -Fq 'AskUserQuestion' && AUQ_BUDGET=1
grep -A5 '| 6 ' "$EC" 2>/dev/null | grep -Fq 'AskUserQuestion' && AUQ_BUDGET=1
if [ "$AUQ_BUDGET" = "1" ]; then
    pass "AskUserQuestion: unresolved-concerns-after-budget (exit 2/6) names AskUserQuestion"
else
    fail "implementation missing: exit 2/6 at cap does not yet require AskUserQuestion"
fi
case_end

finish
