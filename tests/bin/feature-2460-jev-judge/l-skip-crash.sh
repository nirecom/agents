#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge, bin/workflow/lib/jev-skip-adapter.js, hooks/lib/jev/two-stage/replay.js
# Tags: TL2, bin, jev, two-stage, skip-gate, crash-injection, write-ahead, replay, idempotency, orphan, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# detail-skip half of the stop-at-every-boundary matrix. A finalize stopped after the
# write-ahead is finished by a CLI re-run or a sweep with exactly the uncrashed outcome, and
# a stop between the judgment write and the advance is resumed without a second write.

echo "=== jev-judge: skip crash consistency ==="
need_mod bin/workflow/jev-judge || return 0
need_mod bin/workflow/lib/jev-skip-adapter.js || return 0
. "$JJ_DIR/_skip-lib.sh"

SK_BOUNDS="after-wal after-append after-settle after-done"
SK_SIG='r ? JSON.stringify([r.adopted, r.final, r.agreement_by_signal, r.short_circuited, r.unjudged_keys, r.mode]) : "no-record"'

# scen <jev|sc|llm>: mock + detail-skip query (+ the subagent answer for llm).
#   jev: every key p=0.95 -> SKIP=true by Jev. sc: K1 p=0.2 short-circuits -> SKIP=false.
#   llm: every key delegated, the subagent answers true/true -> SKIP=true.
scen() {
  case "$1" in
    jev) mock_p 0.95; sk_query detail ;;
    sc) mock_p 0.5 "$K1" 0.2; sk_query detail ;;
    llm) mock_p 0.5; sk_query detail; sk_answer "$(sk_line true true)" ;;
  esac
}
# norm_out: finalize stdout without path lines and REPLAYED= (a resumed advance may add it).
norm_out() { out_text | grep -v '_FILE=' | grep -v '^REPLAYED=' | sed "s/$TICKET/<ticket>/g"; }
n_absent() { lq "$TICKET" 'recs.filter(x=>x.fallback_reason==="finalize-absent").length'; }
sj_view() { sjq detail "sj && JSON.stringify([sj.conditions, sj.judgment_source, sj.ticket === \"$TICKET\"])"; }

# baseline <scen>: the uncrashed outcome (B_OUT, B_SIG, B_SJ, B_ST) from a fresh fixture.
baseline() {
  sk_fx "ls-base-$1" detail
  scen "$1"
  sk_fin
  check "baseline $1: uncrashed finalize exit 0, RESULT=ok, SETTLE=ok" "0|ok|ok" "$JJ_RC|$(kv RESULT)|$(kv SETTLE)"
  B_OUT="$(norm_out)"; B_SIG="$(lq "$TICKET" "$SK_SIG")"; B_SJ="$(sj_view)"; B_ST="$(sk_status detail)"
}

# verify <label> <a|b>: the recovered state equals the uncrashed one.
verify() {
  check "$1: exactly one decision record" "1" "$(sk_n_rec "$TICKET" decision)"
  check "$1: no settle record, no finalize-absent record" "0|0" "$(sk_n_rec "$TICKET" settle)|$(n_absent)"
  check "$1: decision record content equals the uncrashed run" "$B_SIG" "$(lq "$TICKET" "$SK_SIG")"
  check "$1: skip_judgment conditions/source equal, ticket recorded" "$B_SJ" "$(sj_view)"
  check "$1: skip_judgment written once" "1" "$(sk_events detail)"
  check "$1: detail status equals the uncrashed run (no fail-safe rewrite)" "$B_ST" "$(sk_status detail)"
  check "$1: MS owner is this ticket" "\"$TICKET\"" "$(ms_get detail owner_id)"
  check "$1: done marker present, claims and jev-sources gone" "1|0|0" \
    "$([ -n "$(sk_done "$TICKET")" ] && echo 1 || echo 0)|$(sk_claims)|$(sk_sources "$TICKET")"
  if [ "$2" = "a" ]; then
    check "$1: re-run exit 0" "0" "$JJ_RC"
    check "$1: re-run stdout equals the uncrashed stdout" "$B_OUT" "$(norm_out)"
  fi
}

# crash_then <scen> <boundary> <a|b>
crash_then() {
  sk_fx "ls-$1-$2-$3" detail
  scen "$1"
  sk_crash "$2"
  check "$1/$2: probe stopped at the boundary (exit 99)" "99" "$SP_RC"
  if [ "$3" = "a" ]; then
    sk_fin
  else
    sk_sweep
    check "$1/$2: sweep replay ran" "0|1" "$SP_RC|$(grep -c '^SWEPT=1' "$OUT")"
  fi
  verify "$1/$2/$3" "$3"
}

