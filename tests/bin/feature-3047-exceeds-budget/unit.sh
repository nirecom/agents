# shellcheck shell=bash
# tests/bin/feature-3047-exceeds-budget/unit.sh
# Tests: bin/lib/run-tests-baseline-timeout.sh
# Tags: run-tests, baseline, timeout, budget, unit, scope:issue-specific, pwsh-not-required, TL2
# T4: rtb_timeout_settle_into <idx> <reserve> at its boundaries. The limit is the stage's whole
# budget (600-45-reserve-2: branch 403 s, base 553 s), derived from RTB_BUDGET_TOTAL and never from
# elapsed time; only a completed measurement above it settles as exceeds-budget.
# One assertion function per case; the entrypoint wraps each in case markers.

# EB_SETTLE — eb_settle <secs|-> <term|-|EMPTY> <reserve>: one call on index 3 (APPLIED_OUT=777 before);
# prints `SET <s>|<t>|<r> -> <out> <why> applied=<a>` and `LIM <s>|<t>|<r> -> <limit>`.
EB_SETTLE='eb_settle() {
  RTB_TIMEOUT_LEDGER=(); RTB_TIMEOUT_LEDGER_TERM=()
  [ "$1" = - ] || RTB_TIMEOUT_LEDGER[3]="$1"
  [ "$2" = - ] || RTB_TIMEOUT_LEDGER_TERM[3]="$2"
  [ "$2" != EMPTY ] || RTB_TIMEOUT_LEDGER_TERM[3]=""
  RTB_TIMEOUT_APPLIED_OUT=777 RTB_TIMEOUT_SETTLE_OUT=unset RTB_TIMEOUT_SETTLE_WHY=unset RTB_TIMEOUT_SETTLE_LIMIT=unset
  rtb_timeout_settle_into 3 "$3"
  printf "SET %s|%s|%s -> %s %s applied=%s\n" "$1" "$2" "$3" "$RTB_TIMEOUT_SETTLE_OUT" "$RTB_TIMEOUT_SETTLE_WHY" "$RTB_TIMEOUT_APPLIED_OUT"
  printf "LIM %s|%s|%s -> %s\n" "$1" "$2" "$3" "$RTB_TIMEOUT_SETTLE_LIMIT"
}; '

eb_unit_probe() {
  eb_drive "$TMPROOT/c-unit" "$EB_SETTLE"'
for r in 150 0; do
  for s in 403 404 553 554; do eb_settle "$s" completed "$r"; done
done
eb_settle 9999 timeout 150
eb_settle 9999 timeout 0
eb_settle 5 "?" 150
eb_settle 5 unrunnable 0
eb_settle 5 unsupported 0
eb_settle 5 EMPTY 150
eb_settle - - 150
eb_settle - - 0'
}

# eb_set <prefix> — the SET line for <secs>|<term>|<reserve>.
eb_set() { eb_line "SET $1 -> "; }

eb_unit_branch_limit() {
  eb_ck "reserve 150 (branch): 403 s completed is within the 403 s limit" \
    "SET 403|completed|150 -> budget-exhausted within-limit applied=777" "$(eb_set '403|completed|150')"
  eb_ck "reserve 150 (branch): 404 s completed exceeds the 403 s limit" \
    "exceeds-budget" "$(eb_set '404|completed|150' | awk '{ print $4 }')"
  eb_ck "reserve 150 (branch): RTB_TIMEOUT_SETTLE_LIMIT is 403" "LIM 404|completed|150 -> 403" "$(eb_line 'LIM 404|completed|150 -> ')"
}

eb_unit_base_limit() {
  eb_ck "reserve 0 (base): 553 s completed is within the 553 s limit" \
    "SET 553|completed|0 -> budget-exhausted within-limit applied=777" "$(eb_set '553|completed|0')"
  eb_ck "reserve 0 (base): 554 s completed exceeds the 553 s limit" \
    "exceeds-budget" "$(eb_set '554|completed|0' | awk '{ print $4 }')"
  eb_ck "reserve 150: 553 s completed exceeds the branch limit" \
    "exceeds-budget" "$(eb_set '553|completed|150' | awk '{ print $4 }')"
  eb_ck "reserve 0 (base): RTB_TIMEOUT_SETTLE_LIMIT is 553" "LIM 554|completed|0 -> 553" "$(eb_line 'LIM 554|completed|0 -> ')"
}

