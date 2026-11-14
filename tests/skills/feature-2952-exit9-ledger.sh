#!/usr/bin/env bash
# Tests: bin/lib/codex-review-loop/review-wrapper-control.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: feature-2952, codex-review-loop, terminal-guard, exit9, table-driven, accept-marker, scope:issue-specific, TL2, dup-group-keep:time-hard-limit
#
# #2952 (D6) T3-1 / T3-2: after an exit-6 terminal, a changed input passes only
# when the ledger the loop used (terminal line 3) has no open HIGH left. T3-5: the
# exit-9 guidance prints an accept command that runs as printed and binds its marker
# to this terminal. Siblings (split for the test-time budget): -{source,unchanged,expiry}.sh.
# TL3 gap: a real codex round reaching exit 6 is covered by tests/bin/feature-2937-*.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/skills/feature-2952-exit9-ledger/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/skills/feature-2952-exit9-ledger/fixture.sh"

case_begin "t3-1-2-rejected-highs-clear-open-high-blocks" "bin/lib/codex-review-loop/review-wrapper-control.sh"
while IFS='|' read -r F S LF M; do
    sid="t3a-$F"; seed_sid "$sid"; L="$(ctl "$sid")/$LF-concern-ledger.txt"
    ledger_open_high "$L" "$LF" "$sid" C1 C2
    wrap "$S" "$sid" 6 "$L"
    assert_eq "$F: the stub exit 6 passes through" "6" "$W_RC"
    assert_eq "$F: terminal line 1 is 6" "6" "$(term_line "$sid" "$F" 1)"
    assert_eq "$F: terminal line 3 is the ledger the loop used" "$L" "$(term_line "$sid" "$F" 3)"
    bump "$F" "$sid"
    wrap "$S" "$sid" 1
    assert_eq "$F: two open HIGH, input changed -> 9 (T3-2)" "9" "$W_RC"
    reject "$L" "$sid" "$LF" C1
    wrap "$S" "$sid" 1
    assert_eq "$F: one HIGH still open -> still 9 (T3-2)" "9" "$W_RC"
    reject "$L" "$sid" "$LF" C2
    wrap "$S" "$sid" 1
    assert_eq "$F: every residual HIGH rejected -> the guard clears (T3-1)" "1" "$W_RC"
    assert_eq "$F: and the terminal file is gone" "missing" "$(clf_file_state "$(ctl "$sid")/$F-terminal.txt")"
done <<EOF
$FORMATS
EOF
case_end

case_begin "t3-5-guidance-command-runs-as-printed" "bin/lib/codex-review-loop/review-wrapper-control.sh"
while IFS='|' read -r F S LF M; do
    sid="t3f-$F"; seed_sid "$sid"; L="$(ctl "$sid")/$LF-concern-ledger.txt"; C="$(ctl "$sid")"
    ledger_open_high "$L" "$LF" "$sid" C1
    wrap "$S" "$sid" 6 "$L"
    bump "$F" "$sid"
    wrap "$S" "$sid" 1
    assert_eq "$F: open HIGH after the change -> 9" "9" "$W_RC"
    CMD="$(printf '%s\n' "$W_ERR" | sed -n 's/.*\(node ".*accept-exit6-residual" --session [^ ]* --format [^ ]* --reason "<text>"\).*/\1/p' | head -n 1)"
    assert_ne "$F: the 9 guidance carries a runnable node command" "" "$CMD"
    assert_contains "$F: the command names this session and format" "--session $sid --format $F" "$CMD"
    CMD="${CMD//<text>/the user accepted the residual}"
    E_RC=0
    if [ -n "$CMD" ]; then eval "$CMD" >/dev/null 2>&1 || E_RC=$?; else E_RC=missing; fi
    assert_eq "$F: the printed command exits 0" "0" "$E_RC"
    assert_eq "$F: the marker exists" "present" "$(clf_file_state "$C/$M")"
    assert_eq "$F: marker terminal_fp is terminal line 2" "$(term_line "$sid" "$F" 2)" "$(marker_kv "$C/$M" terminal_fp)"
    assert_eq "$F: marker terminal_ledger is terminal line 3" "$L" "$(marker_kv "$C/$M" terminal_ledger)"
    wrap "$S" "$sid" 1
    assert_eq "$F: the re-run passes after the accept" "1" "$W_RC"
    assert_eq "$F: clearing the guard drops the marker" "missing" "$(clf_file_state "$C/$M")"
done <<EOF
$FORMATS
EOF
case_end

finish
