# shellcheck shell=bash
# tests/bin/feature-3015-baseline-timeout-record/branch.sh
# Tests: bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, timeout, branch, scope:issue-specific, pwsh-not-required, TL2
# #3015 branch stage: a run that timed out at the full requested timeout is cached as
# `timeout-after-<N>s`, and a later run with N >= requested is a hit (no re-run). A timeout cut by the
# budget, or by an explicit value below the derived one, is not recorded.
# One function per case; the entrypoint wraps each in its case markers.

TR_BRANCH_RUN='TESTS=("tests/bin/t.sh"); rtb_branch_stage; tr_report'
# Measured 151s -> derived (requested) 302s.
TR_MEASURED_151='RTB_TIMEOUT_LEDGER=([0]=151); '

tr_branch_recorded() {
  tr_drive "$TMPROOT/c-br-rec" "$TR_BRANCH_RUN"
  tr_ck "unmeasured: the stage ran the test once" "CALLS=1" "$(tr_line CALLS=)"
  tr_has "unmeasured: the requested 300s was applied" "branch re-run: tests/bin/t.sh 300s"
  tr_ck "a full-length timeout is cached as timeout-after-300s with fp -" "CACHE tests/bin/t.sh timeout-after-300s -" "$(tr_line 'CACHE tests/bin/t.sh')"
  tr_ck "the test is left for the base (no class), marked BR_TIMEOUT, normal end" "R0 cls= det= brt=1 end=normal" "$(tr_line R0)"
  tr_lacks "a recordable timeout prints no 'not recorded' note" "timeout not recorded"
}

# Reuses tr_branch_recorded's cache.
tr_branch_hit() {
  tr_drive "$TMPROOT/c-br-rec" "$TR_BRANCH_RUN"
  tr_ck "idempotent: a second run on the same cache does not run the test" "CALLS=0" "$(tr_line CALLS=)"
  tr_lacks "idempotent: no 'branch re-run' line on the hit" "branch re-run: tests/bin/t.sh"
  tr_ck "idempotent: the hit classifies the same as the run" "R0 cls= det= brt=1 end=normal" "$(tr_line R0)"
}

tr_branch_boundary() {
  tr_drive "$TMPROOT/c-br-302" "tr_seed_branch tests/bin/t.sh timeout-after-302s; $TR_MEASURED_151$TR_BRANCH_RUN"
  tr_ck "boundary: N = requested (302) is a hit" "CALLS=0" "$(tr_line CALLS=)"
  tr_ck "boundary: the hit sets BR_TIMEOUT" "R0 cls= det= brt=1 end=normal" "$(tr_line R0)"
  tr_drive "$TMPROOT/c-br-300" "tr_seed_branch tests/bin/t.sh timeout-after-300s; $TR_MEASURED_151$TR_BRANCH_RUN"
  tr_ck "boundary: N = 300 below requested 302 is a miss (re-run)" "CALLS=1" "$(tr_line CALLS=)"
  tr_has "boundary: the re-run is recorded at the new requested value" "CACHE tests/bin/t.sh timeout-after-302s -"
}

# Requested 302s for every row: a well-formed N >= 302 is a hit (CALLS=0), a malformed row is never trusted (CALLS=1).
tr_branch_cache_row() {
  local name row want
  while IFS='|' read -r name row want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; row="${row//[[:space:]]/}"; want="${want//[[:space:]]/}"
    tr_drive "$TMPROOT/c-br-row-$name" "tr_seed_branch tests/bin/t.sh $row; $TR_MEASURED_151$TR_BRANCH_RUN"
    tr_ck "$name: cache row '$row' (requested 302s)" "$want" "$(tr_line CALLS=)"
  done <<'TABLE'
valid-equal    | timeout-after-302s   | CALLS=0
valid-above    | timeout-after-400s   | CALLS=0
zero           | timeout-after-0s     | CALLS=1
non-digit      | timeout-after-xs     | CALLS=1
missing-suffix | timeout-after-302    | CALLS=1
leading-zero   | timeout-after-0302s  | CALLS=1
negative       | timeout-after--302s  | CALLS=1
TABLE
}

# u.sh (measured 10s) runs first and consumes 200s, so t.sh (unmeasured, requested 300s) gets ~203s.
tr_branch_budget_cut() {
  tr_drive "$TMPROOT/c-br-short" 'TESTS=("tests/bin/t.sh" "tests/bin/u.sh"); RTB_TIMEOUT_LEDGER=([1]=10); rtb_branch_stage; tr_report' TR_ADVANCE=200
  tr_ck "budget: two runs" "CALLS=2" "$(tr_line CALLS=)"
  tr_has "budget: the first (full 300s) timeout is recorded" "CACHE tests/bin/u.sh timeout-after-300s -"
  tr_lacks "budget: the shortened timeout leaves no row" "CACHE tests/bin/t.sh"
  tr_ck "budget: the shortened timeout is budget-exhausted" "R0 cls=undetermined det=budget-exhausted brt= end=" "$(tr_line R0)"
  tr_lacks "budget: a budget cut is no unrecordable-timeout note" "timeout not recorded: tests/bin/t.sh"
}

# Measured 250s -> requested 500s; the branch stage can apply at most ~403s (600-45-150-2).
tr_branch_cap() {
  tr_drive "$TMPROOT/c-br-cap" "RTB_TIMEOUT_LEDGER=([0]=250); $TR_BRANCH_RUN"
  tr_ck "cap: budget-exhausted" "R0 cls=undetermined det=budget-exhausted brt= end=" "$(tr_line R0)"
  tr_lacks "cap: no cache row" "CACHE tests/bin/t.sh"
  tr_match "cap: the note names the stage maximum and the fix" \
    '^run-tests-baseline: timeout not recorded: tests/bin/t\.sh requested 500s; the branch stage applies at most [0-9]+s: shorten or split the test$'
}

tr_branch_explicit_low() {
  tr_drive "$TMPROOT/c-br-expl" "$TR_BRANCH_RUN" TR_PTT_EXPLICIT=1 TR_PTT=10
  tr_ck "explicit: budget-exhausted" "R0 cls=undetermined det=budget-exhausted brt= end=" "$(tr_line R0)"
  tr_lacks "explicit: no cache row" "CACHE tests/bin/t.sh"
  tr_has "explicit: the note names the derived value" \
    "run-tests-baseline: timeout not recorded: tests/bin/t.sh requested 10s; explicit --per-test-timeout is below the derived 300s: drop it or raise it"
}

tr_branch_explicit_high() {
  tr_drive "$TMPROOT/c-br-expl-hi" "$TR_BRANCH_RUN" TR_PTT_EXPLICIT=1 TR_PTT=320
  tr_has "explicit 320 >= derived 300: recorded at the requested value" "CACHE tests/bin/t.sh timeout-after-320s -"
  tr_ck "explicit 320: BR_TIMEOUT, no class" "R0 cls= det= brt=1 end=normal" "$(tr_line R0)"
}