eb_unit_not_completed() {
  eb_ck "a timeout row stays budget-exhausted however long (branch)" \
    "SET 9999|timeout|150 -> budget-exhausted not-completed:timeout applied=777" "$(eb_set '9999|timeout|150')"
  eb_ck "a timeout row stays budget-exhausted however long (base)" \
    "SET 9999|timeout|0 -> budget-exhausted not-completed:timeout applied=777" "$(eb_set '9999|timeout|0')"
  eb_ck "a legacy ? termination is not completed" \
    "SET 5|?|150 -> budget-exhausted not-completed:? applied=777" "$(eb_set '5|?|150')"
  eb_ck "unrunnable is not completed" \
    "SET 5|unrunnable|0 -> budget-exhausted not-completed:unrunnable applied=777" "$(eb_set '5|unrunnable|0')"
  eb_ck "unsupported is not completed" \
    "SET 5|unsupported|0 -> budget-exhausted not-completed:unsupported applied=777" "$(eb_set '5|unsupported|0')"
  eb_ck "an empty termination is not completed" \
    "SET 5|EMPTY|150 -> budget-exhausted not-completed: applied=777" "$(eb_set '5|EMPTY|150')"
}

eb_unit_unmeasured() {
  eb_ck "no measurement: unmeasured (branch)" "SET -|-|150 -> budget-exhausted unmeasured applied=777" "$(eb_set '-|-|150')"
  eb_ck "no measurement: unmeasured (base)" "SET -|-|0 -> budget-exhausted unmeasured applied=777" "$(eb_set '-|-|0')"
}

# The limit follows the RTB_BUDGET_TOTAL seam: 300 gives branch 103 s and base 253 s; 60 leaves no
# slice at all (limit 0), so any completed second exceeds it.
eb_unit_total_seam() {
  eb_drive "$TMPROOT/c-unit-300" "$EB_SETTLE"'
eb_settle 103 completed 150; eb_settle 104 completed 150; eb_settle 253 completed 0; eb_settle 254 completed 0' RTB_BUDGET_TOTAL=300
  eb_ck "total 300, reserve 150: 103 s is within the limit" \
    "SET 103|completed|150 -> budget-exhausted within-limit applied=777" "$(eb_set '103|completed|150')"
  eb_ck "total 300, reserve 150: 104 s exceeds it" "exceeds-budget" "$(eb_set '104|completed|150' | awk '{ print $4 }')"
  eb_ck "total 300, reserve 0: 253 s is within the limit" \
    "SET 253|completed|0 -> budget-exhausted within-limit applied=777" "$(eb_set '253|completed|0')"
  eb_ck "total 300, reserve 0: 254 s exceeds it" "exceeds-budget" "$(eb_set '254|completed|0' | awk '{ print $4 }')"
  eb_drive "$TMPROOT/c-unit-60" "$EB_SETTLE"'eb_settle 1 completed 0; eb_settle 1 timeout 0' RTB_BUDGET_TOTAL=60
  eb_ck "total 60 (limit 0): 1 s completed exceeds it" "exceeds-budget" "$(eb_set '1|completed|0' | awk '{ print $4 }')"
  eb_ck "total 60: a timeout row is still not completed" \
    "SET 1|timeout|0 -> budget-exhausted not-completed:timeout applied=777" "$(eb_set '1|timeout|0')"
}

eb_unit_applied_kept() {
  eb_ck "the helper leaves RTB_TIMEOUT_APPLIED_OUT as it was (exceeds)" \
    "applied=777" "$(eb_set '404|completed|150' | awk '{ print $NF }')"
}
