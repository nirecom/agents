#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge, bin/workflow/lib/jev-skip-adapter.js, hooks/lib/jev/two-stage/finalize.js
# Tags: TL2, bin, jev, two-stage, skip-gate, superseded, owner-marker, newer-query-wins, failsafe, idempotent, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# skip-side settle ownership. The skip owner marker MS (<target>-skip-owner.json) is taken at
# query time, a newer query or a fail-safe owns it, and an older ticket's finalize, replay or
# done-marker re-output then reports superseded without calling record-skip-judgment.

echo "=== jev-judge: skip superseded ==="
need_mod bin/workflow/jev-judge || return 0
need_mod bin/workflow/lib/jev-skip-adapter.js || return 0
. "$JJ_DIR/_skip-lib.sh"

now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }
# qa_qb <fixture>: query A (every key p=0.95, all true) then B (K1 p=0.05: short circuit false).
# B is made strictly newer by created_ms (sleep), so the newer-owner outcome never rests on
# the lexical order of two random ticket ids; newer_premise asserts that.
qa_qb() {
  sk_fx "$1" detail
  mock_p 0.95; sk_query detail; TA="$TICKET"; TA_CREATED="$(sk_created "$TA")"
  sleep 0.05
  mock_p 0.95 "$K1" 0.05; sk_query detail; TB="$TICKET"
  newer_premise "$1"
  TICKET="$TA"
}
# newer_premise <label>: B's created_ms is strictly greater than A's (TA_CREATED, TB).
newer_premise() {
  local cb; cb="$(sk_created "$TB")"
  check "$1: premise: B queried strictly later than A (created_ms)" "1" \
    "$([ "$cb" -gt "$TA_CREATED" ] 2>/dev/null && echo 1 || echo 0)"
}
# snap: the state that must not move when record-skip-judgment is not called.
snap() { S_MS="$(ms_sha detail)"; S_MT="$(sq state-mtime "$SID")"; S_EV="$(sk_events detail)"; S_ST="$(sk_status detail)"; }
unmoved() {
  check "$1: MS byte-identical" "$S_MS" "$(ms_sha detail)"
  check "$1: state file not rewritten (mtime), events and status unchanged" "$S_MT|$S_EV|$S_ST" \
    "$(sq state-mtime "$SID")|$(sk_events detail)|$(sk_status detail)"
}
superseded_out() {
  check "$1: exit 0, RESULT=ok, SKIP=false, SETTLE=superseded" "0|ok|false|superseded" \
    "$JJ_RC|$(kv RESULT)|$(kv SKIP)|$(kv SETTLE)"
  check "$1: no RECORDED line (record-skip-judgment not called)" "0" "$(grep -c '^RECORDED=' "$OUT")"
}

case_begin "jj-skip-superseded-step-not-pending" "bin/workflow/jev-judge"
for mode in a b; do
  sk_fx "ms-snp-$mode" detail
  mock_p 0.95; sk_query detail
  sk_crash after-append
  check "snp $mode: stopped after the decision append" "99" "$SP_RC"
  sq mark "$SID" detail in_progress > /dev/null
  if [ "$mode" = "a" ]; then
    sk_fin
    check "snp a: RECORDED=superseded relayed" "superseded" "$(kv RECORDED)"
    check "snp a: SKIP=false, SETTLE=superseded" "false|superseded" "$(kv SKIP)|$(kv SETTLE)"
  else
    sk_sweep
  fi
  check "snp $mode: detail stays in_progress, no skip_judgment" "in_progress|0" "$(sk_status detail)|$(sk_events detail)"
  check "snp $mode: one decision and one settle step-not-pending (owner null)" "1|superseded|step-not-pending|" \
    "$(sk_n_rec "$TICKET" decision)|$(sk_settle "$TICKET")"
  sk_fin
  check "snp $mode: replay again: SETTLE=superseded from the done marker" "false|superseded" "$(kv SKIP)|$(kv SETTLE)"
  check "snp $mode: replay again: settle record not duplicated" "1" "$(sk_n_rec "$TICKET" settle)"
done
case_end

