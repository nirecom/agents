#!/usr/bin/env bash
# Tests: hooks/lib/jev/two-stage/replay.js
# Tags: TL2, bin, jev, two-stage, crash-injection, write-ahead, replay, idempotency, orphan, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# complexity side of the stop-at-every-boundary matrix. A finalize stopped after the
# write-ahead is finished by a CLI re-run or by a sweep with exactly the uncrashed outcome.
# The detail-skip half of the matrix lives in the skip-side fragments (stage 4).

echo "=== jev-judge: crash consistency (complexity) ==="
need_mod bin/workflow/jev-judge || return 0
need_mod hooks/lib/jev/two-stage/finalize.js || return 0
need_mod hooks/lib/jev/two-stage/replay.js || return 0
. "$JJ_DIR/two-stage-lib.sh"

BOUNDARIES="after-wal after-append after-owner-writing after-settle after-done"
SIG_EXPR='r ? JSON.stringify([r.adopted, r.final, r.agreement_by_signal, r.short_circuited, r.unjudged_keys, r.mode]) : "no-record"'

# scen_setup <jev|deleg>: mock + query for one scenario. jev: Jev adopts every key (S2 true,
# the rest false). deleg: every key delegated; the subagent answers S3-security.
scen_setup() {
  if [ "$1" = "jev" ]; then
    mock_p 0.01 S2-architecture 0.95
    ts_query complexity complexity-judge "$F_PRODUCTION"
  else
    mock_p 0.5
    ts_query complexity complexity-judge "$F_PRODUCTION"
    answer_with "SIGNALS: S3-security"
  fi
}
# norm_out: the finalize stdout without path-valued lines, the ticket id masked.
norm_out() { out_text | grep -v '_FILE=' | sed "s/$TICKET/<ticket>/g"; }
n_rec() { lq "$TICKET" "recs.filter(x=>x.record_type===\"$1\").length"; }
n_absent() { lq "$TICKET" 'recs.filter(x=>x.fallback_reason==="finalize-absent").length'; }
owner_view() {
  local m; m="$(ctl complexity-signals-owner.json)"
  if [ -f "$m" ]; then printf '%s|%s' "$(pb json-get "$(np "$m")" owner_id)" "$(pb json-get "$(np "$m")" state)"; else echo "<no-marker>"; fi
}
done_count() { find "$FX" -path '*tickets-done*' -name "$TICKET.json" -type f 2>/dev/null | wc -l | tr -d ' '; }
claim_count() { find "$FX" -name "$TICKET.claimed-*" 2>/dev/null | wc -l | tr -d ' '; }
sweep_now() { sleep 1.1; tsp sweep "$SID" 1; }

# baseline <scenario>: the uncrashed outcome (B_OUT, B_SIG, B_FIXED) from a fresh fixture.
baseline() {
  jj_fx "l-base-$1"
  scen_setup "$1"
  jj finalize --session "$SID" --ticket "$TICKET"
  check "baseline $1: uncrashed finalize RESULT=ok SETTLE=ok" "0|ok|ok" "$JJ_RC|$(kv RESULT)|$(kv SETTLE)"
  B_OUT="$(norm_out)"; B_SIG="$(lq "$TICKET" "$SIG_EXPR")"; B_FIXED="$(fixed_csv complexity)"
}

# verify <label> <a|b>: the recovered state equals the uncrashed one.
verify() {
  check "$1: exactly one decision record" "1" "$(n_rec decision)"
  check "$1: no settle record, no finalize-absent record" "0|0" "$(n_rec settle)|$(n_absent)"
  check "$1: decision record content equals the uncrashed run" "$B_SIG" "$(lq "$TICKET" "$SIG_EXPR")"
  check "$1: fixed file from the write-ahead merged_line (not S0)" "$B_FIXED" "$(fixed_csv complexity)"
  check "$1: owner marker is this ticket, written" "\"$TICKET\"|\"written\"" "$(owner_view)"
  check "$1: done marker present, claim and copies gone" "1|0|0" "$(done_count)|$(claim_count)|$(copy_count)"
  if [ "$2" = "a" ]; then
    check "$1: re-run exit 0, stdout equals the uncrashed stdout" "0" "$JJ_RC"
    check "$1: re-run stdout (SIGNALS_CSV, SETTLE=ok included)" "$B_OUT" "$(norm_out)"
  fi
}

