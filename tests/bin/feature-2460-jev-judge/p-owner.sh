#!/usr/bin/env bash
# Tests: hooks/lib/jev/two-stage/settle-complexity.js
# Tags: TL2, bin, jev, two-stage, owner-marker, newer-owner, unowned-write, lock, concurrency, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# ownership of the fixed <stage>-signals.txt is decided by the owner marker (the newer query
# wins), never by comparing the file content with this ticket's result.

echo "=== jev-judge: fixed signals file owner marker ==="
need_mod bin/workflow/jev-judge || return 0
need_mod hooks/lib/jev/two-stage/settle-complexity.js || return 0
. "$JJ_DIR/two-stage-lib.sh"

F_NAME="complexity-signals.txt"
M_NAME="complexity-signals-owner.json"
L_NAME="complexity-signals-owner.lock"
fpath() { ctl "$1"; }
fsha() { local f; f="$(fpath "$1")"; if [ -f "$f" ]; then pb sha "$(np "$f")"; else echo "<absent>"; fi; }
mtime() { local f; f="$(fpath "$1")"; if [ -f "$f" ]; then stat -c %Y "$f"; else echo "<absent>"; fi; }
owner() { pb json-get "$(np "$(fpath "$M_NAME")")" "$1"; }
settles() { lq "$1" 'recs.filter(x=>x.record_type==="settle").map(x=>[x.settle,x.detail,x.owner].join("|")).join(";")'; }
# two_tickets: A then B queried from the same fixture and the same mock answer (S2 true).
two_tickets() {
  mock_p 0.01 S2-architecture 0.95
  ts_query complexity complexity-judge "$F_PRODUCTION"; TA="$TICKET"
  ts_query complexity complexity-judge "$F_PRODUCTION"; TB="$TICKET"; TB_CREATED="$(tk created_ms)"
}
put_fixed() { local f; f="$(fpath "$F_NAME")"; mkdir -p "$(dirname "$f")"; printf '%s\n' "$1" > "$f"; }

case_begin "p-owner-newer-finalized-first" "hooks/lib/jev/two-stage/settle-complexity.js"
jj_fx p-b-first
two_tickets
jj finalize --session "$SID" --ticket "$TB"
check "B first: SETTLE=ok, SIGNALS_CSV=S2-architecture" "ok|S2-architecture" "$(kv SETTLE)|$(kv SIGNALS_CSV)"
F_SHA="$(fsha "$F_NAME")"; F_MT="$(mtime "$F_NAME")"; M_SHA="$(fsha "$M_NAME")"
sleep 1.1
jj finalize --session "$SID" --ticket "$TA"
check "A after B, same content: SETTLE=superseded, SIGNALS_CSV=-" "0|superseded|-" "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
check "A: the fixed file content still equals A's own result" "S2-architecture" "$(fixed_csv complexity)"
check "A: settle record newer-owner, owner B" "superseded|newer-owner|$TB" "$(settles "$TA")"
check "A: fixed file bytes and mtime unchanged" "$F_SHA|$F_MT" "$(fsha "$F_NAME")|$(mtime "$F_NAME")"
check "A: owner marker unchanged (owner B, written)" "$M_SHA|\"$TB\"|\"written\"" \
  "$(fsha "$M_NAME")|$(owner owner_id)|$(owner state)"
check "B: no settle record" "" "$(settles "$TB")"
case_end

case_begin "p-owner-older-finalized-first" "hooks/lib/jev/two-stage/settle-complexity.js"
jj_fx p-a-first
two_tickets
jj finalize --session "$SID" --ticket "$TA"
check "A first: SETTLE=ok, owner A" "ok|\"$TA\"" "$(kv SETTLE)|$(owner owner_id)"
jj finalize --session "$SID" --ticket "$TB"
check "B after A: SETTLE=ok, owner B, written" "ok|\"$TB\"|\"written\"" "$(kv SETTLE)|$(owner owner_id)|$(owner state)"
check "neither ticket has a settle record" "|" "$(settles "$TA")|$(settles "$TB")"
check "owner_created_ms is B's query time" "$TB_CREATED" "$(owner owner_created_ms)"
case_end

