#!/usr/bin/env bash
# Tests: bin/lib/codex-review-loop/review-wrapper-control.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: feature-2952, codex-review-loop, terminal-guard, exit9, table-driven, scope:issue-specific, TL2, dup-group-keep:time-hard-limit
#
# #2952 (D6) T3-2 / T3-3: the guard judges the ledger named on terminal line 3 —
# the one the loop actually used, an override included — and fails closed (9)
# when that line or that ledger is missing.
# TL3 gap: a real codex round reaching exit 6 is covered by tests/bin/feature-2937-*.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/skills/feature-2952-exit9-ledger/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/skills/feature-2952-exit9-ledger/fixture.sh"

case_begin "t3-2-missing-ledger-or-line3-blocks" "bin/lib/codex-review-loop/review-wrapper-control.sh"
while IFS='|' read -r F S LF M; do
    sid="t3b-$F"; seed_sid "$sid"
    wrap "$S" "$sid" 6 "$(ctl "$sid")/no-such-ledger.txt"
    bump "$F" "$sid"
    wrap "$S" "$sid" 1
    assert_eq "$F: line 3 names a ledger that does not exist -> 9" "9" "$W_RC"
    printf '6\nold-fingerprint\n' > "$(ctl "$sid")/$F-terminal.txt"
    wrap "$S" "$sid" 1
    assert_eq "$F: a two-line terminal (no ledger line) -> 9" "9" "$W_RC"
done <<EOF
$FORMATS
EOF
case_end

case_begin "t3-3-ledger-override-is-the-one-judged" "bin/lib/codex-review-loop/review-wrapper-control.sh"
while IFS='|' read -r F S LF M; do
    sid="t3c-$F"; seed_sid "$sid"
    D="$(ctl "$sid")/$LF-concern-ledger.txt"; O="$T3_TMP/override-$F.txt"
    ledger_open_high "$D" "$LF" "$sid" C1
    ledger_open_high "$O" "$LF" "$sid" C1
    wrap "$S" "$sid" 6 "$O"
    assert_eq "$F: terminal line 3 is the override ledger" "$O" "$(term_line "$sid" "$F" 3)"
    reject "$O" "$sid" "$LF" C1
    bump "$F" "$sid"
    wrap "$S" "$sid" 1
    assert_eq "$F: override HIGH rejected, default ledger still open -> not 9" "1" "$W_RC"
done <<EOF
$FORMATS
EOF
case_end

finish
