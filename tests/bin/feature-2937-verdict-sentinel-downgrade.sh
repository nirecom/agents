#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/verdict-dispatch.sh, bin/lib/codex-review-loop/prestaged-pass.sh, bin/lib/codex-review-loop/verdict-sentinel.sh
# Tags: feature-2937, codex-review-loop, verdict-sentinel, medium-downgrade, scope:issue-specific, TL2
#
# #2937 (D7) T1-3: an open MEDIUM at the round cap still approves (exit 0), but
# the approval is marked with REVIEW_LOOP_NOTE on both the reviewer pass and the
# prestaged pass; exits 3 and 4 carry no verdict and so no sentinel.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/lib/codex-loop-fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

NOTE='REVIEW_LOOP_NOTE: downgraded-medium=1 (open MEDIUM at the round cap; information only, not a WARNINGS gap)'

case_begin "t1-3-reviewer-pass-medium-downgrade-is-marked" "bin/lib/codex-review-loop/verdict-dispatch.sh"
sid="t1m"; F=detail-plan
reply "$sid" "$F" 1 "NEEDS_REVISION" "1. [MEDIUM] the error message omits the path"
reply "$sid" "$F" 2 "NEEDS_REVISION" "C1: still open — the error message omits the path"
loop "$sid" "$F" --cap 2 --max-extensions 1 --extensions-used 0
assert_eq "round 1 with a MEDIUM continues" "1" "$L_RC"
assert_not_contains "a continuing round carries no downgrade note" "REVIEW_LOOP_NOTE:" "$L_OUT"
loop "$sid" "$F" --cap 2 --max-extensions 1 --extensions-used 0
assert_eq "MEDIUM only at the cap approves (exit 0)" "0" "$L_RC"
assert_eq "the sentinel names APPROVED" "REVIEW_LOOP_VERDICT: APPROVED (exit 0)" "$(last_line "$L_OUT")"
assert_contains "the downgrade note is printed" "$NOTE" "$L_OUT"
note_n="$(printf '%s\n' "$L_OUT" | grep -nF 'REVIEW_LOOP_NOTE:' | head -n 1 | cut -d: -f1)"
sent_n="$(printf '%s\n' "$L_OUT" | grep -nF 'REVIEW_LOOP_VERDICT:' | tail -n 1 | cut -d: -f1)"
assert_eq "the note precedes the sentinel" "yes" "$([ -n "$note_n" ] && [ -n "$sent_n" ] && [ "$note_n" -lt "$sent_n" ] && echo yes || echo no)"
case_end

case_begin "t1-3-prestaged-pass-medium-downgrade-is-marked" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="t1p"
REP="$FX_TMP/scanner-medium.txt"
delta "$REP" MEDIUM "[MEDIUM] C1 | reviewed.txt#5 | correctness | the error message omits the path"
prestaged "$sid" "$REP" --cap 2 --max-extensions 1 --extensions-used 0
assert_eq "prestaged round 1 with a MEDIUM continues" "1" "$L_RC"
assert_eq "its sentinel is NEEDS_REVISION" "REVIEW_LOOP_VERDICT: NEEDS_REVISION (exit 1)" "$(last_line "$L_OUT")"
prestaged "$sid" "$REP" --cap 2 --max-extensions 1 --extensions-used 0
assert_eq "prestaged MEDIUM only at the cap approves (exit 0)" "0" "$L_RC"
assert_eq "the sentinel names APPROVED" "REVIEW_LOOP_VERDICT: APPROVED (exit 0)" "$(last_line "$L_OUT")"
assert_contains "the downgrade note is printed on the prestaged pass too" "$NOTE" "$L_OUT"
case_end

case_begin "t1-3-exit3-and-exit4-carry-no-sentinel" "bin/run-codex-review-loop"
export FX_RV=1
loop "t1u" detail-plan --cap 2 --max-extensions 1 --extensions-used 0
unset FX_RV
assert_eq "a failing reviewer is exit 3" "3" "$L_RC"
assert_not_contains "exit 3 prints no sentinel" "REVIEW_LOOP_VERDICT:" "$L_OUT"
loop "t1h" detail-plan --cap 2 --max-extensions 1 --extensions-used 0 --round 5
assert_eq "a --round that does not follow the counter is exit 4" "4" "$L_RC"
assert_not_contains "exit 4 prints no sentinel" "REVIEW_LOOP_VERDICT:" "$L_OUT"
case_end

