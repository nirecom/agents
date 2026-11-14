#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/verdict-sentinel.sh, bin/lib/codex-review-loop/review-wrapper-control.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh
# Tags: feature-2952, codex-review-loop, terminal-guard, exit9, terminal-ledger, scope:issue-specific, TL2
#
# #2952 (D6) handover: the REAL loop behind the REAL detail-plan wrapper reaches exit 6 on an
# open HIGH, and terminal line 3 names the ledger that loop actually wrote; the exit-9 guard
# then judges that ledger. tests/skills/feature-2952-exit9-ledger*.sh stub the loop instead.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/bin/feature-2937-review-loop/fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

case_begin "real-loop-exit6-hands-its-ledger-to-terminal-line-3" "bin/run-codex-review-loop"
sid=h6
seed_sid "$sid"
st seed "$sid"
C="$(ctl "$sid")"
LED="$C/detail-plan-concern-ledger.txt"
wrap make-detail-plan "$sid"
assert_eq "r1 continues on the open HIGH (precondition)" "1" "$W_RC"
wrap make-detail-plan "$sid"
assert_eq "r2 at the cap auto-extends (precondition)" "5" "$W_RC"
wrap make-detail-plan "$sid"
assert_eq "r3 with the extension spent ends on exit 6" "6" "$W_RC"
assert_contains "the ledger the loop used holds the open HIGH" "|HIGH|open|" "$(cat "$LED" 2>/dev/null)"
T1="$(sed -n '1p' "$C/detail-plan-terminal.txt" 2>/dev/null | tr -d '\r')"
T3="$(sed -n '3p' "$C/detail-plan-terminal.txt" 2>/dev/null | tr -d '\r')"
assert_eq "terminal line 1 is 6" "6" "$T1"
assert_ne "terminal line 3 is not empty" "" "$T3"
assert_eq "terminal line 3 is the ledger the loop used" "$(np "$LED")" "$(np "${T3:-<empty>}")"
printf 'edit\n' >> "$P/$sid-detail.md"
wrap make-detail-plan "$sid"
assert_eq "a changed input with that ledger's HIGH still open -> 9" "9" "$W_RC"
case_end

# to_exit6 <sid> — three real wrapper runs to an exit 6 terminal; sets C / LED.
to_exit6() {
    seed_sid "$1"
    st seed "$1"
    C="$(ctl "$1")"
    LED="$C/detail-plan-concern-ledger.txt"
    wrap make-detail-plan "$1"
    wrap make-detail-plan "$1"
    wrap make-detail-plan "$1"
}

case_begin "header-only-terminal-ledger-keeps-the-exit9-guard" "bin/lib/codex-review-loop/review-wrapper-control.sh"
sid=h6e
to_exit6 "$sid"
assert_eq "precondition: exit 6" "6" "$W_RC"
head -n 1 "$LED" > "$LED.tmp"
mv -f "$LED.tmp" "$LED"
assert_eq "the ledger is now header-only" "0" "$(grep -cE '^C[0-9]+\|' "$LED")"
printf 'edit\n' >> "$P/$sid-detail.md"
wrap make-detail-plan "$sid"
assert_eq "a header-only ledger does not release the guard -> 9" "9" "$W_RC"
assert_not_contains "no release message" "releasing the guard" "$W_ERR"
assert_eq "the terminal stays armed" "6" "$(sed -n '1p' "$C/detail-plan-terminal.txt" 2>/dev/null | tr -d '\r')"
case_end

case_begin "closed-highs-in-terminal-ledger-release-the-guard" "bin/lib/codex-review-loop/review-wrapper-control.sh"
sid=h6c
to_exit6 "$sid"
assert_eq "precondition: exit 6" "6" "$W_RC"
"$ROOT/bin/concern-ledger" reject --ledger "$LED" --plans-dir "$P" --session-id "$sid" \
    --format detail-plan --id C1 --reason "rejected by the user" >/dev/null 2>&1
assert_eq "precondition: C1 is no longer an open HIGH" "0" "$(grep -cF '|HIGH|open|' "$LED")"
assert_ne "the ledger still holds concern lines" "0" "$(grep -cE '^C[0-9]+\|' "$LED")"
printf 'edit\n' >> "$P/$sid-detail.md"
wrap make-detail-plan "$sid"
assert_ne "every HIGH closed -> not 9" "9" "$W_RC"
assert_ne "and not the unchanged-input 8" "8" "$W_RC"
assert_contains "the guard is released" "releasing the guard" "$W_ERR"
case_end

finish
