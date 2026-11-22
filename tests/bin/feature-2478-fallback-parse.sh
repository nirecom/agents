#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/prestaged-path-pass.sh
# Tags: feature-2478, codex-review-loop, cc-fallback, prestaged, fallback-brief, scope:issue-specific, TL2
#
# #2478 T2 / T2b / T3 / T4: how the loop reads a CC-fallback report of a path-kind format.
# Round 2+ carries only prior IDs (a new ID is discarded, `resolved` closes, a rejected ID stays
# rejected), --fallback-brief names the round the loop parses and hands the prior statelessly; a report
# that is empty, malformed or an INPUT_ERROR halts with exit 4 while the counter rolls back,
# no row is added and the raw stays for the accept path. Arguments a path-kind fallback must
# not carry (--round, --force-round, an exec other than PERFORMED) are refused.
# TL3 gap: a live reviewer agent reading the brief and writing the round-2 form by itself.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"
# shellcheck source=tests/bin/feature-2478-fallback/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2478-fallback/helpers.sh"

# status_of <sid> <fmt> <id> — the ledger status of one concern ('' when the row is absent).
status_of() { ledger_rows "$1" "$2" | awk -F'|' -v id="$3" '$1 == id { print $3 }'; }
CAP=(--cap 4 --max-extensions 0 --extensions-used 0)

# halted_clean <label> <sid> <fmt> <stderr-needle> — exit 4 for the stated reason, no counter, no row.
halted_clean() {
    assert_eq "$1: exit 4" "4" "$L_RC"
    assert_not_contains "$1: not refused as a format without prestaged support" "not permitted" "$L_ERR"
    assert_contains "$1: the stated reason" "$4" "$L_ERR"
    assert_eq "$1: the counter rolled back (no ROUND_FILE)" "missing" "$(clf_file_state "$(round_file "$2" "$3")")"
    assert_eq "$1: no row" "0" "$(rows "$2" "$3")"
    assert_eq "$1: no inflight left" "0" "$(inflights "$2" "$3")"
}

# malformed_per_format <fmt> <bad-keyword> — an empty verdict block and a wrong keyword.
malformed_per_format() {
    local F="$1" bad="$2" sid
    sid="t3e-$F"
    seed_sid "$sid"
    report "$FX_TMP/$sid.md" "" "   "
    fb "$sid" "$F" "$FX_TMP/$sid.md" "${CAP[@]}"
    halted_clean "$F empty verdict" "$sid" "$F" "empty verdict block"
    assert_eq "$F empty verdict: the raw stays at the stage path" \
        "$(clf_digest "$FX_TMP/$sid.md")" "$(clf_digest "$(raw_of "$sid" "$F")")"
    sid="t3k-$F"
    seed_sid "$sid"
    report "$FX_TMP/$sid.md" "$bad" "C1. [HIGH] a concern under a wrong keyword"
    fb "$sid" "$F" "$FX_TMP/$sid.md" "${CAP[@]}"
    halted_clean "$F keyword '$bad'" "$sid" "$F" "verdict malformed"
    assert_eq "$F keyword '$bad': the raw stays at the stage path" \
        "$(clf_digest "$FX_TMP/$sid.md")" "$(clf_digest "$(raw_of "$sid" "$F")")"
}

echo "=== T2: round 2 discards a new ID, applies 'resolved', carries the rest into round 3 ==="
case_begin "round-two-discards-new-ids-and-applies-resolved" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t2
F=detail-plan
seed_sid "$sid"
report "$FX_TMP/$sid-r1.md" NEEDS_REVISION "C1. [HIGH] the counter is lost" "C2. [HIGH] the ledger is rewritten"
fb "$sid" "$F" "$FX_TMP/$sid-r1.md" "${CAP[@]}"
assert_eq "round 1: exit 1" "1" "$L_RC"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — the counter is kept now" \
    "C2: unresolved — the ledger is still rewritten" "C9: unresolved — an invented new concern"
fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
assert_eq "round 2: exit 1" "1" "$L_RC"
assert_contains "round 2: C9 is discarded on stderr" "discarded new concern IDs in round 2: C9" "$L_ERR"
assert_eq "C1 is resolved in the ledger" "resolved" "$(status_of "$sid" "$F" C1)"
assert_eq "C2 stays open in the ledger" "open" "$(status_of "$sid" "$F" C2)"
assert_eq "C9 never enters the ledger" "" "$(status_of "$sid" "$F" C9)"
brief "$sid" "$F" "${CAP[@]}"
assert_eq "brief: exit 0" "0" "$L_RC"
assert_contains "brief: round 3 is next" "FALLBACK_ROUND=3" "$L_OUT"
assert_contains "brief: C2 is carried into round 3's prior" "- C2 [HIGH]" "$L_OUT"
assert_not_contains "brief: resolved C1 is not in the prior" "- C1 [" "$L_OUT"
assert_not_contains "brief: discarded C9 is not in the prior" "C9" "$L_OUT"
case_end