case_begin "jj-skip-owner-taken-at-query" "bin/workflow/jev-judge"
sk_fx ms-q detail
mock_p 0.95; sk_query detail; TA="$TICKET"
check "after query A: MS owner is A, version 1" "\"$TA\"|1" "$(ms_get detail owner_id)|$(ms_get detail version)"
TA_CREATED="$(sk_created "$TA")"
check "after query A: MS owner_created_ms is A's query time" "$TA_CREATED" "$(ms_get detail owner_created_ms)"
sleep 0.05
sk_query detail; TB="$TICKET"
newer_premise "owner at query"
check "after query B: MS owner is B (newer query wins at query time)" "\"$TB\"" "$(ms_get detail owner_id)"
check "query of detail-skip leaves outline's MS alone" "absent" "$(ms_get outline owner_id)"
sk_fx ms-q-fail detail
MSP="$(ctl detail-skip-owner.json)"
mkdir -p "$MSP/blocker"
jj query --session "$SID" --point detail-skip --stage outline
check "MS write fails (a directory at the MS path): query exit 3" "3" "$JJ_RC"
check "MS write fails: the ticket is deleted again (no pending ticket)" "0" "$(pending_count)"
check "MS write fails: no TICKET line" "<none>" "$(kv TICKET)"
case_end

case_begin "jj-skip-superseded-newer-owner-unfinalized" "bin/workflow/jev-judge"
qa_qb ms-nu-a
check "A then B queried: MS owner B before anyone finalizes" "\"$TB\"" "$(ms_get detail owner_id)"
snap
sk_fin
superseded_out "A finalize (B unfinalized)"
check "A finalize: settle newer-owner owned by B" "superseded|newer-owner|$TB" "$(sk_settle "$TA")"
unmoved "A finalize (B unfinalized)"
check "A finalize: detail stays pending" "pending" "$(sk_status detail)"
TICKET="$TB"; sk_fin
check "positive control, B finalize: SETTLE=ok, SKIP=false, record-skip-judgment called" "ok|false|1" \
  "$(kv SETTLE)|$(kv SKIP)|$(grep -c '^RECORDED=detail all_conditions_met=false' "$OUT")"
check "B finalize: judgment recorded with B's ticket, detail pending" "1|$TB|pending" \
  "$(sk_events detail)|$(sjq detail 'sj && sj.ticket')|$(sk_status detail)"
check "B finalize: no settle record for B" "0" "$(sk_n_rec "$TB" settle)"
qa_qb ms-nu-b
sk_crash after-append
snap
sk_sweep
check "A sweep-replayed (B unfinalized): settle newer-owner owned by B" "superseded|newer-owner|$TB" "$(sk_settle "$TA")"
unmoved "A sweep-replayed (B unfinalized)"
check "B never finalized: detail stays pending, never skipped" "pending|0" "$(sk_status detail)|$(sk_events detail)"
check "B never finalized: the sweep records B as finalize-absent" "1" \
  "$(lq "$TB" 'recs.filter(x=>x.fallback_reason==="finalize-absent").length')"
case_end

case_begin "jj-skip-superseded-newer-owner-finalized" "bin/workflow/jev-judge"
for mode in a b; do
  qa_qb "ms-nf-$mode"
  TICKET="$TB"; sk_fin
  check "nf $mode: B finalize SKIP=false SETTLE=ok, detail pending" "false|ok|pending" \
    "$(kv SKIP)|$(kv SETTLE)|$(sk_status detail)"
  B_SJ="$(sjq detail 'sj && JSON.stringify(sj)')"
  TICKET="$TA"; sk_crash after-append
  check "nf $mode: A stopped after the decision append" "99" "$SP_RC"
  snap
  if [ "$mode" = "a" ]; then sk_fin; superseded_out "nf a: A re-run"; else sk_sweep; fi
  check "nf $mode: settle newer-owner owned by B (one record)" "superseded|newer-owner|$TB" "$(sk_settle "$TA")"
  unmoved "nf $mode"
  check "nf $mode: skip_judgment is still B's" "$B_SJ" "$(sjq detail 'sj && JSON.stringify(sj)')"
done
case_end