HIGH_REP="$FX_TMP/scanner-high.txt"
delta "$HIGH_REP" HIGH "[HIGH] C1 | reviewed.txt#5 | correctness | unchecked input reaches the shell"

case_begin "prestaged-advance-finalize-failure-records-and-keeps-the-round" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="pa7"; F=security-code
prestaged "$sid" "$HIGH_REP" --cap 2 --max-extensions 0 --extensions-used 0
assert_eq "precondition: prestaged ADVANCE round 1 with a HIGH continues" "1" "$L_RC"
assert_eq "round 1 takes one record row" "1" "$(rows "$sid" "$F")"
# A directory where finalize writes its artifact and diagnostic makes the write fail;
# the continuing round 1 already wrote the artifact as a file, so replace it.
ART="$(ctl "$sid")/review-security-shared-unresolved-concerns.json"
DIAG="$P/$sid-review-security-shared-finalize-diagnostic.txt"
rm -f "$ART" "$DIAG"
mkdir -p "$ART" "$DIAG"
prestaged "$sid" "$HIGH_REP" --cap 2 --max-extensions 0 --extensions-used 0
assert_eq "reduce succeeds, finalize fails: exit 7" "7" "$L_RC"
assert_eq "the exit 7 round adds exactly one row" "2" "$(rows "$sid" "$F")"
assert_eq "the row carries exit 7" "7" "$(row "$sid" "$F" -1 exit)"
assert_eq "the row names counter round 2" "2" "$(row "$sid" "$F" -1 counter_round)"
assert_eq "the row source is cc-fallback" "cc-fallback" "$(row "$sid" "$F" -1 source)"
assert_eq "the round is consumed, not rolled back (last round 2)" "2" "$(cat "$(clf_last_round_path "$P" "$sid" "$F")" 2>/dev/null | tr -d '\r\n')"
assert_eq "the counter is not rewritten to round 1" "absent" "$([ -f "$(clf_round_path "$P" "$sid" "$F")" ] && echo present || echo absent)"
case_end

case_begin "prestaged-join-records-no-row" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="pj"; F=security-code
prestaged "$sid" "$HIGH_REP" --cap 2 --max-extensions 0 --extensions-used 0 --round 1
assert_eq "precondition: prestaged JOIN round 1 with a HIGH continues" "1" "$L_RC"
assert_eq "a JOIN round takes no record row" "0" "$(rows "$sid" "$F")"
assert_eq "and allocates no round counter" "absent" "$([ -f "$(clf_round_path "$P" "$sid" "$F")" ] && echo present || echo absent)"
case_end

case_begin "prestaged-reduce-failure-is-exit4-without-row-or-commit" "bin/lib/codex-review-loop/prestaged-pass.sh"
sid="pr4"; F=security-code
CLB="$ROOT/bin/concern-ledger"
mv "$CLB" "$CLB.real"
printf '#!/usr/bin/env bash\n[ "${1:-}" = reduce ] && exit 1\nexec bash "%s.real" "$@"\n' "$CLB" > "$CLB"
chmod +x "$CLB"
prestaged "$sid" "$HIGH_REP" --cap 2 --max-extensions 0 --extensions-used 0
mv -f "$CLB.real" "$CLB"
assert_eq "a failed reduce is exit 4" "4" "$L_RC"
assert_contains "the reason names the unfolded round" "could not be folded into the ledger" "$L_ERR"
assert_eq "exit 4 writes no row" "0" "$(rows "$sid" "$F")"
assert_eq "the fresh counter is rolled back" "absent" "$([ -f "$(clf_round_path "$P" "$sid" "$F")" ] && echo present || echo absent)"
assert_eq "and no last round is recorded" "absent" "$([ -f "$(clf_last_round_path "$P" "$sid" "$F")" ] && echo present || echo absent)"
case_end

finish