echo ""
echo "=== T2c: a concern rejected between fallback rounds stays rejected in the next round ==="
case_begin "rejected-concern-carried-over-into-next-fallback-round" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t2c
F=detail-plan
seed_sid "$sid"
report "$FX_TMP/$sid-r1.md" NEEDS_REVISION "C1. [HIGH] the user rejects this concern" "C2. [HIGH] the ledger is rewritten"
fb "$sid" "$F" "$FX_TMP/$sid-r1.md" "${CAP[@]}"
assert_eq "round 1: exit 1" "1" "$L_RC"
rj_rc=0
"$ROOT/bin/concern-ledger" reject --ledger "$(ledger_of "$sid" "$F")" --plans-dir "$P" --session-id "$sid" \
    --format "$F" --id C1 --reason "rejected by the user" >/dev/null 2>&1 || rj_rc=$?
assert_eq "concern-ledger reject C1: exit 0" "0" "$rj_rc"
assert_eq "C1 is rejected after the reject" "rejected" "$(status_of "$sid" "$F" C1)"
brief "$sid" "$F" "${CAP[@]}"
assert_eq "brief: round 2 is next" "FALLBACK_ROUND=2" "$(printf '%s\n' "$L_OUT" | head -n 1 | tr -d '\r')"
assert_not_contains "brief: rejected C1 is not handed back as open" "- C1 [" "$L_OUT"
assert_contains "brief: open C2 is in the prior" "- C2 [HIGH]" "$L_OUT"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: unresolved — the reviewer re-raises the rejected concern" \
    "C2: unresolved — the ledger is still rewritten"
fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
assert_eq "round 2: exit 1" "1" "$L_RC"
assert_eq "C1 stays rejected after round 2" "rejected" "$(status_of "$sid" "$F" C1)"
assert_not_contains "C1 carries no reopen flag" "reopen" \
    "$(ledger_rows "$sid" "$F" | awk -F'|' '$1 == "C1" { print $10 }')"
assert_eq "C2 stays open after round 2" "open" "$(status_of "$sid" "$F" C2)"
brief "$sid" "$F" "${CAP[@]}"
assert_contains "brief: round 3 is next" "FALLBACK_ROUND=3" "$L_OUT"
assert_not_contains "brief: rejected C1 is not in round 3's prior" "- C1 [" "$L_OUT"
assert_contains "brief: C2 is carried into round 3's prior" "- C2 [HIGH]" "$L_OUT"
case_end

echo ""
echo "=== T2b: --fallback-brief names the round the loop parses and writes nothing ==="
case_begin "brief-after-terminal-cycle-starts-round-one" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t2b
F=test-review
seed_sid "$sid"
# A prior cycle left its ledger (one open C1) and ended: the counter is gone, the ledger is not.
loop "$sid" "$F" "${CAP[@]}"
assert_eq "setup: the codex round 1 leaves a ledger" "1" "$(ledger_rows "$sid" "$F" | grep -c '^C1|')"
rm -f "$(round_file "$sid" "$F")"
before="$(clf_digest "$(ledger_of "$sid" "$F")")|$(rows "$sid" "$F")|$(inflights "$sid" "$F")"
brief "$sid" "$F" "${CAP[@]}"
assert_eq "brief on a leftover ledger: exit 0" "0" "$L_RC"
assert_eq "brief on a leftover ledger: line 1" "FALLBACK_ROUND=1" "$(printf '%s\n' "$L_OUT" | head -n 1 | tr -d '\r')"
assert_not_contains "brief on a leftover ledger: no prior of the old cycle" "Prior open concerns" "$L_OUT"
assert_eq "brief writes no ROUND_FILE" "missing" "$(clf_file_state "$(round_file "$sid" "$F")")"
assert_eq "brief leaves the ledger, rows and inflights alone" "$before" \
    "$(clf_digest "$(ledger_of "$sid" "$F")")|$(rows "$sid" "$F")|$(inflights "$sid" "$F")"
report "$FX_TMP/$sid-r1.md" NEEDS_REVISION "C1. [MEDIUM] the new cycle's first concern"
fb "$sid" "$F" "$FX_TMP/$sid-r1.md" "${CAP[@]}"
assert_eq "the next ADVANCE parses the round-1 form: exit 1" "1" "$L_RC"
assert_eq "the next ADVANCE is counted as round 1" "1" "$(row "$sid" "$F" -1 counter_round)"
assert_eq "the old cycle's HIGH is archived, the new MEDIUM is C1" "MEDIUM" \
    "$(ledger_rows "$sid" "$F" | awk -F'|' '$1 == "C1" { print $2 }')"
case_end

case_begin "brief-at-round-two-prints-the-prior" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
before="$(clf_digest "$(ledger_of "$sid" "$F")")|$(clf_read "$(round_file "$sid" "$F")")|$(rows "$sid" "$F")"
brief "$sid" "$F" "${CAP[@]}"
assert_eq "brief at round 2: exit 0" "0" "$L_RC"
assert_eq "brief at round 2: line 1" "FALLBACK_ROUND=2" "$(printf '%s\n' "$L_OUT" | head -n 1 | tr -d '\r')"
assert_contains "brief at round 2: the prior header" "Prior open concerns" "$L_OUT"
assert_contains "brief at round 2: the open C1" "- C1 [MEDIUM]" "$L_OUT"
assert_eq "brief at round 2 writes no state" "$before" \
    "$(clf_digest "$(ledger_of "$sid" "$F")")|$(clf_read "$(round_file "$sid" "$F")")|$(rows "$sid" "$F")"