case_begin "jj-skip-crash-jev-true" "hooks/lib/jev/two-stage/replay.js"
baseline jev
check "baseline jev: SKIP=true, ADOPTED=jev, detail skipped" "true|jev|skipped" "$(kv SKIP)|$(kv ADOPTED)|$B_ST"
for b in $SK_BOUNDS; do crash_then jev "$b" a; crash_then jev "$b" b; done
case_end

case_begin "jj-skip-crash-short-circuit" "hooks/lib/jev/two-stage/replay.js"
baseline sc
check "baseline sc: SKIP=false, detail pending, K2 filled false" "false|pending|$(sk_conds false false)" \
  "$(kv SKIP)|$B_ST|$(sk_sj_conds detail)"
for b in $SK_BOUNDS; do crash_then sc "$b" a; crash_then sc "$b" b; done
case_end

case_begin "jj-skip-crash-all-delegated" "hooks/lib/jev/two-stage/replay.js"
baseline llm
check "baseline llm: SKIP=true, ADOPTED=llm" "true|llm" "$(kv SKIP)|$(kv ADOPTED)"
for b in $SK_BOUNDS; do crash_then llm "$b" a; crash_then llm "$b" b; done
case_end

case_begin "jj-skip-crash-between-write-and-advance" "bin/workflow/record-skip-judgment"
for mode in a b; do
  sk_fx "ls-wa-$mode" detail
  mock_p 0.95; sk_query detail
  sk_crash after-append
  check "write/advance $mode: stopped after the decision append" "99" "$SP_RC"
  sq record "$SID" detail "$(sk_conds true true)" jev "$TICKET" > /dev/null
  check "write/advance $mode: judgment written, detail still pending" "1|pending" "$(sk_events detail)|$(sk_status detail)"
  if [ "$mode" = "a" ]; then
    sk_fin
    check "write/advance a: stdout SKIP=true, SETTLE=ok, REPLAYED=1" "true|ok|1" \
      "$(kv SKIP)|$(kv SETTLE)|$(grep -c '^REPLAYED=1' "$OUT")"
  else
    sk_sweep
  fi
  check "write/advance $mode: detail advanced to skipped" "skipped" "$(sk_status detail)"
  check "write/advance $mode: skip_judgment not rewritten (one event)" "1" "$(sk_events detail)"
  check "write/advance $mode: no settle record" "0" "$(sk_n_rec "$TICKET" settle)"
done
case_end

case_begin "jj-skip-crash-claim-only-before-wal" "hooks/lib/jev/two-stage/replay.js"
sk_fx ls-claim-rerun detail
mock_p 0.95; sk_query detail
TF="$(ticket_file "$TICKET")"
mv "$TF" "$(dirname "$TF")/$TICKET.claimed-999999"
sk_fin
check "claim without write-ahead, re-run: takes over, RESULT=ok, SKIP=true" "0|ok|true" "$JJ_RC|$(kv RESULT)|$(kv SKIP)"
check "claim without write-ahead, re-run: one decision, no finalize-absent" "1|0" "$(sk_n_rec "$TICKET" decision)|$(n_absent)"
check "claim without write-ahead, re-run: detail skipped" "skipped" "$(sk_status detail)"
sk_fx ls-claim-sweep detail
mock_p 0.95; sk_query detail
TF="$(ticket_file "$TICKET")"
mv "$TF" "$(dirname "$TF")/$TICKET.claimed-999999"
sk_sweep
check "claim without write-ahead, sweep: one finalize-absent record" "1" "$(n_absent)"
check "claim without write-ahead, sweep: downstream untouched" "0|pending" "$(sk_events detail)|$(sk_status detail)"
check "claim without write-ahead, sweep: finalize-absent mode is the ticket's" '"production"' \
  "$(lq "$TICKET" 'JSON.stringify((recs.find(x=>x.fallback_reason==="finalize-absent")||{}).mode)')"
sk_fin
check "after the orphan record: finalize is ticket-missing (exit 4)" "4|ticket-missing" "$JJ_RC|$(kv REASON)"
case_end

case_begin "jj-skip-crash-double-replay" "hooks/lib/jev/two-stage/replay.js"
baseline jev
sk_fx ls-double detail
mock_p 0.95; sk_query detail
sk_crash after-append
sk_fin
LC1="$(log_count)"
sk_sweep
sk_fin
check "re-run then sweep then re-run: log does not grow" "$LC1" "$(log_count)"
verify "double replay" a
check "double replay: the sentinel API key appears in no fixture file" "absent" "$(grep_absent "$SENTINEL_KEY" "$FX")"
check "double replay: the sentinel API key appears in no stderr" "absent" "$(grep_absent "$SENTINEL_KEY" "$ERR_ALL")"
case_end
