#!/usr/bin/env bash
# tests/hooks/feature-2517-baseline-accept-parity.sh
# Tests: hooks/workflow-mark/run-tests-baseline-accept-handler.js, bin/workflow/lib/run-tests-baseline-evidence.js
# Tags: TL2, hooks, workflow-mark, run-tests, baseline, escape-hatch, security, parity, scope:issue-specific
# CPR-ORTH (#2517 review): the sentinel handler's grant verdict and the CLI's accept verdict agree on
# every strict_rows shape. Per row, the real workflow-mark.js receives the sentinel; then the real
# evidence CLI runs `accept` on the handler's grant, or on a grant forged for the row's kind when the
# handler refused, so the CLI's own grantKind is exercised on every row.
# TL3 gap: no live session emits the sentinel; feature-2517-run-tests-baseline-accept.sh owns that seam.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

T="$(make_tmp)"
readonly T
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$T/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"

# shellcheck source=feature-2517-run-tests-baseline-accept/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2517-run-tests-baseline-accept/_lib.sh"
EVIDENCE_CLI="$SCRIPT_CHECKOUT_ROOT/bin/workflow/run-tests-baseline-evidence"

# cli_verdict <sid> — granted when accept exits 0 and run_tests is complete, else rejected.
cli_verdict() {
  local rc=0
  (cd "$T" && run_with_timeout 30 "$EVIDENCE_CLI" accept --session "$1" >/dev/null 2>&1) || rc=$?
  if [[ "$rc" -eq 0 && "$(st field "$1" run_tests status)" == complete ]]; then
    printf 'granted'
  else
    printf 'rejected'
  fi
}

# parity_row <id> — the strict_rows row <id> through the handler, then through the CLI.
parity_row() {
  local id kind verdict gkind row sid hv cv seq ro
  row="$(strict_rows | grep "^$1|")"
  IFS='|' read -r id kind verdict gkind <<<"$row"
  [[ -n "$kind" ]] || { fail "fixture: strict_rows has no row $1"; return; }
  sid="f2517-parity-$id"
  setup_state "$sid" "$kind"
  mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
  hv="granted"
  if [[ "$(st field "$sid" run_tests baseline_accept)" == "(absent)" ]]; then
    hv="rejected"
    seq="$(st field "$sid" run_tests updated_seq)"
    ro="$(st field "$sid" run_tests run_outcome)"
    st ann "$sid" baseline_accept "{\"reason\":\"$REASON_OK\",\"kind\":\"$gkind\",\"run_seq\":$seq,\"outcome_source\":null,\"accepted_run_outcome\":\"$ro\"}" >/dev/null
    assert_eq "$id fixture: forged grant kind: $(st path "$sid" run_tests baseline_accept kind)" \
      "$id fixture: forged grant kind: $gkind"
  fi
  cv="$(cli_verdict "$sid")"
  assert_eq "$id handler=$hv cli=$cv" "$id handler=$verdict cli=$verdict"
}

case_begin "parity-H1-listless-unrunnable-null" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
parity_row H1
case_end

case_begin "parity-H2-listless-unrunnable-absent" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
parity_row H2
case_end

case_begin "parity-H3-listless-unrunnable-zero" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
parity_row H3
case_end

case_begin "parity-H4-classification-missing-path" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H4
case_end

case_begin "parity-H5-classification-foreign-path" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H5
case_end

case_begin "parity-H6-classification-all-preexisting" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H6
case_end

case_begin "parity-H7-listed-unrunnable-null" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H7
case_end

case_begin "parity-H8-listed-undetermined-mix" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H8
case_end

case_begin "parity-H9-classification-duplicate-path" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H9
case_end

case_begin "parity-H10-listless-unrunnable-negative" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H10
case_end

case_begin "parity-H11-listless-unrunnable-string-zero" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H11
case_end

case_begin "parity-H12-listed-unrunnable-negative" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H12
case_end

case_begin "parity-H13-listed-unrunnable-string-zero" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H13
case_end

case_begin "parity-H14-empty-list-timeout" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H14
case_end

case_begin "parity-H15-empty-list-runner-error" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H15
case_end

case_begin "parity-H16-listed-unrunnable-absent" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H16
case_end

case_begin "parity-H17-listed-inherited-undetermined-mix" "bin/workflow/lib/run-tests-baseline-evidence.js"
parity_row H17
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