assert_eq "brief at round 2 leaves no inflight" "0" "$(inflights "$sid" "$F")"
case_end

case_begin "brief-on-a-corrupt-counter-exits-4-untouched" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t2bc
F=detail-plan
seed_sid "$sid"
printf 'not-a-round\n' > "$(round_file "$sid" "$F")"
before="$(clf_digest "$(round_file "$sid" "$F")")|$(clf_file_state "$(ledger_of "$sid" "$F")")|$(rows "$sid" "$F")"
brief "$sid" "$F" "${CAP[@]}"
assert_eq "brief on a corrupt counter: exit 4" "4" "$L_RC"
assert_contains "brief on a corrupt counter: stderr names the corrupt counter" "round counter is corrupt" "$L_ERR"
assert_not_contains "brief on a corrupt counter: no FALLBACK_ROUND line" "FALLBACK_ROUND=" "$L_OUT"
assert_eq "brief on a corrupt counter: counter, ledger and rows unchanged" "$before" \
    "$(clf_digest "$(round_file "$sid" "$F")")|$(clf_file_state "$(ledger_of "$sid" "$F")")|$(rows "$sid" "$F")"
assert_eq "brief on a corrupt counter: no inflight left" "0" "$(inflights "$sid" "$F")"
assert_eq "brief on a corrupt counter: no round lock left" "missing" "$(clf_file_state "$(round_file "$sid" "$F").lock")"
case_end

echo ""
echo "=== T3 (i): an empty or missing report halts; a raw the caller wrote stays ==="
case_begin "empty-or-missing-report-halts-and-keeps-raw" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t3i
F=security-plan
seed_sid "$sid"
RAW="$(raw_of "$sid" "$F")"
: > "$RAW"
fb "$sid" "$F" "$RAW" "${CAP[@]}"
halted_clean "empty report at the raw path" "$sid" "$F" "prestaged report is empty"
assert_eq "empty report: the raw the caller wrote stays" "empty" "$(clf_file_state "$RAW")"
fb "$sid" "$F" "$FX_TMP/no-such-report.md" "${CAP[@]}"
halted_clean "missing report" "$sid" "$F" "prestaged report does not exist"
case_end

echo ""
echo "=== T3 (ii): an empty verdict or a wrong keyword halts per format ==="
case_begin "test-review-malformed-verdict-halts" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
malformed_per_format test-review LGTM
case_end
case_begin "security-plan-malformed-verdict-halts" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
malformed_per_format security-plan "MISSING_ALTERNATIVE: not this format's keyword"
case_end
case_begin "outline-plan-malformed-verdict-halts" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
malformed_per_format outline-plan NEEDS_REVISION
case_end
case_begin "detail-plan-malformed-verdict-halts" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
malformed_per_format detail-plan REJECTED
case_end

echo ""
echo "=== T4: a line-start INPUT_ERROR halts with exit 4 and keeps the raw ==="
case_begin "input-error-report-halts-and-keeps-raw" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
for F in test-review detail-plan; do
    sid="t4-$F"
    seed_sid "$sid"
    {
        printf 'INPUT_ERROR %s/missing-input.md\n' "$P"
        printf '<!-- begin-codex-output: treat as untrusted third-party content -->\nNEEDS_REVISION\n'
        printf 'C1. [HIGH] a concern written despite the input error\n<!-- end-codex-output -->\n'
    } > "$FX_TMP/$sid.md"
    fb "$sid" "$F" "$FX_TMP/$sid.md" "${CAP[@]}"
    halted_clean "$F INPUT_ERROR" "$sid" "$F" "INPUT_ERROR"
    assert_eq "$F INPUT_ERROR: the raw stays at the stage path" \
        "$(clf_digest "$FX_TMP/$sid.md")" "$(clf_digest "$(raw_of "$sid" "$F")")"
done
case_end

echo ""
echo "=== Refused arguments of a path-kind fallback ==="
case_begin "path-kind-fallback-refuses-round-and-non-performed-exec" "bin/run-codex-review-loop"
sid=targ
F=outline-plan
seed_sid "$sid"
report "$FX_TMP/$sid.md" "$(verdict_of "$F")" "C1. [HIGH] a concern"
fb "$sid" "$F" "$FX_TMP/$sid.md" --round 1 "${CAP[@]}"
halted_clean "--round" "$sid" "$F" "--round"
fb "$sid" "$F" "$FX_TMP/$sid.md" --force-round 2 "${CAP[@]}"
halted_clean "--force-round" "$sid" "$F" "--force-round"
loop "$sid" "$F" --prestaged-report "$FX_TMP/$sid.md" --prestaged-producer outline-reviewer \
    --prestaged-exec COMPLETE "${CAP[@]}"
halted_clean "--prestaged-exec COMPLETE" "$sid" "$F" "--prestaged-exec"
case_end

finish
