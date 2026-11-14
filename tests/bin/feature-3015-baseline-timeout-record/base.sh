# shellcheck shell=bash
# tests/bin/feature-3015-baseline-timeout-record/base.sh
# Tests: bin/lib/run-tests-baseline-classify.sh
# Tags: run-tests, baseline, timeout, classify, ledger, scope:issue-specific, pwsh-not-required, TL2
# #3015 base side: a base timeout at the full requested timeout is recorded as
# `und:timeout-at-base-after-<N>s` on the path the base ran, and the ledger stage reuses it when
# N >= requested. A branch timeout (BR_TIMEOUT) means no branch records.
# One function per case; the entrypoint wraps each in its case markers.

TR_NOW="$(date +%s)"

# rtb_cls_base_timeout <i> <run> <applied> <requested> <derived>, three tests in one child.
tr_base_timeout() {
  tr_drive "$TMPROOT/c-base-tmo" 'TESTS=("tests/bin/t.sh" "tests/bin/u.sh" "tests/bin/added.sh")
rtb_cls_base_timeout 0 tests/bin/t.sh 300 300 300
rtb_cls_base_timeout 1 tests/bin/u.sh 250 300 300
rtb_cls_base_timeout 2 tests/bin/added.sh 10 10 300
tr_report'
  tr_ck "full: timeout-at-base" "R0 cls=undetermined det=timeout-at-base brt= end=" "$(tr_line R0)"
  tr_has "full: ledger row und:timeout-at-base-after-300s on the run path" "LEDGER tests/bin/t.sh und:timeout-at-base-after-300s"
  tr_ck "budget-cut: budget-exhausted" "R1 cls=undetermined det=budget-exhausted brt= end=" "$(tr_line R1)"
  tr_lacks "budget-cut: no ledger row" "LEDGER tests/bin/u.sh"
  tr_lacks "budget-cut: no note (requested is not below derived)" "timeout not recorded: tests/bin/u.sh"
  tr_ck "explicit-below: budget-exhausted" "R2 cls=undetermined det=budget-exhausted brt= end=" "$(tr_line R2)"
  tr_lacks "explicit-below: no ledger row" "LEDGER tests/bin/added.sh"
  tr_has "explicit-below: the note names the derived value" \
    "timeout not recorded: tests/bin/added.sh requested 10s; explicit --per-test-timeout is below the derived 300s"
}

# One round-trip on one cache: the row the base writes is found again on the same base SHA and
# not on another one (TR_ANC, an ancestor, which can never inherit from its descendant).
tr_base_timeout_round_trip() {
  tr_drive "$TMPROOT/c-base-rt" 'TESTS=(tests/bin/t.sh); rtb_cls_base_timeout 0 tests/bin/t.sh 300 300 300
CLS=(); DET=(); RERUN=(); rtb_cls_ledger_stage; tr_report'
  tr_has "round-trip: the base wrote und:timeout-at-base-after-300s" "LEDGER tests/bin/t.sh und:timeout-at-base-after-300s"
  tr_ck "round-trip: the same base SHA finds the written row (a hit)" "R0 cls=undetermined det=timeout-at-base brt= end=" "$(tr_line R0)"
  tr_ck "round-trip: the same base SHA re-runs nothing" "RERUN=" "$(tr_line RERUN=)"
  tr_drive "$TMPROOT/c-base-rt" 'TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report' TR_B2="$TR_ANC"
  tr_ck "round-trip: another base SHA misses the row (the base re-runs)" "RERUN=0" "$(tr_line RERUN=)"
  tr_ck "round-trip: another base SHA leaves no class" "R0 cls= det= brt= end=" "$(tr_line R0)"
}

tr_ledger_hit() {
  tr_drive "$TMPROOT/c-led-hit" "tr_seed_ledger $TR_B2 tests/bin/t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "N=300 >= requested 300: a hit, detail without the N" "R0 cls=undetermined det=timeout-at-base brt= end=" "$(tr_line R0)"
  tr_ck "N=300: nothing re-runs at base" "RERUN=" "$(tr_line RERUN=)"
  tr_drive "$TMPROOT/c-led-low" "tr_seed_ledger $TR_B2 tests/bin/t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/t.sh); RTB_TIMEOUT_LEDGER=([0]=151); rtb_cls_ledger_stage; tr_report"
  tr_ck "N=300 below requested 302: the base re-runs" "RERUN=0" "$(tr_line RERUN=)"
  tr_ck "N=300 below requested: no class yet" "R0 cls= det= brt= end=" "$(tr_line R0)"
  tr_drive "$TMPROOT/c-led-high" "tr_seed_ledger $TR_B2 tests/bin/t.sh und:timeout-at-base-after-400s $TR_NOW
TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "N=400 > requested 300: a hit, detail without the N" "R0 cls=undetermined det=timeout-at-base brt= end=" "$(tr_line R0)"
  tr_ck "N=400 > requested: nothing re-runs at base" "RERUN=" "$(tr_line RERUN=)"
}

