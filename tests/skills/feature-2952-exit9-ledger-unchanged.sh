#!/usr/bin/env bash
# Tests: bin/lib/codex-review-loop/review-wrapper-control.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: feature-2952, codex-review-loop, terminal-guard, exit9, accept-marker, table-driven, scope:issue-specific, TL2, dup-group-keep:time-hard-limit
#
# #2952 (D6) T3-4 / T3-7: an unchanged input stays 8 whatever the ledger says,
# plan exit 2 never arms the guard, and the accept CLI replaces a stale marker
# but leaves a matching one untouched (idempotent).
# TL3 gap: a real codex round reaching exit 6 is covered by tests/bin/feature-2937-*.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/skills/feature-2952-exit9-ledger/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/skills/feature-2952-exit9-ledger/fixture.sh"

case_begin "t3-4-unchanged-stays-8-and-plan-exit2-unarmed" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
while IFS='|' read -r F S LF M; do
    sid="t3d-$F"; seed_sid "$sid"; L="$(ctl "$sid")/$LF-concern-ledger.txt"
    ledger_open_high "$L" "$LF" "$sid" C1
    wrap "$S" "$sid" 6 "$L"
    reject "$L" "$sid" "$LF" C1
    wrap "$S" "$sid" 1
    assert_eq "$F: input unchanged after exit 6 -> 8 even with no open HIGH" "8" "$W_RC"
done <<EOF
$FORMATS
EOF
for F in outline-plan detail-plan; do
    sid="t3e-$F"; seed_sid "$sid"
    wrap "make-$F" "$sid" 2
    assert_eq "$F: exit 2 passes through" "2" "$W_RC"
    assert_eq "$F: exit 2 does not arm the guard" "missing" "$(clf_file_state "$(ctl "$sid")/$F-terminal.txt")"
done
case_end

case_begin "t3-7-marker-replacement-and-idempotency" "bin/lib/codex-review-loop/review-wrapper-control.sh"
while IFS='|' read -r F S LF M; do
    sid="t3h-$F"; seed_sid "$sid"; L="$(ctl "$sid")/$LF-concern-ledger.txt"; C="$(ctl "$sid")"
    ledger_open_high "$L" "$LF" "$sid" C1
    wrap "$S" "$sid" 6 "$L"
    printf 'accepted_at=2026-01-01T00:00:00Z\nreason=old form\n' > "$C/$M"
    accept "$sid" "$F"
    assert_eq "$F: replacing an old-form marker exits 0" "0" "$A_RC"
    assert_contains "$F: and says so" "replaced stale accept marker" "$A_OUT"
    assert_eq "$F: the marker now holds this terminal's fp" "$(term_line "$sid" "$F" 2)" "$(marker_kv "$C/$M" terminal_fp)"
    printf 'accepted_at=x\nreason=y\nterminal_fp=other\nterminal_ledger=%s\n' "$L" > "$C/$M"
    accept "$sid" "$F"
    assert_contains "$F: a marker of another terminal is replaced too" "replaced stale accept marker" "$A_OUT"
    BEFORE="$(clf_digest "$C/$M")"
    accept "$sid" "$F"
    assert_eq "$F: the same accept again exits 0" "0" "$A_RC"
    assert_contains "$F: and reports already accepted" "already accepted" "$A_OUT"
    assert_eq "$F: without touching the marker" "$BEFORE" "$(clf_digest "$C/$M")"
    bump "$F" "$sid"
    wrap "$S" "$sid" 1
    assert_eq "$F: the re-run passes on the replaced marker" "1" "$W_RC"
done <<EOF
$FORMATS
EOF
case_end

finish
