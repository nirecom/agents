#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/verdict-sentinel.sh, bin/lib/codex-review-loop/ledger-verdict.sh, skills/review-tests/SKILL.md, skills/review-plan-security/SKILL.md, skills/_shared/codex-review-loop.md
# Tags: feature-2937, codex-review-loop, verdict-sentinel, raw-round-number, table-driven, scope:issue-specific, TL2
#
# #2937 (D7) T1 / T2: every verdict-bearing exit ends stdout with
# "REVIEW_LOOP_VERDICT: <NAME> (exit <rc>)", a finalize failure keeps its reason
# before that line, and the continuation exits leave the round in round-number.txt.
# TL3 gap: a real codex CLI round is not run; the reviewer is the stub of tests/lib/codex-loop-fixture.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

sentinel() { printf 'REVIEW_LOOP_VERDICT: %s (exit %s)' "$1" "$2"; }

case_begin "t1-1-t2-1-sentinel-per-exit-and-round-files" "bin/run-codex-review-loop"
sid="t1a"; F=detail-plan
R1="$(clf_round_path "$P" "$sid" "$F")"
LR="$(clf_last_round_path "$P" "$sid" "$F")"
for spec in "1 1 NEEDS_REVISION 0" "2 1 NEEDS_REVISION 0" "3 5 AUTO_EXTEND 0" "4 6 HIGH_UNRESOLVED 1"; do
    read -r rnd want name ext <<<"$spec"
    loop "$sid" "$F" --cap 3 --max-extensions 1 --extensions-used "$ext"
    assert_eq "round $rnd: exit $want" "$want" "$L_RC"
    assert_eq "round $rnd: the last stdout line is the sentinel" "$(sentinel "$name" "$want")" "$(last_line "$L_OUT")"
    assert_eq "round $rnd: exactly one sentinel line" "1" "$(count_lines 'REVIEW_LOOP_VERDICT:' "$L_OUT")"
    if [ "$want" != 6 ]; then
        assert_eq "round $rnd: round-number.txt holds this run's round (T2-1)" "$rnd" "$(clf_read "$R1")"
    else
        assert_eq "round $rnd: the terminal records its round in last-round.txt (T2-1)" "$rnd" "$(clf_read "$LR")"
    fi
done

sid="t1b"
reply "$sid" "$F" 1 "APPROVED"
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0
assert_eq "approved: exit 0" "0" "$L_RC"
assert_eq "approved: the sentinel names APPROVED" "$(sentinel APPROVED 0)" "$(last_line "$L_OUT")"

sid="t1c"
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0 --risk-signal hook-registration
assert_eq "escalate: exit 2" "2" "$L_RC"
assert_eq "escalate: the sentinel names ESCALATE" "$(sentinel ESCALATE 2)" "$(last_line "$L_OUT")"
case_end

case_begin "t1-2-needs-revision-sentinel-matches-exit" "bin/run-codex-review-loop"
for F in outline-plan security-plan test-review; do
    sid="t1n-$F"
    loop "$sid" "$F" --cap 2 --max-extensions 1 --extensions-used 0
    assert_eq "$F: round 1 is exit 1" "1" "$L_RC"
    assert_eq "$F: and its sentinel is NEEDS_REVISION (exit 1)" "$(sentinel NEEDS_REVISION 1)" "$(last_line "$L_OUT")"
done
case_end

case_begin "t1-4-finalize-failure-reason-before-sentinel" "bin/lib/codex-review-loop/ledger-verdict.sh"
sid="t1d"; F=detail-plan
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0
assert_eq "precondition: round 1 continues" "1" "$L_RC"
# A directory where finalize writes its artifact and diagnostic makes the write fail.
mkdir -p "$(clf_artifact_path "$P" "$sid" "$F")" "$P/$sid-$F-finalize-diagnostic.txt"
loop "$sid" "$F" --cap 2 --max-extensions 0 --extensions-used 0
assert_eq "finalize failure: exit 7" "7" "$L_RC"
assert_eq "finalize failure: the sentinel names FINALIZE_FAILED" "$(sentinel FINALIZE_FAILED 7)" "$(last_line "$L_OUT")"
assert_eq "the FINALIZE-FAILED line appears once on stdout" "1" "$(count_lines '## Concern Ledger: FINALIZE-FAILED — ' "$L_OUT")"
fl="$(printf '%s\n' "$L_OUT" | tr -d '\r' | grep -nF '## Concern Ledger: FINALIZE-FAILED — ' | head -n 1)"
assert_contains "the FINALIZE-FAILED line carries the would-be verdict" "(would-be verdict: " "$fl"
el="$(printf '%s\n' "$L_OUT" | grep -nF '<!-- end-codex-output' | tail -n 1 | cut -d: -f1)"
sl="$(printf '%s\n' "$L_OUT" | grep -nF 'REVIEW_LOOP_VERDICT:' | tail -n 1 | cut -d: -f1)"
fn="${fl%%:*}"
assert_eq "it follows the codex body" "yes" "$([ -n "$el" ] && [ -n "$fn" ] && [ "$fn" -gt "$el" ] && echo yes || echo no)"
assert_eq "and precedes the sentinel" "yes" "$([ -n "$sl" ] && [ -n "$fn" ] && [ "$fn" -lt "$sl" ] && echo yes || echo no)"
assert_contains "the same line also goes to stderr" "${fl#*:}" "$L_ERR"
case_end

# block <file> <start-regex> — the start line plus its continuation up to the next bullet or blank line.
block() {
    awk -v re="$2" '
        hit && (/^$/ || /^- / || /^[A-Z][a-z]+ [0-9]+ = /) { exit }
        hit { print; next }
        $0 ~ re { hit = 1; print }
    ' "$1"
}

case_begin "t2-3-review-tests-exit0-note-is-not-a-warnings-gap" "skills/review-tests/SKILL.md"
b="$(block "$SCRIPT_CHECKOUT_ROOT/skills/review-tests/SKILL.md" '^- exit 0 ')"
assert_contains "the exit 0 line names the downgrade note" "downgraded-medium" "$b"
assert_contains "and says it is not a WARNINGS ground" "WARNINGS" "$b"
b="$(block "$SCRIPT_CHECKOUT_ROOT/skills/review-tests/SKILL.md" '^- exit 3 ')"
assert_contains "the exit 3 line records the fallback round" "record-fallback" "$b"
case_end

case_begin "t2-3-review-plan-security-exit3-records-fallback" "skills/review-plan-security/SKILL.md"
b="$(block "$SCRIPT_CHECKOUT_ROOT/skills/review-plan-security/SKILL.md" '^- exit 3 ')"
assert_contains "the exit 3 line records the fallback round" "record-fallback" "$b"
case_end

case_begin "t2-3-shared-loop-exit3-records-fallback" "skills/_shared/codex-review-loop.md"
b="$(block "$SCRIPT_CHECKOUT_ROOT/skills/_shared/codex-review-loop.md" '^Exit 3 = ')"
assert_contains "the Exit 3 paragraph records the fallback round" "record-fallback" "$b"
case_end

finish