# A malformed N in the ledger row is never a hit: the base re-runs.
tr_ledger_malformed() {
  local name row want
  while IFS='|' read -r name row want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; row="${row//[[:space:]]/}"; want="${want//[[:space:]]/}"
    tr_drive "$TMPROOT/c-led-bad-$name" "tr_seed_ledger $TR_B2 tests/bin/t.sh $row $TR_NOW
TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report"
    tr_ck "$name: ledger row '$row' is a miss" "$want" "$(tr_line RERUN=)"
  done <<'TABLE'
zero           | und:timeout-at-base-after-0s    | RERUN=0
leading-zero   | und:timeout-at-base-after-0300s | RERUN=0
non-digit      | und:timeout-at-base-after-xs    | RERUN=0
missing-suffix | und:timeout-at-base-after-300   | RERUN=0
TABLE
}

tr_ledger_newest() {
  tr_drive "$TMPROOT/c-led-newer" "tr_seed_ledger $TR_B2 tests/bin/t.sh und:timeout-at-base-after-300s $((TR_NOW - 100))
tr_seed_ledger $TR_B2 tests/bin/t.sh pass $TR_NOW
TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "a newer pass row outranks the older timeout row: broken" "R0 cls=broken det=ledger-same-base brt= end=" "$(tr_line R0)"
  tr_drive "$TMPROOT/c-led-newer-tmo" "tr_seed_ledger $TR_B2 tests/bin/t.sh pass $((TR_NOW - 100))
tr_seed_ledger $TR_B2 tests/bin/t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "a newer timeout row outranks the older pass row: timeout-at-base" "R0 cls=undetermined det=timeout-at-base brt= end=" "$(tr_line R0)"
  tr_ck "a newer timeout row: nothing re-runs at base" "RERUN=" "$(tr_line RERUN=)"
}

# The only timeout row is on a real ancestor (TR_ANC) of the base; inheritance reads fail rows
# only, so it never counts and the descendant base re-runs.
tr_ledger_no_inherit() {
  tr_drive "$TMPROOT/c-led-anc" "tr_seed_ledger $TR_ANC tests/bin/t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "a timeout row on an ancestor base is never inherited: the descendant base re-runs" "RERUN=0" "$(tr_line RERUN=)"
  tr_ck "a timeout row on an ancestor base: no class" "R0 cls= det= brt= end=" "$(tr_line R0)"
}

tr_ledger_rename() {
  tr_drive "$TMPROOT/c-ren-brt" "tr_seed_ledger $TR_B2 tests/bin/old-t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/new-t.sh); BR_TIMEOUT[0]=1; rtb_cls_ledger_stage; tr_report"
  tr_ck "branch timeout + base timeout via the old path: timeout-at-base, no via suffix" \
    "R0 cls=undetermined det=timeout-at-base brt=1 end=" "$(tr_line R0)"
  tr_has "branch timeout + base timeout: the rename is told on stderr" \
    "run-tests-baseline: rename: tests/bin/new-t.sh ran at base as tests/bin/old-t.sh"
  tr_drive "$TMPROOT/c-ren-fail" "tr_seed_ledger $TR_B2 tests/bin/old-t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/new-t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "branch failure + base timeout via the old path: the detail keeps the via suffix" \
    "R0 cls=undetermined det=timeout-at-base-via-rename:tests/bin/old-t.sh brt= end=" "$(tr_line R0)"
  tr_drive "$TMPROOT/c-ren-new" "tr_seed_ledger $TR_B2 tests/bin/new-t.sh und:timeout-at-base-after-300s $TR_NOW
TESTS=(tests/bin/new-t.sh); rtb_cls_ledger_stage; tr_report"
  tr_ck "a row keyed on the new path (never the base's path) is not looked up: the base re-runs" "RERUN=0" "$(tr_line RERUN=)"
}

tr_no_branch_records() {
  tr_drive "$TMPROOT/c-combo" 'TESTS=(tests/bin/t.sh tests/bin/u.sh tests/bin/new-t.sh)
BR_TIMEOUT[0]=1; rtb_cls_base_pass 0 passes-at-base
BR_NOREC[1]=1; rtb_cls_base_pass 1 passes-at-base
BR_TIMEOUT[2]=1; mkdir -p "$TMP_BASE/empty-base.res"; rtb_cls_table1 2 "$ROOT" "$TMP_BASE/empty-base.res" "" fails-at-base-exit-1
tr_report'
  tr_ck "BR_TIMEOUT + base pass: broken (the branch failed by timing out)" "R0 cls=broken det=passes-at-base brt=1 end=" "$(tr_line R0)"
  tr_ck "BR_NOREC + base pass: records missing on the branch (unchanged)" \
    "R1 cls=new-case-failure-on-branch det=case-records-missing-on-branch brt= end=" "$(tr_line R1)"
  tr_ck "BR_TIMEOUT + base failure: records missing on the branch" \
    "R2 cls=new-case-failure-on-branch det=case-records-missing-on-branch brt=1 end=" "$(tr_line R2)"
}

tr_no_inherit_on_branch_timeout() {
  tr_drive "$TMPROOT/c-inh" 'rtb_cls_inherit() { echo "INHERIT-CALLED $1"; return 1; }
TESTS=(tests/bin/t.sh tests/bin/u.sh); BR_TIMEOUT[0]=1; rtb_cls_ledger_stage; tr_report'
  tr_lacks "BR_TIMEOUT: inheritance is not consulted" "INHERIT-CALLED 0"
  tr_has "control: without BR_TIMEOUT inheritance is consulted" "INHERIT-CALLED 1"
  tr_ck "both go to the base run" "RERUN=0 1" "$(tr_line RERUN=)"
}
