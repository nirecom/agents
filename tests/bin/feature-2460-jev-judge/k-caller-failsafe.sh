#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, caller-contract, failsafe, superseded, exit-4, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# the caller side of the shared procedure (JJ-4 / JJ-5) for complexity. An exit-4 finalize
# falls back to `jev-judge failsafe` and its SIGNALS_CSV; a superseded finalize makes the
# caller stop without touching the fixed file, the evaluation record or the level.

echo "=== jev-judge: caller fail-safe and superseded path ==="
need_mod bin/workflow/jev-judge || return 0
need_mod hooks/lib/jev/two-stage/failsafe.js || return 0
. "$JJ_DIR/two-stage-lib.sh"

UNKNOWN_TICKET="0123456789abcdef"
derive_sig() { bash "$RWT" 30 node "$DERIVE" --stage "$1" --signals "$2" 2>/dev/null | tr -d '\r' | paste -sd'|' -; }
record_ce() { bash "$RWT" 30 node "$RECORD_CE" --session "$SID" --signals "$1" 2>/dev/null | tr -d '\r'; }
owner_of() { pb json-get "$(np "$(ctl "$1-signals-owner.json")")" "$2"; }
fsha() { pb sha "$(np "$(ctl "$1")")"; }
err_shape() { printf '%s|%s|%s|%s' "$JJ_RC" "$(kv RESULT)" "$(kv REASON)" "$(out_lines)"; }

case_begin "k-caller-ticket-missing-failsafe" "bin/workflow/jev-judge"
jj_fx k-missing
jj finalize --session "$SID" --ticket "$UNKNOWN_TICKET"
check "finalize of an unknown ticket: exit 4, RESULT=error, ticket-missing, exactly two lines" \
  "4|error|ticket-missing|2" "$(err_shape)"
check "unknown ticket: nothing logged, fixed file untouched" "0|<absent>" "$(log_count)|$(fixed_csv write-code)"
jj failsafe --session "$SID" --point complexity-judge --stage write-code --ticket -
check "JJ-5 failsafe: exit 0, RESULT=ok, SETTLE=ok" "0|ok|ok" "$JJ_RC|$(kv RESULT)|$(kv SETTLE)"
FS_CSV="$(kv SIGNALS_CSV)"
check "JJ-5 failsafe: SIGNALS_CSV=S0-undecidable" "S0-undecidable" "$FS_CSV"
check "JJ-5 failsafe: owner is failsafe-<hex>, state written" "1|\"written\"" \
  "$(owner_of write-code owner_id | grep -Ec '^"failsafe-[0-9a-f]+"$')|$(owner_of write-code state)"
check "caller passes SIGNALS_CSV to derive: high / opus" "level=high|model=opus" "$(derive_sig write_code "$FS_CSV")"
check "failsafe: still no decision record" "0" "$(log_count)"
case_end

case_begin "k-caller-ticket-invalid-and-in-progress" "bin/workflow/jev-judge"
jj_fx k-invalid
mock_p 0.01
ts_query complexity complexity-judge "$F_PRODUCTION"
ts_fin '{"entryPatch":{"complexity-judge":{"stages":["write-code"]}}}'
check "unregistered stage: exit 4 ticket-invalid, two lines" "4|error|ticket-invalid|2" \
  "$TS_RC|$(kv RESULT)|$(kv REASON)|$(out_lines)"
jj_fx k-inprogress
mock_p 0.01
ts_query complexity complexity-judge "$F_PRODUCTION"
TA="$TICKET"; TA_CREATED="$(tk created_ms)"
TF="$(ticket_file "$TA")"
mv "$TF" "$(dirname "$TF")/$TA.claimed-$(live_pid)"
jj failsafe --session "$SID" --point complexity-judge --stage complexity --ticket "$TA"
check "failsafe --ticket A (A unfinalized): SETTLE=ok, S0" "ok|S0-undecidable" "$(kv SETTLE)|$(kv SIGNALS_CSV)"
check "failsafe --ticket A: owner_created_ms is A's query time" "$TA_CREATED" "$(owner_of complexity owner_created_ms)"
check "failsafe --ticket A: fixed file S0" "S0-undecidable" "$(fixed_csv complexity)"
case_end