case_begin "p-owner-no-marker-mtime-rule" "hooks/lib/jev/two-stage/settle-complexity.js"
jj_fx p-old-file
mock_p 0.01 S2-architecture 0.95
put_fixed "S2-architecture"
touch -d '2000-01-01 00:00:00' "$(fpath "$F_NAME")"
ts_query complexity complexity-judge "$F_PRODUCTION"
jj finalize --session "$SID" --ticket "$TICKET"
check "no marker, file older than the query: A writes (SETTLE=ok, owner A)" "ok|\"$TICKET\"|\"written\"" \
  "$(kv SETTLE)|$(owner owner_id)|$(owner state)"
check "no marker, older file: no settle record" "" "$(settles "$TICKET")"
jj_fx p-new-file
mock_p 0.01 S2-architecture 0.95
ts_query complexity complexity-judge "$F_PRODUCTION"
sleep 1.1
put_fixed "S2-architecture"
F_SHA="$(fsha "$F_NAME")"; F_MT="$(mtime "$F_NAME")"
jj finalize --session "$SID" --ticket "$TICKET"
check "no marker, file written after the query with A's own content: superseded" "superseded|-" \
  "$(kv SETTLE)|$(kv SIGNALS_CSV)"
check "unowned-write settle record, owner null" "superseded|unowned-write|" "$(settles "$TICKET")"
check "unowned write: file untouched, no marker created" "$F_SHA|$F_MT|<absent>" \
  "$(fsha "$F_NAME")|$(mtime "$F_NAME")|$(fsha "$M_NAME")"
case_end

case_begin "p-owner-concurrent-settle" "hooks/lib/jev/two-stage/settle-complexity.js"
jj_fx p-race
OA="aaaaaaaaaaaaaaaa"; OB="bbbbbbbbbbbbbbbb"
( tpb settle "$SID" complexity "SIGNALS: S2-architecture" "S2-architecture" "$OA" 1000 > "$FX/settle-a.out" ) &
PA=$!
( tpb settle "$SID" complexity "SIGNALS: none" "" "$OB" 2000 > "$FX/settle-b.out" ) &
PB=$!
wait "$PA"; wait "$PB"
check "both settles answered ok or superseded" "1|1" \
  "$(grep -Ecx 'ok|superseded' "$FX/settle-a.out")|$(grep -Ecx 'ok|superseded' "$FX/settle-b.out")"
check "B (newer) settled ok" "ok" "$(tr -d '\r\n' < "$FX/settle-b.out")"
check "owner ends as the newer B, state written (never left writing)" "\"$OB\"|\"written\"" "$(owner owner_id)|$(owner state)"
check "fixed file holds B's result" "" "$(fixed_csv complexity)"
check "no lock left behind" "0" "$(find "$(dirname "$(fpath "$L_NAME")")" -name "$L_NAME" 2>/dev/null | wc -l | tr -d ' ')"
case_end

# Tie-break on equal created_ms (audit run-0024): failsafe- beats a ticket id even when the
# id sorts after "failsafe-" (ff...); two ticket ids compare lexically.
case_begin "p-owner-tie-break-kind-then-lexical" "hooks/lib/jev/two-stage/settle-complexity.js"
FS="failsafe-0123456789abcdef"; TFF="ffffffffffffffff"; T01="0123456789abcdef"
jj_fx p-tie-fs
check "failsafe settles first at created 1000" "ok" "$(tpb settle "$SID" complexity "SIGNALS: S0-undecidable" "S0-undecidable" "$FS" 1000)"
check "ticket ffff... at the same created_ms loses to the failsafe" "superseded" \
  "$(tpb settle "$SID" complexity "SIGNALS: S2-architecture" "S2-architecture" "$TFF" 1000)"
