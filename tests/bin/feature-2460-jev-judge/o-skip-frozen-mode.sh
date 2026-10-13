#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge, bin/workflow/lib/jev-skip-adapter.js, hooks/lib/jev/two-stage/finalize.js
# Tags: TL2, bin, jev, two-stage, skip-gate, frozen-policy, shadow-mode, replay, exit-4, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# the skip points follow the policy frozen into the ticket at query time (mode, threshold,
# short_circuit_answer, record_decision), through finalize, re-run, sweep replay and orphan
# records; only a removed stage or point invalidates a ticket; the exit-4 error shapes.

echo "=== jev-judge: skip frozen policy ==="
need_mod bin/workflow/jev-judge || return 0
need_mod bin/workflow/lib/jev-skip-adapter.js || return 0
. "$JJ_DIR/_skip-lib.sh"

# sp_fin <entry-json>: in-process finalize of $TICKET with a finalize-time entry.
sp_fin() { sp finalize "{\"sid\":\"$SID\",\"ticket\":\"$TICKET\",\"entry\":$1}"; }
n_dec() { sk_n_rec "$TICKET" decision; }
is_ticket() { printf '%s' "$1" | grep -Ec '^[0-9a-f]{16}$'; }
err_shape() { printf '%s|%s|%s' "$(kv RESULT)" "$(kv REASON)" "$(out_lines)"; }
# Frozen at query: production, a non-default threshold and no short circuit. The shipped
# registry (stage 4: shadow, 0.9/0.7, short circuit false) differs in every field.
FROZEN='"confidence_threshold_by_answer":{"true":0.6,"false":0.6},"short_circuit_answer":null'
FROZEN_V='"production"|{"true":0.6,"false":0.6}|null'
frozen_view() { lq "$TICKET" 'r ? [JSON.stringify(r.mode), JSON.stringify(r.threshold), String(r.short_circuit_answer)].join("|") : "no-record"'; }

case_begin "jj-skip-frozen-shadow-mode" "hooks/lib/jev/two-stage/finalize.js"
sk_fx o-shadow detail
mock_p 0.99
sk_query detail '"mode":"shadow"'
check "detail-skip queried as shadow, p=0.99: both keys delegated" "$(keyset "$K1,$K2")" "$(keyset "$(kv DELEGATED)")"
sk_answer "$(sk_line true false)"
sp_fin '{"mode":"production"}'
check "finalized with a production entry: MODE=shadow (frozen)" "shadow" "$(kv MODE)"
check "finalized with a production entry: ADOPTED=llm, SKIP from the subagent (false)" "llm|false" "$(kv ADOPTED)|$(kv SKIP)"
check "decision record mode shadow" '"shadow"' "$(lq "$TICKET" 'r && JSON.stringify(r.mode)')"
check "Jev p=0.99 not adopted: skip_judgment follows the subagent" "$(sk_conds true false)|subagent" \
  "$(sk_sj_conds detail)|$(sjq detail 'sj && sj.judgment_source')"
case_end

case_begin "jj-skip-frozen-record-decision" "hooks/lib/jev/two-stage/finalize.js"
sk_fx o-jev-onoff detail
mock_p 0.95; sk_query detail
sk_fin JEV=off
check "JEV=on at query, off at finalize: RESULT=ok" "0|ok" "$JJ_RC|$(kv RESULT)"
check "JEV=on at query, off at finalize: one decision record (frozen record_decision)" "1" "$(n_dec)"
sk_fx o-jev-offon detail
mock_p 0.95; sk_query detail "" "" JEV=off
check "JEV=off at query: a ticket is still issued" "1" "$(is_ticket "$TICKET")"
sk_fin JEV=on
check "JEV=off at query, on at finalize: RESULT=ok" "0|ok" "$JJ_RC|$(kv RESULT)"
check "JEV=off at query, on at finalize: no decision record" "0|0" "$(n_dec)|$(log_count)"
case_end

