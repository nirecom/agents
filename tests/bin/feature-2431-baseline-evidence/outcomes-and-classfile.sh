# shellcheck shell=bash
# tests/bin/feature-2431-baseline-evidence/outcomes-and-classfile.sh
# Tests: bin/workflow/run-tests-baseline-evidence, bin/workflow/lib/run-tests-baseline-evidence.js
# Tags: run-tests, baseline, evidence, workflow, scope:issue-specific, pwsh-not-required, TL2
# Sourced by ../feature-2431-baseline-evidence.sh after its helpers; never run standalone.
# `failing` lists a run only when run_outcome is a failing value (FAILING_OUTCOMES), and
# `record` refuses an unparseable or unreadable classification file with the usage exit.

# bec_ck <name> <want> <got> — the row name is in every message.
bec_ck() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi
}

# --- `failing` over every run_outcome value: both verdicts, one row per case -------------
# bec_failing_row <label> <run_outcome or absent> <want exit>
bec_failing_row() {
  local olabel="$1" ovalue="$2" owant="$3"
  SID="$(next_sid "ro-$olabel")"
  if seed_pending_outcome "$SID" "$ovalue" 0 "tests/bin/omega.sh" && [ "$CLI_EXISTS" = "1" ]; then
    bec_ck "failing-run-outcome-$olabel: control — run_tests is pending" '"pending"' \
      "$(read_step_field "$SID" run_tests status)"
    run_failing "$SID"
    bec_ck "failing-run-outcome-$olabel: exit" "$owant" "$EV_RC"
    EV_OUT="$(printf '%s' "$EV_OUT" | tr -d '\r')"
    if [ "$owant" = "0" ]; then
      USEQ="$(read_step_field "$SID" run_tests updated_seq)"
      bec_ck "failing-run-outcome-$olabel: SEQ is the state seq" "SEQ=$USEQ" "$(printf '%s\n' "$EV_OUT" | sed -n 1p)"
      bec_ck "failing-run-outcome-$olabel: failing path listed" "tests/bin/omega.sh" "$(printf '%s\n' "$EV_OUT" | sed -n 2p)"
    else
      bec_ck "failing-run-outcome-$olabel: no SEQ printed" "0" "$(printf '%s\n' "$EV_OUT" | grep -c '^SEQ=')"
    fi
  else
    fail "failing-run-outcome-$olabel: seed or CLI missing"
  fi
}

case_begin "failing-run-outcome-fail" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row fail fail 0
case_end

case_begin "failing-run-outcome-timeout" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row timeout timeout 0
case_end

case_begin "failing-run-outcome-runner-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row runner-error runner-error 0
case_end

# Non-failing values: the step is not baseline-classifiable.
case_begin "failing-run-outcome-passed" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row passed pass 3
case_end

case_begin "failing-run-outcome-unrunnable" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row unrunnable unrunnable 3
case_end

case_begin "failing-run-outcome-skip" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row skip skip 3
case_end

case_begin "failing-run-outcome-absent" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_failing_row absent absent 3
case_end

# --- `record` with a classification file it cannot use: usage exit 2, nothing written ----
# bec_record_row <label> <file content as printf %b, or @missing / @dir>
# Each row closes with a control: the same session re-recorded with a valid file completes,
# so a refusal cannot pass merely because the session was not classifiable.
bec_record_row() {
  local clabel="$1" cbody="$2"
  SID="$(next_sid "cf-$clabel")"
  if seed_pending_fail "$SID" 0 "tests/bin/omega.sh" && [ "$CLI_EXISTS" = "1" ]; then
    SEQ_VAL="$(get_seq "$SID")"
    CLASSFILE="$TMPROOT/cls-bad-$clabel.txt"
    case "$cbody" in
      @missing) rm -f "$CLASSFILE" ;;
      @dir) mkdir -p "$CLASSFILE" ;;
      *) printf '%b' "$cbody" > "$CLASSFILE" ;;
    esac
    run_record "$SID" "${SEQ_VAL:-1}" "$CLASSFILE"
    bec_ck "record-classification-$clabel: usage exit" "2" "$REC_RC"
    assert_not_completed "record-classification-$clabel" "$SID"
    bec_ck "record-classification-$clabel: no baseline_classification written" "(absent)" \
      "$(read_step_field "$SID" run_tests baseline_classification)"
    case "$REC_ERR" in
      *"cannot read classification"*) pass "record-classification-$clabel: reason names the file" ;;
      *) fail "record-classification-$clabel: reason" "stderr=$REC_ERR" ;;
    esac
    printf 'tests/bin/omega.sh\tpreexisting\tbase-fail\n' > "$TMPROOT/cls-ok-$clabel.txt"
    run_record "$SID" "${SEQ_VAL:-1}" "$TMPROOT/cls-ok-$clabel.txt"
    bec_ck "record-classification-$clabel: control — a valid file then records" "0" "$REC_RC"
    bec_ck "record-classification-$clabel: control — and completes run_tests" '"complete"' \
      "$(read_step_field "$SID" run_tests status)"
  else
    fail "record-classification-$clabel: seed or CLI missing"
  fi
}

case_begin "record-classification-invalid-class-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row invalid-class 'tests/bin/omega.sh\tfixed\tbase-fail\n'
case_end

case_begin "record-classification-class-case-mismatch-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row class-case-mismatch 'tests/bin/omega.sh\tPreexisting\tbase-fail\n'
case_end

case_begin "record-classification-no-tab-separator-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row no-tab-separator 'tests/bin/omega.sh preexisting base-fail\n'
case_end

case_begin "record-classification-empty-path-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row empty-path '\tpreexisting\tbase-fail\n'
case_end

case_begin "record-classification-valid-then-garbage-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row valid-then-garbage 'tests/bin/omega.sh\tpreexisting\tbase-fail\nnot a classification line\n'
case_end

case_begin "record-classification-missing-file-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row missing-file @missing
case_end

case_begin "record-classification-directory-not-file-is-usage-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
bec_record_row directory-not-file @dir
case_end