case_begin "jj-skip-failsafe-takes-owner" "bin/workflow/jev-judge"
# Same created_ms (the failsafe takes A's query time): a failsafe- owner outranks a ticket
# owner by kind, never by lexical order. ffff... sorts after "failsafe-", 0123... before it,
# so an order-only comparison fails one of the two ids. The ids are pinned, not random.
for FIX_ID in 0123456789abcdef ffffffffffffffff; do
  sk_fx "ms-fs-$FIX_ID" detail
  mock_p 0.95; sk_query detail "" "\"ticketId\":\"$FIX_ID\""; TA="$TICKET"; TA_CREATED="$(sk_created "$TA")"
  check "$FIX_ID: the query issued the pinned ticket id" "$FIX_ID" "$TA"
  sk_crash after-append
  check "$FIX_ID: A (all true, SKIP=true written ahead) stopped after the decision append" "99" "$SP_RC"
  LC0="$(log_count)"
  jj failsafe --session "$SID" --point detail-skip --stage outline --ticket "$TA"
  check "$FIX_ID: failsafe --ticket A: exit 0, RESULT=ok, SKIP=false, SETTLE=ok" "0|ok|false|ok" \
    "$JJ_RC|$(kv RESULT)|$(kv SKIP)|$(kv SETTLE)"
  FS_OWNER="$(ms_get detail owner_id | tr -d '"')"
  check "$FIX_ID: failsafe: MS owner is failsafe-<hex>" "1" "$(printf '%s' "$FS_OWNER" | grep -Ec '^failsafe-[0-9a-f]+$')"
  check "$FIX_ID: failsafe: MS owner_created_ms equals A's created_ms" "$TA_CREATED" "$(ms_get detail owner_created_ms)"
  check "$FIX_ID: failsafe: no decision-log record, no skip_judgment, detail pending" "$LC0|0|pending" \
    "$(log_count)|$(sk_events detail)|$(sk_status detail)"
  snap
  sk_sweep
  check "$FIX_ID: A sweep-replayed after the failsafe: superseded newer-owner owned by the failsafe" \
    "superseded|newer-owner|$FS_OWNER" "$(sk_settle "$TA")"
  unmoved "$FIX_ID: A after the failsafe"
  check "$FIX_ID: A after the failsafe: detail pending, not skipped, no judgment" "pending|0" \
    "$(sk_status detail)|$(sk_events detail)"
  TICKET="$TA"; sk_fin
  check "$FIX_ID: A re-run after the replay: SETTLE=superseded, SKIP=false, no RECORDED" "superseded|false|0" \
    "$(kv SETTLE)|$(kv SKIP)|$(grep -c '^RECORDED=' "$OUT")"
done
case_end

case_begin "jj-skip-failsafe-superseded-by-newer-query" "bin/workflow/jev-judge"
qa_qb ms-fs-b
snap
jj failsafe --session "$SID" --point detail-skip --stage outline --ticket "$TA"
check "failsafe --ticket A after query B: SETTLE=superseded, SKIP=false" "0|ok|false|superseded" \
  "$JJ_RC|$(kv RESULT)|$(kv SKIP)|$(kv SETTLE)"
check "failsafe superseded: no RECORDED line" "0" "$(grep -c '^RECORDED=' "$OUT")"
unmoved "failsafe superseded"
check "failsafe superseded: MS owner still B" "\"$TB\"" "$(ms_get detail owner_id)"
case_end

case_begin "jj-skip-failsafe-no-ticket" "bin/workflow/jev-judge"
sk_fx ms-fs-none outline
T0="$(now_ms)"
jj failsafe --session "$SID" --point outline-skip --stage outline --ticket -
T1="$(now_ms)"
check "failsafe outline-skip --ticket -: RESULT=ok, SKIP=false, SETTLE=ok" "0|ok|false|ok" \
  "$JJ_RC|$(kv RESULT)|$(kv SKIP)|$(kv SETTLE)"
check "failsafe --ticket -: outline MS owner failsafe-<hex>" "1" \
  "$(ms_get outline owner_id | tr -d '"' | grep -Ec '^failsafe-[0-9a-f]+$')"
FS_C="$(ms_get outline owner_created_ms)"
check "failsafe --ticket -: owner_created_ms is about now" "1" \
  "$([ "$FS_C" -ge "$T0" ] 2>/dev/null && [ "$FS_C" -le "$T1" ] 2>/dev/null && echo 1 || echo 0)"