# Owner tie-break (audit run-0024): failsafe --ticket A takes A's created_ms, and on equal
# created_ms a failsafe- owner is newer than any ticket-id owner. Ticket ids are 16-hex, so
# ffff... sorts after "failsafe-" lexically; both fixed ids must lose to the failsafe.
case_begin "k-caller-failsafe-beats-own-ticket-on-tie" "bin/workflow/jev-judge"
for TID in 0123456789abcdef ffffffffffffffff; do
  jj_fx "k-tie-$TID"
  mock_p 0.01 S2-architecture 0.95
  ts_query complexity complexity-judge "$(f_production_with "\"ticketId\":\"$TID\"")"
  check "$TID: the forced ticket id is used" "$TID" "$TICKET"
  TA_CREATED="$(tk created_ms)"
  ts_fin '{"crashAt":"after-wal"}'
  check "$TID: A stopped after the write-ahead (S2 in the claim)" "99" "$TS_RC"
  CL="$(find "$FX" -name "$TID.claimed-*" 2>/dev/null | head -1)"
  check "$TID: A's claim exists" "yes" "$([ -n "$CL" ] && echo yes || echo no)"
  LIVE="$(dirname "$CL")/$TID.claimed-$(live_pid)"
  mv "$CL" "$LIVE"
  jj finalize --session "$SID" --ticket "$TID"
  check "$TID: finalize while the claim is live: exit 4 in-progress" "4|in-progress" "$JJ_RC|$(kv REASON)"
  jj failsafe --session "$SID" --point complexity-judge --stage complexity --ticket "$TID"
  check "$TID: failsafe --ticket A: SETTLE=ok, S0" "0|ok|S0-undecidable" "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
  check "$TID: owner failsafe-<hex> with A's created_ms" "1|$TA_CREATED" \
    "$(owner_of complexity owner_id | grep -Ec '^"failsafe-[0-9a-f]+"$')|$(owner_of complexity owner_created_ms)"
  FS_OWNER="$(owner_of complexity owner_id | tr -d '"')"
  F_SHA="$(fsha complexity-signals.txt)"
  mv "$LIVE" "$(dirname "$CL")/$TID.claimed-999999"
  sleep 1.1
  tsp sweep "$SID" 1
  check "$TID: sweep replay of A's claim ran" "0" "$TS_RC"
  check "$TID: A superseded by the failsafe owner (newer-owner)" "superseded|newer-owner|$FS_OWNER" \
    "$(lq "$TID" 'recs.filter(x=>x.record_type==="settle").map(x=>[x.settle,x.detail,x.owner].join("|")).join(";")')"
  check "$TID: fixed file byte-identical, still S0-undecidable" "$F_SHA|S0-undecidable" \
    "$(fsha complexity-signals.txt)|$(fixed_csv complexity)"
  check "$TID: owner stays the failsafe" "$FS_OWNER" "$(owner_of complexity owner_id | tr -d '"')"
  jj finalize --session "$SID" --ticket "$TID"
  check "$TID: A's finalize replays SETTLE=superseded, SIGNALS_CSV=-" "0|superseded|-" \
    "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
done
case_end

case_begin "k-caller-superseded-stops" "bin/workflow/jev-judge"
jj_fx k-superseded
mock_p 0.01 S2-architecture 0.95
ts_query complexity complexity-judge "$F_PRODUCTION"
TA="$TICKET"
mock_p 0.01
ts_query complexity complexity-judge "$F_PRODUCTION"
TB="$TICKET"
jj finalize --session "$SID" --ticket "$TB"
check "B finalize: SETTLE=ok, SIGNALS_CSV empty (none)" "0|ok|" "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
B_CSV="$(kv SIGNALS_CSV)"
check "caller B records the evaluation from SIGNALS_CSV" "1" "$(record_ce "$B_CSV" | grep -c '^RECORDED_COMPLEXITY ')"
check "one complexity_evaluation event" "1" "$(tpb ce-count "$SID")"
F_SHA="$(fsha complexity-signals.txt)"; M_SHA="$(fsha complexity-signals-owner.json)"
TICKET="$TA"
ts_fin '{"crashAt":"after-append"}'
check "A stopped after the decision append" "99" "$TS_RC"
jj finalize --session "$SID" --ticket "$TA"
check "A re-run: exit 0, RESULT=ok, SETTLE=superseded" "0|ok|superseded" "$JJ_RC|$(kv RESULT)|$(kv SETTLE)"
check "A re-run: SIGNALS_CSV=-, no SIGNALS_FILE line" "-|<none>" "$(kv SIGNALS_CSV)|$(kv SIGNALS_FILE)"
check "A re-run: settle record newer-owner owned by B" "superseded|newer-owner|$TB" \
  "$(lq "$TA" 'recs.filter(x=>x.record_type==="settle").map(x=>[x.settle,x.detail,x.owner].join("|")).join(";")')"
check "A superseded: fixed file byte-equal to B's" "$F_SHA" "$(fsha complexity-signals.txt)"
check "A superseded: owner marker byte-equal to B's" "$M_SHA" "$(fsha complexity-signals-owner.json)"
check "A superseded: owner id is B" "\"$TB\"" "$(owner_of complexity owner_id)"
check "A superseded: the caller records nothing (event count stays 1)" "1" "$(tpb ce-count "$SID")"
jj finalize --session "$SID" --ticket "$TA"
check "A re-run again: replays SIGNALS_CSV=- from the done marker" "superseded|-" "$(kv SETTLE)|$(kv SIGNALS_CSV)"
check "A re-run again: settle record not duplicated" "1" "$(lq "$TA" 'recs.filter(x=>x.record_type==="settle").length')"
no_secret_leak "k-caller"
case_end
