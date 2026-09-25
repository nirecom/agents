# shellcheck shell=bash
# tests/feature-1665-run-outcome/a-outcome-table.sh
# Tests: hooks/workflow-run-tests/outcome.js
# Tags: workflow, run-outcome, classifier, table-driven, mutation-probe, TL1, scope:issue-specific
#
# TL1 — resolveRunOutcome / isContractTrusted called directly.
#
# Three layers, deliberately separated (CPR-SC):
#   (A) LITERAL DECISION TABLE — hand-written want values, one row per verdict per
#       axis. No logic in the test, per skills/_shared/test-design/parser-regex-tests.md.
#       Covers every verdict of the classifier, not only "fail" (CPR-ORTH).
#   (B) MUTATION PROBE — the 6 conjuncts of isContractTrusted flipped ONE at a time
#       from an all-true base. Each flip must collapse both isContractTrusted to
#       false AND resolveRunOutcome to null. This is what stops R3's SSOT-ised
#       predicate from silently dropping a conjunct (!ambiguous and !vetoed are the
#       two most easily lost — #1273 ambiguity and #1242 C' veto).
#   (C) EXHAUSTIVE SWEEP — the full 360-row cross product
#       emitter x ambiguous x attributed x vetoed x contract x workerStatus.
#       Hand-writing 360 want values would be transcription, not verification, so
#       the sweep asserts INVARIANTS derived from the plan's 4-row decision table
#       instead. Layer (A) supplies the exact values; (C) proves no combination
#       escapes the table's shape.

C_NULL='null'
C_PASS='{"pass":3,"fail":0,"skip":0,"executed":3}'
C_FAIL='{"pass":3,"fail":2,"skip":0,"executed":5}'
C_ZEROEXEC='{"pass":3,"fail":0,"skip":0,"executed":0}'
C_ALLSKIP='{"pass":0,"fail":0,"skip":5,"executed":5}'

# contract_json <key> → the JSON literal for a table cell
contract_json() {
    case "$1" in
        NULL) echo "$C_NULL" ;;
        PASS) echo "$C_PASS" ;;
        FAIL) echo "$C_FAIL" ;;
        ZEROEXEC) echo "$C_ZEROEXEC" ;;
        ALLSKIP) echo "$C_ALLSKIP" ;;
        *) echo "null" ;;
    esac
}

# json_or_null <literal> → JSON string or the null literal (for emitter/workerStatus)
json_or_null() {
    if [ "$1" = "-" ]; then echo "null"; else echo "\"$1\""; fi
}

# ro <emitter> <ambiguous> <attributed> <vetoed> <contractKey> <workerStatus>
ro() {
    local input
    input="{\"emitter\":$(json_or_null "$1"),\"ambiguous\":$2,\"attributed\":$3,\"vetoed\":$4,\"contract\":$(contract_json "$5"),\"workerStatus\":$(json_or_null "$6")}"
    probe resolve "$input"
}

# ct <emitter> <ambiguous> <attributed> <vetoed> <contractKey> <workerStatus>
ct() {
    local input
    input="{\"emitter\":$(json_or_null "$1"),\"ambiguous\":$2,\"attributed\":$3,\"vetoed\":$4,\"contract\":$(contract_json "$5"),\"workerStatus\":$(json_or_null "$6")}"
    probe trusted "$input"
}