# crash_then <scenario> <boundary> <a|b>
crash_then() {
  jj_fx "l-$1-$2-$3"
  scen_setup "$1"
  ts_fin "{\"crashAt\":\"$2\"}"
  check "$1/$2: probe stopped at the boundary (exit 99)" "99" "$TS_RC"
  if [ "$3" = "a" ]; then
    jj finalize --session "$SID" --ticket "$TICKET"
  else
    sweep_now
    check "$1/$2: sweep replay ran" "0" "$TS_RC"
  fi
  verify "$1/$2/$3" "$3"
}

case_begin "l-crash-jev-adopted-rerun" "hooks/lib/jev/two-stage/replay.js"
baseline jev
check "baseline jev: ADOPTED=jev, SIGNALS_CSV=S2-architecture" "jev|S2-architecture" "$(kv ADOPTED)|$(kv SIGNALS_CSV)"
for b in $BOUNDARIES; do crash_then jev "$b" a; done
case_end

case_begin "l-crash-jev-adopted-sweep" "hooks/lib/jev/two-stage/replay.js"
baseline jev
for b in $BOUNDARIES; do crash_then jev "$b" b; done
case_end

case_begin "l-crash-all-delegated-rerun" "hooks/lib/jev/two-stage/replay.js"
baseline deleg
check "baseline deleg: ADOPTED=llm, SIGNALS_CSV=S3-security" "llm|S3-security" "$(kv ADOPTED)|$(kv SIGNALS_CSV)"
for b in $BOUNDARIES; do crash_then deleg "$b" a; done
case_end

case_begin "l-crash-all-delegated-sweep" "hooks/lib/jev/two-stage/replay.js"
baseline deleg
for b in $BOUNDARIES; do crash_then deleg "$b" b; done
case_end

case_begin "l-crash-answer-changed-after-wal" "hooks/lib/jev/two-stage/replay.js"
baseline deleg
jj_fx l-answer-swap
scen_setup deleg
ts_fin '{"crashAt":"after-wal"}'
answer_with "SIGNALS: S0-undecidable"
jj finalize --session "$SID" --ticket "$TICKET"
check "answer rewritten after the write-ahead: replay keeps the written-ahead result" "$B_OUT" "$(norm_out)"
check "answer rewritten after the write-ahead: fixed file unchanged" "$B_FIXED" "$(fixed_csv complexity)"
case_end

case_begin "l-crash-claim-only-before-wal" "hooks/lib/jev/two-stage/replay.js"
baseline jev
jj_fx l-claim-rerun
scen_setup jev
TF="$(ticket_file "$TICKET")"
mv "$TF" "$(dirname "$TF")/$TICKET.claimed-999999"
jj finalize --session "$SID" --ticket "$TICKET"
check "claim without write-ahead, re-run: takes over and judges again" "0|ok|ok" "$JJ_RC|$(kv RESULT)|$(kv SETTLE)"
check "claim without write-ahead, re-run: same stdout as uncrashed" "$B_OUT" "$(norm_out)"
check "claim without write-ahead, re-run: one decision, no finalize-absent" "1|0" "$(n_rec decision)|$(n_absent)"
jj_fx l-claim-sweep
scen_setup jev
TF="$(ticket_file "$TICKET")"
mv "$TF" "$(dirname "$TF")/$TICKET.claimed-999999"
sweep_now
check "claim without write-ahead, sweep: one finalize-absent record" "1|1" "$(n_rec decision)|$(n_absent)"
check "claim without write-ahead, sweep: downstream untouched" "<absent>|<no-marker>" "$(fixed_csv complexity)|$(owner_view)"
jj finalize --session "$SID" --ticket "$TICKET"
check "after the orphan record: finalize is ticket-missing" "4|ticket-missing" "$JJ_RC|$(kv REASON)"
case_end

case_begin "l-crash-double-replay" "hooks/lib/jev/two-stage/replay.js"
baseline jev
jj_fx l-double
scen_setup jev
ts_fin '{"crashAt":"after-append"}'
jj finalize --session "$SID" --ticket "$TICKET"
LC1="$(log_count)"
sweep_now
jj finalize --session "$SID" --ticket "$TICKET"
check "re-run then sweep then re-run: log does not grow" "$LC1" "$(log_count)"
verify "double replay" a
no_secret_leak "l-crash"
case_end
