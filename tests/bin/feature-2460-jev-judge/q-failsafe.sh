#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, failsafe, owner-marker, superseded, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# `failsafe` writes S0 through the owner marker, never logs a decision, and never overwrites
# a newer ticket's result.

echo "=== jev-judge failsafe ==="
need_mod bin/workflow/jev-judge || return 0

case_begin "jj-failsafe-no-owner" "bin/workflow/jev-judge"
jj_fx fs-fresh
jj failsafe --session "$SID" --point complexity-judge --stage write-code --ticket -
check "failsafe: exit 0" "0" "$JJ_RC"
check "failsafe: RESULT=ok" "ok" "$(kv RESULT)"
check "failsafe: SIGNALS_CSV=S0-undecidable" "S0-undecidable" "$(kv SIGNALS_CSV)"
check "failsafe: SETTLE=ok" "ok" "$(kv SETTLE)"
check "failsafe: fixed write-code file is S0" "S0-undecidable" "$(fixed_csv write-code)"
check "failsafe: owner id is failsafe-<hex>" "1" \
  "$(pb json-get "$(ctl write-code-signals-owner.json)" owner_id | grep -Ec '^"failsafe-[0-9a-f]+"$')"
check "failsafe: no decision log written" "0" "$(log_count)"
check "derive --signals S0 for write_code: high / opus" "level=high|model=opus" \
  "$(bash "$RWT" 30 node "$DERIVE" --stage write_code --signals S0-undecidable 2>/dev/null | tr -d '\r' | paste -sd'|' -)"
case_end

case_begin "jj-failsafe-loses-to-newer" "bin/workflow/jev-judge"
jj_fx fs-newer
mock_p 0.01
jj_query complexity
TA="$TICKET"
jj_query complexity
TB="$TICKET"
jj finalize --session "$SID" --ticket "$TB"
BEFORE="$(pb sha "$(ctl complexity-signals.txt)")"
jj failsafe --session "$SID" --point complexity-judge --stage complexity --ticket "$TA"
check "failsafe for an older ticket: SETTLE=superseded" "superseded" "$(kv SETTLE)"
check "failsafe for an older ticket: SIGNALS_CSV=-" "-" "$(kv SIGNALS_CSV)"
check "failsafe for an older ticket: fixed file untouched" "$BEFORE" "$(pb sha "$(ctl complexity-signals.txt)")"
check "failsafe for an older ticket: owner stays B" "\"$TB\"" "$(pb json-get "$(ctl complexity-signals-owner.json)" owner_id)"
case_end