run_a_outcome_table_cases() {
    echo ""
    echo "=== a-outcome-table (TL1: resolveRunOutcome / isContractTrusted) ==="

    # --- vocabulary -------------------------------------------------------
    # No new words: emit.js's renderer vocabulary is the whole outcome domain.
    assert_eq "A0/RUN_OUTCOME_VALUES" "pass,fail,timeout,runner-error" "$(probe values '{}')"

    # --- (A) literal decision table ---------------------------------------
    # name | emitter | ambiguous | attributed | vetoed | contract | workerStatus | want
    local name emitter amb att vet con ws want got
    while IFS='|' read -r name emitter amb att vet con ws want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; emitter="${emitter//[[:space:]]/}"
        amb="${amb//[[:space:]]/}"; att="${att//[[:space:]]/}"
        vet="${vet//[[:space:]]/}"; con="${con//[[:space:]]/}"
        ws="${ws//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(ro "$emitter" "$amb" "$att" "$vet" "$con" "$ws")"
        assert_eq "A/$name" "$want" "$got"
    done <<'TABLE'
# --- run-all route: contract decides, and FAIL>0 is the C1 primary path ---
runall-trusted-fail            | run-all         | false | true  | false | FAIL     | - | fail
runall-trusted-pass            | run-all         | false | true  | false | PASS     | - | pass
runall-ambiguous               | run-all         | true  | true  | false | FAIL     | - | (null)
runall-unattributed            | run-all         | false | false | false | FAIL     | - | (null)
runall-vetoed                  | run-all         | false | true  | true  | FAIL     | - | (null)
runall-contract-absent         | run-all         | false | true  | false | NULL     | - | (null)
runall-executed-zero           | run-all         | false | true  | false | ZEROEXEC | - | (null)
runall-all-skip                | run-all         | false | true  | false | ALLSKIP  | - | (null)
# no provenance at all: the caller can only ever hand a null contract with it
no-emitter-no-contract         | -               | false | true  | false | NULL     | - | (null)
# worker `status:` is scoped to the worker route; on run-all the contract wins
runall-workerstatus-ignored-f  | run-all         | false | true  | false | FAIL     | fail | fail
runall-workerstatus-ignored-p  | run-all         | false | true  | false | PASS     | fail | pass
runall-workerstatus-no-rescue  | run-all         | false | true  | false | NULL     | fail | (null)
# --- worker-dispatch route: the worker's own verdict is row 1 -------------
# a non-pass status ALSO vetoes the contract, so these rows carry vetoed=true
wd-status-fail                 | worker-dispatch | false | true  | true  | FAIL     | fail         | fail
wd-status-timeout              | worker-dispatch | false | true  | true  | NULL     | timeout      | timeout
wd-status-runner-error         | worker-dispatch | false | true  | true  | NULL     | runner-error | runner-error
# row 1 outranks a green contract: the process that ran the suite is authoritative
wd-status-fail-beats-pass-con  | worker-dispatch | false | true  | true  | PASS     | fail         | fail
# status: pass is NOT a row-1 value — it falls through to the contract rows
wd-status-pass-trusted         | worker-dispatch | false | true  | false | PASS     | pass | pass
wd-status-pass-trusted-fail    | worker-dispatch | false | true  | false | FAIL     | pass | fail
wd-status-pass-all-skip        | worker-dispatch | false | true  | false | ALLSKIP  | pass | (null)
wd-status-pass-no-contract     | worker-dispatch | false | true  | false | NULL     | pass | (null)
wd-status-pass-but-vetoed      | worker-dispatch | false | true  | true  | PASS     | pass | (null)
# a missing / unrecognised status vetoes and is not a row-1 value (allowlist)
wd-status-absent               | worker-dispatch | false | true  | true  | PASS     | -      | (null)
wd-status-typo-passed          | worker-dispatch | false | true  | true  | PASS     | passed | (null)
wd-status-unknown-word         | worker-dispatch | false | true  | true  | PASS     | green  | (null)
# ambiguity and unattributed bytes veto row 1 as hard as they veto the contract
wd-fail-but-ambiguous          | worker-dispatch | true  | true  | true  | FAIL     | fail | (null)
wd-fail-but-unattributed       | worker-dispatch | false | false | true  | FAIL     | fail | (null)
wd-timeout-but-ambiguous       | worker-dispatch | true  | true  | true  | NULL     | timeout | (null)
wd-timeout-but-unattributed    | worker-dispatch | false | false | true  | NULL     | timeout | (null)
TABLE

    # --- (B) mutation probe over the 6 conjuncts of isContractTrusted ------
    # Base: every conjunct true → trusted, and the contract's FAIL==0 → "pass".
    assert_eq "B0/base-trusted"  "true" "$(ct run-all false true false PASS -)"
    assert_eq "B0/base-resolves" "pass" "$(ro run-all false true false PASS -)"

    # name | emitter | ambiguous | attributed | vetoed | contract
    local mname
    while IFS='|' read -r mname emitter amb att vet con; do
        [[ -z "$mname" || "$mname" =~ ^[[:space:]]*# ]] && continue
        mname="${mname//[[:space:]]/}"; emitter="${emitter//[[:space:]]/}"
        amb="${amb//[[:space:]]/}"; att="${att//[[:space:]]/}"
        vet="${vet//[[:space:]]/}"; con="${con//[[:space:]]/}"
        assert_eq "B/$mname-trusted-false" "false"  "$(ct "$emitter" "$amb" "$att" "$vet" "$con" -)"
        assert_eq "B/$mname-collapses"     "(null)" "$(ro "$emitter" "$amb" "$att" "$vet" "$con" -)"
    done <<'MUTATIONS'
conjunct1-not-ambiguous  | run-all | true  | true  | false | PASS
conjunct2-attributed     | run-all | false | false | false | PASS
conjunct3-not-vetoed     | run-all | false | true  | true  | PASS
conjunct4-contract-nonnull | run-all | false | true  | false | NULL
conjunct5-executed-gt0   | run-all | false | true  | false | ZEROEXEC
conjunct6-passfail-gt0   | run-all | false | true  | false | ALLSKIP
MUTATIONS

    # `fail` is NOT a conjunct of isContractTrusted (R3): the predicate must stay
    # true for a failing-but-trustworthy contract, or the C1 primary path dies.
    assert_eq "B/fail-is-not-a-conjunct" "true" "$(ct run-all false true false FAIL -)"

    # --- (C) exhaustive sweep ---------------------------------------------
    local axes sweep
    axes='{"axes":{"emitter":[null,"run-all","worker-dispatch"],"ambiguous":[false,true],"attributed":[false,true],"vetoed":[false,true],"contract":[null,{"pass":3,"fail":0,"skip":0,"executed":3},{"pass":3,"fail":2,"skip":0,"executed":5}],"workerStatus":[null,"pass","fail","timeout","runner-error"]}}'
    sweep="$(probe sweep "$axes")"

    # GUARD before the invariants, not after. Every S-assertion below is of the
    # form "no row violates X", which an EMPTY sweep satisfies trivially — so a
    # missing module would report five green invariants over zero rows. Bail out
    # loudly instead: no invariant may be evaluated against an unusable sweep.
    local rows inv
    rows="$(printf '%s\n' "$sweep" | grep -c '	')"
    if [ "${sweep#ERR:}" != "$sweep" ] || [ "$rows" != "360" ]; then
        fail "C/sweep-ran" "unusable sweep (rows=$rows): $(printf '%s' "$sweep" | head -1)"
        for inv in S1-result-domain-closed S2-ambiguous-always-null \
                   S3-unattributed-always-null S4-nonworker-veto-always-null \
                   S5-pass-needs-trusted-c1 S6-timeout-is-worker-only \
                   S6-timeout-is-verbatim S7-verdict-reachable; do
            fail "C/$inv" "not evaluated — the sweep produced no usable rows"
        done
        return 0
    fi
    pass "C/sweep-ran"
    assert_eq "C/sweep-row-count" "360" "$rows"

    # Key layout: emitter:ambiguous:attributed:vetoed:cN:workerStatus <TAB> result
    # c0=absent contract, c1=FAIL==0 contract, c2=FAIL>0 contract.
    local bad
    # S1 — the result domain is closed over RUN_OUTCOME_VALUES + null.
    bad="$(printf '%s\n' "$sweep" | awk -F'\t' '$2!="pass"&&$2!="fail"&&$2!="timeout"&&$2!="runner-error"&&$2!="(null)"' | head -3)"
    assert_eq "C/S1-result-domain-closed" "" "$bad"
    # S2 — ambiguous provenance blocks BOTH the worker row and the contract rows.
    bad="$(printf '%s\n' "$sweep" | awk -F'\t' '$1 ~ /^[^:]*:true:/ && $2!="(null)"' | head -3)"
    assert_eq "C/S2-ambiguous-always-null" "" "$bad"
    # S3 — unattributed stdout likewise.
    bad="$(printf '%s\n' "$sweep" | awk -F'\t' '$1 ~ /^[^:]*:[a-z]*:false:/ && $2!="(null)"' | head -3)"
    assert_eq "C/S3-unattributed-always-null" "" "$bad"
    # S4 — a veto off the worker route has no row-1 escape hatch.
    bad="$(printf '%s\n' "$sweep" | awk -F':' '$1!="worker-dispatch"' | awk -F'\t' '$1 ~ /^[^:]*:[a-z]*:[a-z]*:true:/ && $2!="(null)"' | head -3)"
    assert_eq "C/S4-nonworker-veto-always-null" "" "$bad"
    # S5 — "pass" is reachable only from a trusted FAIL==0 contract.
    bad="$(printf '%s\n' "$sweep" | awk -F'\t' '$2=="pass" && $1 !~ /^[^:]*:false:true:false:c1:/' | head -3)"
    assert_eq "C/S5-pass-needs-trusted-c1" "" "$bad"
    # S6 — timeout / runner-error exist ONLY as the worker's own verbatim verdict.
    bad="$(printf '%s\n' "$sweep" | awk -F'\t' '($2=="timeout"||$2=="runner-error") && $1 !~ /^worker-dispatch:/' | head -3)"
    assert_eq "C/S6-timeout-is-worker-only" "" "$bad"
    bad="$(printf '%s\n' "$sweep" | awk -F'\t' '($2=="timeout"||$2=="runner-error") && $1 !~ (":"$2"$")' | head -3)"
    assert_eq "C/S6-timeout-is-verbatim" "" "$bad"
    # S7 — every verdict is actually reachable somewhere in the product; a sweep
    # that only ever answers null would satisfy S1-S6 vacuously.
    local v
    for v in pass fail timeout runner-error "(null)"; do
        if printf '%s\n' "$sweep" | awk -F'\t' -v w="$v" '$2==w' | grep -q .; then
            pass "C/S7-verdict-reachable-$v"
        else
            fail "C/S7-verdict-reachable-$v" "no row in the 360-combination sweep yields $v"
        fi
    done
}