check "fixed file keeps the failsafe result" "S0-undecidable|\"$FS\"" "$(fixed_csv complexity)|$(owner owner_id)"
jj_fx p-tie-ticket-first
check "ticket ffff... settles first at created 1000" "ok" "$(tpb settle "$SID" complexity "SIGNALS: S2-architecture" "S2-architecture" "$TFF" 1000)"
check "failsafe at the same created_ms overwrites it" "ok|S0-undecidable|\"$FS\"" \
  "$(tpb settle "$SID" complexity "SIGNALS: S0-undecidable" "S0-undecidable" "$FS" 1000)|$(fixed_csv complexity)|$(owner owner_id)"
jj_fx p-tie-lexical
check "ticket ffff... settles first at created 1000" "ok" "$(tpb settle "$SID" complexity "SIGNALS: S2-architecture" "S2-architecture" "$TFF" 1000)"
check "ticket 0123... at the same created_ms is lexically older: superseded" "superseded" \
  "$(tpb settle "$SID" complexity "SIGNALS: none" "" "$T01" 1000)"
CMP_FS="$(tpb compare-owner "$FS" 1000 "$TFF" 1000)"
if [ "$CMP_FS" != "n/a" ]; then
  CMP_LEX="$(tpb compare-owner "$TFF" 1000 "$T01" 1000)"
  check "compareOwner: failsafe vs ffff... and ffff... vs 0123... are antisymmetric" "yes|yes" \
    "$([ "${CMP_FS%%|*}" = "$(( -${CMP_FS##*|} ))" ] && [ "${CMP_FS%%|*}" != 0 ] && echo yes || echo no)|$([ "${CMP_LEX%%|*}" = "$(( -${CMP_LEX##*|} ))" ] && [ "${CMP_LEX%%|*}" != 0 ] && echo yes || echo no)"
  check "compareOwner: failsafe is newer than ffff... the same way ffff... is newer than 0123..." \
    "${CMP_LEX%%|*}" "${CMP_FS%%|*}"
fi
case_end

case_begin "p-owner-lock-stale-and-held" "hooks/lib/jev/two-stage/settle-complexity.js"
jj_fx p-stale-lock
mock_p 0.01 S2-architecture 0.95
ts_query complexity complexity-judge "$F_PRODUCTION"
LK="$(fpath "$L_NAME")"; mkdir -p "$(dirname "$LK")"
printf 'stale\n' > "$LK"
touch -d '2000-01-01 00:00:00' "$LK"
jj finalize --session "$SID" --ticket "$TICKET"
check "stale lock is stolen: SETTLE=ok, owner written" "0|ok|\"written\"" "$JJ_RC|$(kv SETTLE)|$(owner state)"
check "stolen lock released" "0" "$([ -e "$LK" ] && echo 1 || echo 0)"
jj_fx p-held-lock
mock_p 0.01 S2-architecture 0.95
ts_query complexity complexity-judge "$F_PRODUCTION"
LK="$(fpath "$L_NAME")"; mkdir -p "$(dirname "$LK")"
printf 'held\n' > "$LK"
jj finalize --session "$SID" --ticket "$TICKET"
check "fresh lock held by another settle: finalize exits 3, fixed file not written" "3|<absent>" \
  "$JJ_RC|$(fixed_csv complexity)"
check "held lock: the decision record is already appended once" "1" \
  "$(lq "$TICKET" 'recs.filter(x=>x.record_type==="decision").length')"
rm -f "$LK"
jj finalize --session "$SID" --ticket "$TICKET"
check "after the lock is gone: the re-run replays to SETTLE=ok" "0|ok|S2-architecture" \
  "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
check "held lock re-run: still one decision record" "1" \
  "$(lq "$TICKET" 'recs.filter(x=>x.record_type==="decision").length')"
no_secret_leak "p-owner"
case_end
