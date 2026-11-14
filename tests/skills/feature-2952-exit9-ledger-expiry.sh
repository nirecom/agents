#!/usr/bin/env bash
# Tests: bin/lib/codex-review-loop/review-wrapper-control.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: feature-2952, codex-review-loop, terminal-guard, exit9, accept-marker, table-driven, scope:issue-specific, TL2, dup-group-keep:time-hard-limit
#
# #2952 (D6) T3-6: an accept marker covers one terminal only — a new exit 6,
# a rewritten terminal fingerprint or an old-form marker all fall back to 9,
# and the accept CLI refuses (exit 2) when there is no exit-6 terminal.
# TL3 gap: a real codex round reaching exit 6 is covered by tests/bin/feature-2937-*.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/skills/feature-2952-exit9-ledger/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/skills/feature-2952-exit9-ledger/fixture.sh"

case_begin "t3-6-marker-expiry" "bin/lib/codex-review-loop/review-wrapper-control.sh"
while IFS='|' read -r F S LF M; do
    sid="t3g-$F"; seed_sid "$sid"; L="$(ctl "$sid")/$LF-concern-ledger.txt"; C="$(ctl "$sid")"
    ledger_open_high "$L" "$LF" "$sid" C1
    wrap "$S" "$sid" 6 "$L"
    accept "$sid" "$F"
    assert_eq "$F: the first accept is recorded" "0" "$A_RC"
    bump "$F" "$sid"
    wrap "$S" "$sid" 6 "$L"
    assert_eq "$F: the next cycle ends on exit 6 again" "6" "$W_RC"
    assert_eq "$F: the past accept does not survive into the new terminal" "missing" "$(clf_file_state "$C/$M")"
    bump "$F" "$sid"
    wrap "$S" "$sid" 1
    assert_eq "$F: the new exit 6 is not covered by the past accept -> 9" "9" "$W_RC"
    accept "$sid" "$F"
    assert_eq "$F: the second accept is recorded" "0" "$A_RC"
    assert_eq "$F: its marker terminal_fp is the new terminal's line 2" "$(term_line "$sid" "$F" 2)" "$(marker_kv "$C/$M" terminal_fp)"
    assert_ne "$F: the new terminal has a fingerprint (precondition)" "" "$(term_line "$sid" "$F" 2)"
    assert_eq "$F: its marker terminal_ledger is the new terminal's line 3" "$L" "$(marker_kv "$C/$M" terminal_ledger)"
    printf '6\nrewritten-fp\n%s\n' "$L" > "$C/$F-terminal.txt"
    wrap "$S" "$sid" 1
    assert_eq "$F: marker kept but terminal line 2 rewritten -> 9" "9" "$W_RC"
    printf 'accepted_at=2026-01-01T00:00:00Z\nreason=old form\n' > "$C/$M"
    wrap "$S" "$sid" 1
    assert_eq "$F: an old-form marker without terminal_fp -> 9" "9" "$W_RC"
    rm -f "$C/$F-terminal.txt"
    accept "$sid" "$F"
    assert_eq "$F: accept with no terminal file -> exit 2" "2" "$A_RC"
    printf '2\nfp\n%s\n' "$L" > "$C/$F-terminal.txt"
    accept "$sid" "$F"
    assert_eq "$F: accept when terminal line 1 is not 6 -> exit 2" "2" "$A_RC"
done <<EOF
$FORMATS
EOF
case_end

finish
