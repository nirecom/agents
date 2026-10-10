#!/usr/bin/env bash
# tests/bin/feature-2434-review-loop-control-halt.sh
# Tests: skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, bin/workflow-control-dir
# Tags: feature-2434, control-dir, codex-review-loop, fail-closed, legacy-migration, terminal-guard, TL2, scope:issue-specific, pwsh-not-required
#
# #2434 Step 5-2 (C2): every stage wrapper resolves its control dir once with
# bin/workflow-control-dir --for-write; when that fails the review loop halts
# with the public exit 4 and never falls back to writing into PLANS_DIR.
set -uo pipefail

# TL2 — shared fixture: tests/bin/feature-2434-review-loop/fixture.sh.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2434-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2434-review-loop/fixture.sh"

[ -f "$SCRIPT_CHECKOUT_ROOT/bin/workflow-control-dir" ] || fail "implementation missing: bin/workflow-control-dir"

case_begin "control-dir-failure-halts-with-exit-4" "bin/workflow-control-dir"
# A regular file squatting <sid>.control makes the resolver fail.
while IFS='|' read -r NAME SKILL FMT LFMT PROD; do
    SID="cf-$NAME"
    seed_sid "$SID"
    printf 'squatter\n' > "$(ctl "$SID")"
    wrap "$SKILL" "$SID"
    assert_eq "$NAME: unusable control dir -> exit 4 (HALT)" "4" "$W_RC"
    assert_eq "$NAME: nothing written to PLANS_DIR instead" "" "$(plans_leftovers "$SID")"
    assert_eq "$NAME: the squatting file is left untouched" "squatter" "$(clf_read "$(ctl "$SID")")"
done <<EOF
$FORMATS
EOF
case_end

case_begin "legacy-terminal-keeps-the-guard" "skills/review-plan-security/scripts/run-codex-review-loop.sh"
# Step 5-9: a terminal under its pre-#2434 PLANS name (unreadable fingerprint)
# still blocks the unchanged re-run: it is moved into <sid>.control/ first and
# then honoured -> exit 8, so the upgrade opens no window around the guard.
[ -f "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io/control-dir.js" ] || \
    fail "implementation missing: hooks/workflow-state/state-io/control-dir.js"
for ROW in review-plan-security:security-plan review-code-security:security-code review-tests:test-review; do
    SKILL="${ROW%%:*}"; FMT="${ROW#*:}"
    SID="lt-$FMT"
    seed_sid "$SID"
    printf '2\n\n' > "$P/$SID-$FMT-terminal.txt"
    export CLF_ARGV_LOG="$TMP/lt-argv-$FMT.txt"
    : > "$CLF_ARGV_LOG"
    wrap "$SKILL" "$SID"
    assert_eq "$FMT: legacy terminal -> exit 8" "8" "$W_RC"
    assert_eq "$FMT: no review round ran" "" "$(tr -d '\r\n' < "$CLF_ARGV_LOG")"
    assert_eq "$FMT: legacy terminal moved out of PLANS_DIR" "absent" "$(state "$P/$SID-$FMT-terminal.txt")"
    assert_eq "$FMT: terminal now in the control dir" "present" "$(state "$(ctl "$SID")/$FMT-terminal.txt")"
    unset CLF_ARGV_LOG
done
case_end

finish