case_begin "jj-skip-frozen-replay-after-registry-change" "hooks/lib/jev/two-stage/replay.js"
for mode in a b; do
  sk_fx "o-swap-$mode" detail
  mock_p 0.65
  sk_query detail "$FROZEN"
  check "swap $mode: frozen 0.6 adopts p=0.65 (the shipped 0.9 would hold)" "final" "$(kv RESULT)"
  sk_crash after-wal
  check "swap $mode: stopped after the write-ahead" "99" "$SP_RC"
  if [ "$mode" = "a" ]; then
    sk_fin
    check "swap a: re-run under the shipped registry: MODE=production (frozen), SKIP=true" "0|production|true" \
      "$JJ_RC|$(kv MODE)|$(kv SKIP)"
  else
    sk_sweep
  fi
  check "swap $mode: decision record keeps mode/threshold/short_circuit_answer of the query" "$FROZEN_V" "$(frozen_view)"
  check "swap $mode: detail skipped" "skipped" "$(sk_status detail)"
done
sk_fx o-orphan detail
mock_p 0.65
sk_query detail "$FROZEN"
sk_sweep
check "orphan (never finalized): finalize-absent record carries the ticket's mode" '1|"production"' \
  "$(lq "$TICKET" 'recs.filter(x=>x.fallback_reason==="finalize-absent").length+"|"+JSON.stringify((recs.find(x=>x.fallback_reason==="finalize-absent")||{}).mode)')"
check "orphan: detail untouched" "pending|0" "$(sk_status detail)|$(sk_events detail)"
case_end

case_begin "jj-skip-frozen-ticket-invalid-only-on-removal" "hooks/lib/jev/two-stage/finalize.js"
sk_fx o-inv-thr detail
mock_p 0.95; sk_query detail
sp_fin '{"mode":"shadow","confidence_threshold_by_answer":{"true":0.99,"false":0.99},"required_sections":["intent"]}'
check "finalize entry with another mode/threshold/sections: not invalid, RESULT=ok" "ok|production" "$(kv RESULT)|$(kv MODE)"
sk_fx o-inv-stage detail
mock_p 0.95; sk_query detail
sp_fin '{"mode":"production","stages":["complexity"]}'
check "stage outline removed from detail-skip's stages: ticket-invalid, two lines" "error|ticket-invalid|2" "$(err_shape)"
check "stage removed: nothing recorded, detail pending" "0|0|pending" "$(n_dec)|$(sk_events detail)|$(sk_status detail)"
sk_fx o-inv-point detail
mock_p 0.95; sk_query detail
sp_fin '{"__removed__":true}'
check "point removed from the registry: ticket-invalid, two lines" "error|ticket-invalid|2" "$(err_shape)"
check "point removed: nothing recorded" "0|0" "$(n_dec)|$(sk_events detail)"
case_end

case_begin "jj-skip-finalize-exit-4" "bin/workflow/jev-judge"
sk_fx o-missing detail
TICKET="$SK_OTHER_TICKET"; sk_fin
check "unknown ticket: exit 4, ticket-missing, exactly two lines" "4|error|ticket-missing|2" "$JJ_RC|$(err_shape)"
check "unknown ticket: nothing logged, MS untouched" "0|absent" "$(log_count)|$(ms_sha detail)"
sk_fx o-inprog detail
mock_p 0.95; sk_query detail
TF="$(ticket_file "$TICKET")"
mv "$TF" "$(dirname "$TF")/$TICKET.claimed-$(live_pid)"
sk_fin
check "live fresh claim: exit 4, in-progress, exactly two lines" "4|error|in-progress|2" "$JJ_RC|$(err_shape)"
check "in-progress: no decision record, detail pending" "0|pending" "$(n_dec)|$(sk_status detail)"
sk_fx o-tamper detail
mock_p 0.95; sk_query detail
TF="$(ticket_file "$TICKET")"
pb json-set "$(np "$TF")" threshold __delete__ > /dev/null
sk_fin
check "ticket missing a frozen field: exit 4, ticket-invalid" "4|error|ticket-invalid|2" "$JJ_RC|$(err_shape)"
case_end