check "failsafe --ticket -: outline pending, no judgment, no decision log" "pending|0|0" \
  "$(sk_status outline)|$(sk_events outline)|$(log_count)"
case_end

case_begin "jj-skip-done-marker-recheck-owner" "bin/workflow/jev-judge"
sk_fx ms-done detail
mock_p 0.5 "$K1" 0.05; sk_query detail; TA="$TICKET"; TA_CREATED="$(sk_created "$TA")"
sk_fin
check "A finalize: SETTLE=ok, SKIP=false, detail pending" "ok|false|pending" "$(kv SETTLE)|$(kv SKIP)|$(sk_status detail)"
A_DONE="$(sk_done_sha "$TA")"
sleep 0.05
mock_p 0.95; sk_query detail; TB="$TICKET"
newer_premise "done-marker recheck"
sk_fin
check "B finalize: SETTLE=ok, SKIP=true, MS owner B" "ok|true|\"$TB\"" "$(kv SETTLE)|$(kv SKIP)|$(ms_get detail owner_id)"
snap
TICKET="$TA"; sk_fin
check "A re-run after B: exit 0, SETTLE=superseded, SKIP=false (MS re-checked)" "0|superseded|false" \
  "$JJ_RC|$(kv SETTLE)|$(kv SKIP)"
check "A re-run after B: done marker bytes unchanged" "$A_DONE" "$(sk_done_sha "$TA")"
unmoved "A re-run after B"
TICKET="$TB"; sk_fin
check "B re-run: recorded stdout SETTLE=ok, SKIP=true" "ok|true" "$(kv SETTLE)|$(kv SKIP)"
case_end

# A skip is authorized only while the stage sources are still the bytes fingerprinted at query
# time: a source edited, removed or added before finalize settles as source-changed, no skip.
# source_changed_out <label> <target>
source_changed_out() {
  superseded_out "$1"
  check "$1: one settle record source-changed (owner null), $2 pending" "superseded|source-changed||pending" \
    "$(sk_settle "$TICKET")|$(sk_status "$2")"
}
all_met() { sjq "$1" 'sj ? String(sj.all_conditions_met) : "no-judgment"'; }

case_begin "jj-skip-source-changed" "bin/workflow/jev-judge"
sk_fx sc-edit detail
mock_p 0.95; sk_query detail
printf '# Outline\n\nTwo approaches are open now.\n' > "$FX/plans/$SID-outline.md"
sk_fin
source_changed_out "outline edited after the query" detail
check "outline edited: no skip_judgment written" "0" "$(sk_events detail)"
sk_fin
check "outline edited, re-run: same outcome from the done marker, settle record not duplicated" "superseded|false|1" \
  "$(kv SETTLE)|$(kv SKIP)|$(sk_n_rec "$TICKET" settle)"
sk_fx sc-vanish detail
mock_p 0.95; sk_query detail
rm -f "$FX/plans/$SID-context.md"
sk_fin
source_changed_out "context.md removed after the query" detail
sk_fx sc-appear outline
mock_p 0.95; sk_query outline
printf '# Outline\n\nWritten while the judge was out.\n' > "$FX/plans/$SID-outline.md"
sk_fin
source_changed_out "outline.md created after the query" outline
sk_fx sc-same-bytes detail
mock_p 0.95; sk_query detail
cp "$FX/plans/$SID-outline.md" "$FX/outline.keep"
sleep 1.1
cp "$FX/outline.keep" "$FX/plans/$SID-outline.md"
sk_fin
check "control, outline rewritten with the same bytes (newer mtime): SETTLE=ok, SKIP=true, skipped" "ok|true|skipped" \
  "$(kv SETTLE)|$(kv SKIP)|$(sk_status detail)"
sk_fx sc-no-skip detail
mock_p 0.95 "$K1" 0.05; sk_query detail
printf '# Outline\n\nTwo approaches are open now.\n' > "$FX/plans/$SID-outline.md"
sk_fin
check "a judgment that authorizes no skip is recorded whatever the sources: SETTLE=ok, SKIP=false" "ok|false|false|pending" \
  "$(kv SETTLE)|$(kv SKIP)|$(all_met detail)|$(sk_status detail)"
