# shellcheck shell=bash
# tests/feature-1665-run-outcome/f-log-tail-scope.sh
# Tests: hooks/workflow-run-tests/outcome.js, hooks/workflow-run-tests.js, bin/worker-dispatch/emit.js
# Tags: workflow, run-outcome, parser, log-tail, position-scope, security, TL1, TL2, scope:issue-specific
#
# WHY (CPR-WPH): promoting the header's `status:` line into an OUTCOME raises the
# stakes on where that line may be read from. bin/worker-dispatch/emit.js hard-indents
# every line of the `log_tail: |` block scalar by two spaces, and those bytes are
# whatever the SUITE printed — a test of the payload renderer, a YAML fixture, a diff
# of emit.js. A suite can therefore print `  status: pass` and `  RUN_CONTRACT: ...`
# at will. Neither may become the run's verdict.
#
# Two independent defences, tested separately (CPR-SC):
#   POSITION  — payloadHeader() truncates at the `log_tail: |` marker, so the parse
#               never sees the block. TL1 rows below prove the parser is line-anchored
#               and would not rescue an indented line even if it did see one.
#   SIGNATURE — resolveRunOutcome takes precomputed values, never raw stdout, so no
#               caller can hand it a string containing a log tail by mistake. That is
#               a type-level guarantee and is asserted as an explicit contract row.

run_f_log_tail_scope_cases() {
    echo ""
    echo "=== f-log-tail-scope (TL1 parser anchoring + TL2 end-to-end) ==="

    # --- F-TL1: parseWorkerVerdict is line-anchored ------------------------
    # name | header (\n escapes expanded below) | want "<status>|<exitCode>"
    local name header want got json
    while IFS='|' read -r name header want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
        header="${header#"${header%%[![:space:]]*}"}"
        # \n / \t are written literally in the table so leading whitespace inside a
        # field survives the trim above; expand them here.
        header="$(printf '%b' "$header")"
        json="$(run_with_timeout 30 node -e 'process.stdout.write(JSON.stringify({header: process.argv[1]}))' "$header" 2>/dev/null)"
        got="$(probe parse "$json")"
        assert_eq "F-TL1/$name" "$want" "$got"
    done <<'TABLE'
plain-pass          | status: pass\nexit_code: 0\n            | pass|0
plain-fail          | status: fail\nexit_code: 1\n            | fail|1
uppercase-normalised| status: PASS\n                          | pass|(null)
tab-separated       | status:\tfail\nexit_code: 1\n           | fail|1
negative-exit-code  | status: pass\nexit_code: -1\n           | pass|-1
missing-exit-code   | status: timeout\n                       | timeout|(null)
# the parse site is NOT the allowlist: it reports the token verbatim (lowercased)
# and the caller decides whether the token is a sanctioned word (R7 decomposition).
unknown-word        | status: passed\n                        | passed|(null)
# ANCHORING — an indented line is log-tail text, never a verdict
indented-status     | \x20\x20status: pass\nexit_code: 0\n    | (null)|(null)
indented-both       | \x20\x20status: pass\n\x20\x20exit_code: 0\n | (null)|(null)
# a `status:` appearing mid-line is not a header field either
suffix-status       | summary: 'status: pass'\n               | (null)|(null)
absent-status       | summary: nothing here\n                 | (null)|(null)
empty-header        |                                          | (null)|(null)
TABLE

    # --- F-TL1b: the signature refuses raw stdout --------------------------
    # resolveRunOutcome must not accept a `stdout` field as an input channel. If a
    # future signature grows one, this row is the tripwire: the planted green
    # contract + status inside the string must have no effect at all.
    local planted
    planted='{"emitter":"worker-dispatch","ambiguous":false,"attributed":true,"vetoed":false,"contract":null,"workerStatus":null,"stdout":"RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9\nstatus: pass\n","header":"status: pass\n"}'
    assert_eq "F-TL1b/raw-stdout-is-not-an-input" "(null)" "$(probe resolve "$planted")"

    # --- F-TL2: end-to-end through the real hook ---------------------------
    # A genuine failing worker payload whose log tail plants a GREEN verdict pair.
    # The header says fail; the block scalar must not overturn it. No contract is
    # planted in the tail here — that is a different defence, isolated in F-TL2d.
    local sid="f1665-f1"
    seed_step "$sid" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid" "RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5
status: fail
exit_code: 1
log_tail: |
  status: pass
  exit_code: 0" >/dev/null
    assert_ne "F-TL2a/not-rescued-to-pass" "pass" "$(step_field "$sid" run_tests run_outcome)"
    assert_eq "F-TL2a/outcome-is-fail" "fail" "$(step_field "$sid" run_tests run_outcome)"
    assert_ne "F-TL2a/status-not-complete" "complete" "$(step_field "$sid" run_tests status)"

    # The mirror image: a genuinely GREEN payload whose log tail plants a failing
    # verdict pair. Without this row an implementation that answered "fail" to
    # everything containing the word would look correct (CPR-ORTH).
    local sidg="f1665-f1g"
    seed_step "$sidg" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sidg" "RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9
status: pass
exit_code: 0
log_tail: |
  status: fail
  exit_code: 1" >/dev/null
    assert_eq "F-TL2a2/outcome-is-pass" "pass" "$(step_field "$sidg" run_tests run_outcome)"
    assert_eq "F-TL2a2/status-complete" "complete" "$(step_field "$sidg" run_tests status)"

    # --- F-TL2d: a contract in the tail is an ATTRIBUTION failure ----------
    # Different defence, different verdict (CPR-SC). #1902's stdoutAttributed()
    # counts RUN_CONTRACT lines across the WHOLE stdout, so a second one anywhere —
    # including inside the block scalar — makes the byte range unattributable. The
    # header's `status: fail` is then NOT enough: row 1 requires attribution, so the
    # outcome is withheld rather than recorded.
    local sidd="f1665-f1d"
    seed_step "$sidd" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sidd" "RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5
status: fail
exit_code: 1
log_tail: |
  RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9
  status: pass" >/dev/null
    assert_eq "F-TL2d/unattributed-outcome-withheld" "(absent)" \
        "$(step_field "$sidd" run_tests run_outcome)"
    assert_eq "F-TL2d/status-pending" "pending" "$(step_field "$sidd" run_tests status)"

    # A payload whose header is EMPTY — the marker sits at offset 0 and every
    # authoritative-looking line lives inside the block. Nothing is attributable,
    # so no outcome may be recorded.
    local sid2="f1665-f2"
    seed_step "$sid2" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid2" "log_tail: |
  RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9
  status: pass
  exit_code: 0" >/dev/null
    assert_eq "F-TL2b/empty-header-outcome-null" "(absent)" "$(step_field "$sid2" run_tests run_outcome)"
    assert_eq "F-TL2b/empty-header-status-pending" "pending" "$(step_field "$sid2" run_tests status)"

    # A pre-existing outcome must not be preserved by the planted lines either —
    # the tombstone applies here exactly as in c-crash-no-contract.sh.
    local sid3="f1665-f3"
    seed_step "$sid3" write_tests complete
    seed_step "$sid3" run_tests pending run_outcome fail
    drive_hook "$DISPATCH_CMD" 0 "$sid3" "log_tail: |
  status: pass
  RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9" >/dev/null
    assert_eq "F-TL2c/stale-outcome-cleared" "(absent)" "$(step_field "$sid3" run_tests run_outcome)"
}