case_end

case_begin "jj-skip-source-changed-standing-judgment" "bin/workflow/jev-judge"
sk_fx sc-standing detail
mock_p 0.95; sk_query detail
sq record "$SID" detail "$(sk_conds true true)" jev "$TICKET" > /dev/null
check "premise: this ticket's all-true judgment stands, detail pending" "true|pending" "$(all_met detail)|$(sk_status detail)"
printf '# Outline\n\nTwo approaches are open now.\n' > "$FX/plans/$SID-outline.md"
sk_fin
source_changed_out "standing judgment, outline edited" detail
check "standing judgment, outline edited: the judgment is revoked (every condition false)" "false|$(sk_conds false false)" \
  "$(all_met detail)|$(sk_sj_conds detail)"
sk_fx sc-own-skip detail
mock_p 0.95; sk_query detail
sq record "$SID" detail "$(sk_conds true true)" jev "$TICKET" > /dev/null
sq mark "$SID" detail skipped > /dev/null
EV0="$(sk_events detail)"
printf '# Outline\n\nTwo approaches are open now.\n' > "$FX/plans/$SID-outline.md"
sk_fin
check "this ticket already skipped the step: the re-run replays it, sources not re-checked" "0|ok|true|1" \
  "$JJ_RC|$(kv SETTLE)|$(kv SKIP)|$(grep -c '^REPLAYED=1' "$OUT")"
check "own skip replayed: judgment not rewritten, detail stays skipped, no settle record" "$EV0|true|skipped|0" \
  "$(sk_events detail)|$(all_met detail)|$(sk_status detail)|$(sk_n_rec "$TICKET" settle)"
case_end

# The query-time claim of MS also revokes an older owner's standing all-true judgment while
# the step is still pending, and does neither when MS already names a newer owner.
case_begin "jj-skip-owner-query-revokes-standing" "bin/workflow/jev-judge"
sk_fx qr-pending detail
mock_p 0.95; sk_query detail; TA="$TICKET"; TA_CREATED="$(sk_created "$TA")"
sq record "$SID" detail "$(sk_conds true true)" jev "$TA" > /dev/null
check "premise: A's all-true judgment stands, detail pending" "true|pending" "$(all_met detail)|$(sk_status detail)"
sleep 0.05
sk_query detail; TB="$TICKET"
newer_premise "query revokes"
check "query B: A's standing judgment revoked, detail pending, MS owner B" "false|pending|\"$TB\"" \
  "$(all_met detail)|$(sk_status detail)|$(ms_get detail owner_id)"
sk_fx qr-skipped detail
mock_p 0.95; sk_query detail; TA="$TICKET"; TA_CREATED="$(sk_created "$TA")"
sk_fin
check "premise: A finalized, detail skipped" "true|skipped" "$(kv SKIP)|$(sk_status detail)"
A_SJ="$(sjq detail 'sj && JSON.stringify(sj)')"
sleep 0.05
sk_query detail; TB="$TICKET"
check "query B after the step was skipped: A's judgment and the skip stand" "$A_SJ|skipped" \
  "$(sjq detail 'sj && JSON.stringify(sj)')|$(sk_status detail)"
sk_fx qr-older detail
mock_p 0.95; sk_query detail; TB="$TICKET"; TB_CREATED="$(sk_created "$TB")"
sq record "$SID" detail "$(sk_conds true true)" jev "$TB" > /dev/null
snap
check "an owner queried earlier than MS: take-owner returns" "TOOK=1" "$(sq take-owner "$SID" detail 0123456789abcdef "$((TB_CREATED - 1))")"
unmoved "older owner at query time"
check "older owner at query time: the standing judgment is not revoked" "true" "$(all_met detail)"
check "an owner queried later than MS: take-owner returns" "TOOK=1" "$(sq take-owner "$SID" detail 0123456789abcdef "$((TB_CREATED + 1))")"
check "newer owner at query time: MS is its, the standing judgment revoked" "\"0123456789abcdef\"|$((TB_CREATED + 1))|false" \
  "$(ms_get detail owner_id)|$(ms_get detail owner_created_ms)|$(all_met detail)"
case_end
