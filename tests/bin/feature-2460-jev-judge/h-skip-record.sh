#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge, bin/workflow/lib/jev-skip-adapter.js, bin/workflow/record-skip-judgment
# Tags: TL2, bin, jev, two-stage, skip-gate, skip-judgment, short-circuit, idempotent, usage-error, untrusted-input, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# what finalize leaves in skip_judgment (source, ticket, the full schema key set, missing keys
# filled false by one rule) and record-skip-judgment's idempotent resume table for --ticket.

echo "=== jev-judge: skip judgment record ==="
need_mod bin/workflow/jev-judge || return 0
need_mod bin/workflow/lib/jev-skip-adapter.js || return 0
. "$JJ_DIR/_skip-lib.sh"

T_X="fedcba9876543210"
# line_of <prefix>: the 1-based line number of the first $OUT line starting with <prefix> (0 if none).
line_of() { local n; n="$(tr -d '\r' < "$OUT" | grep -n "^$1" | head -1 | cut -d: -f1)"; echo "${n:-0}"; }
# rsj_new <ticket> <K1val> <K2val> [extra...]: the new-form call with --advance for detail.
# The CLI only records what a finalized ticket of this session answered, so the claim for
# <ticket> carrying these values is planted first (once per fixture).
rsj_new() {
  local t="$1" a="$2" b="$3"; shift 3
  if [ -z "$(find "$JEVDIR" -name "$t.claimed-*" -type f 2>/dev/null | head -1)" ]; then
    node "$REPO_N/tests/lib/finalized-ticket.js" "$REPO_N" "$SID" detail "$t" "$(sk_conds "$a" "$b")" jev > /dev/null
  fi
  rsj --session "$SID" --target detail --cond "$K1=$a" --cond "$K2=$b" --source jev --ticket "$t" --advance "$@"
}
# seed <fixture> <K1val> <K2val> <ticket>: a judgment written without advance (probe record).
seed() {
  sk_fx "$1" detail
  sq record "$SID" detail "$(sk_conds "$2" "$3")" jev "$4" > /dev/null
}

case_begin "jj-skip-record-sources-and-validity" "bin/workflow/jev-judge"
sk_fx h-src-jev detail; mock_p 0.95; sk_query detail; sk_fin
check "jev: source jev, ticket recorded" "jev|$TICKET" "$(sjq detail 'sj && sj.judgment_source+"|"+sj.ticket')"
check "jev: hasValidSkipJudgment and isRecordedVerdictValid" "true|true" "$(sq valid "$SID" detail)"
sleep 1.1
printf '# Outline\n\nEdited after the judgment.\n' > "$FX/plans/$SID-outline.md"
check "jev: outline.md newer than the judgment -> hasValidSkipJudgment false" "false" "$(sq valid "$SID" detail | cut -d'|' -f1)"
sk_fx h-src-sub detail; mock_p 0.5; sk_query detail
sk_answer "$(sk_line true true)"; sk_fin
check "subagent: source subagent, ticket recorded" "subagent|$TICKET" "$(sjq detail 'sj && sj.judgment_source+"|"+sj.ticket')"
check "subagent: valid" "true|true" "$(sq valid "$SID" detail)"
sk_fx h-src-mix detail; mock_p 0.5 "$K2" 0.95; sk_query detail
sk_answer "$(sk_line true true)"; sk_fin
check "mixed: source mixed, ticket recorded" "mixed|$TICKET" "$(sjq detail 'sj && sj.judgment_source+"|"+sj.ticket')"
check "mixed: valid" "true|true" "$(sq valid "$SID" detail)"
case_end

case_begin "jj-skip-record-short-circuit-shape" "bin/workflow/jev-judge"
for tg in detail outline; do
  sk_fx "h-sc-$tg" "$tg"; mock_p 0.5 "$K1" 0.5 "$K2" 0.2; sk_query "$tg"; sk_fin
  check "$tg short circuit: key set equals CONDITION_SCHEMAS.$tg" "$(sq schema "$tg")" \
    "$(sjq "$tg" 'sj && Object.keys(sj.conditions).sort().join(",")')"
  check "$tg short circuit: K2 false (adopted), K1 false (unjudged filled)" "$(sk_conds false false)" "$(sk_sj_conds "$tg")"
  check "$tg short circuit: source jev with the ticket" "jev|$TICKET" "$(sjq "$tg" 'sj && sj.judgment_source+"|"+sj.ticket')"
  check "$tg short circuit: isRecordedVerdictValid accepts the record" "true" "$(sq valid "$SID" "$tg" | cut -d'|' -f2)"
  check "$tg short circuit: $tg stays pending" "pending" "$(sk_status "$tg")"
  check "$tg short circuit: unjudged_keys [K1], short_circuited true" "[\"$K1\"]|true" \
    "$(lq "$TICKET" 'r && JSON.stringify(r.unjudged_keys)+"|"+r.short_circuited')"
  check "$tg short circuit: final.conditions equals skip_judgment" "$(sk_sj_conds "$tg")" \
    "$(lq "$TICKET" "r && r.final && JSON.stringify({\"$K1\": r.final.conditions[\"$K1\"], \"$K2\": r.final.conditions[\"$K2\"]})")"
done
case_end

case_begin "jj-skip-record-one-fill-rule" "bin/workflow/jev-judge"
sk_fx h-fill-sc detail; mock_p 0.5 "$K2" 0.2; sk_query detail; sk_fin
F_SC="$(sjq detail "sj && String(sj.conditions[\"$K1\"])")"
sk_fx h-fill-abs detail; mock_p 0.5 "$K2" 0.95; sk_query detail; sk_fin
F_ABS="$(sjq detail "sj && String(sj.conditions[\"$K1\"])")"
sk_fx h-fill-unp detail; mock_p 0.5 "$K2" 0.95; sk_query detail
sk_answer "I could not decide."; sk_fin
F_UNP="$(sjq detail "sj && String(sj.conditions[\"$K1\"])")"
check "K1 filled false by short circuit / answer-file-absent / unparseable alike" "false|false|false" "$F_SC|$F_ABS|$F_UNP"
case_end

case_begin "jj-rsj-table-same-ticket-true-pending" "bin/workflow/record-skip-judgment"
seed h-t1 true true "$T_X"
rsj_new "$T_X" true true
check "row 1: exit 0" "0" "$RSJ_RC"
check "row 1: RECORDED line" "1" "$(grep -c '^RECORDED=detail all_conditions_met=true' "$OUT")"
check "row 1: REPLAYED=1 is the last line, after the advance" "$(out_lines)" "$(line_of REPLAYED=1)"
check "row 1: advance happened, judgment not rewritten" "skipped|1" "$(sk_status detail)|$(sk_events detail)"
case_end

case_begin "jj-rsj-table-same-ticket-true-skipped" "bin/workflow/record-skip-judgment"
seed h-t2 true true "$T_X"
sq mark "$SID" detail skipped > /dev/null
rsj_new "$T_X" true true
check "row 2: RECORDED + REPLAYED=1" "1|1" \
  "$(grep -c '^RECORDED=detail all_conditions_met=true' "$OUT")|$(grep -c '^REPLAYED=1' "$OUT")"
check "row 2: still skipped, one event" "skipped|1" "$(sk_status detail)|$(sk_events detail)"
case_end

case_begin "jj-rsj-table-same-ticket-true-other" "bin/workflow/record-skip-judgment"
seed h-t3 true true "$T_X"
sq mark "$SID" detail in_progress > /dev/null
rsj_new "$T_X" true true
check "row 3: RECORDED=superseded" "superseded" "$(kv RECORDED)"
check "row 3: no REPLAYED line" "0" "$(grep -c '^REPLAYED=' "$OUT")"
check "row 3: in_progress kept, one event" "in_progress|1" "$(sk_status detail)|$(sk_events detail)"
case_end

case_begin "jj-rsj-table-same-ticket-not-all-true" "bin/workflow/record-skip-judgment"
seed h-t4 true false "$T_X"
rsj_new "$T_X" true false
check "row 4: RECORDED all_conditions_met=false + REPLAYED=1" "1|1" \
  "$(grep -c '^RECORDED=detail all_conditions_met=false' "$OUT")|$(grep -c '^REPLAYED=1' "$OUT")"
check "row 4: pending, one event" "pending|1" "$(sk_status detail)|$(sk_events detail)"
case_end

case_begin "jj-rsj-table-new-ticket-pending" "bin/workflow/record-skip-judgment"
sk_fx h-t5 detail
rsj_new "$T_X" true true
check "row 5: normal write" "1|0" "$(grep -c '^RECORDED=detail all_conditions_met=true' "$OUT")|$(grep -c '^REPLAYED=' "$OUT")"
check "row 5: skipped, one event, ticket recorded" "skipped|1|$T_X" \
  "$(sk_status detail)|$(sk_events detail)|$(sjq detail 'sj && sj.ticket')"
seed h-t5b true true "$SK_OTHER_TICKET"
rsj_new "$T_X" true true
check "row 5 (different ticket, pending): written with the new ticket" "$T_X|skipped" \
  "$(sjq detail 'sj && sj.ticket')|$(sk_status detail)"
case_end

case_begin "jj-rsj-table-new-ticket-not-pending" "bin/workflow/record-skip-judgment"
seed h-t6 true true "$SK_OTHER_TICKET"
sq mark "$SID" detail in_progress > /dev/null
rsj_new "$T_X" true true
check "row 6 (different ticket): RECORDED=superseded" "superseded" "$(kv RECORDED)"
check "row 6: nothing rewritten" "in_progress|1|$SK_OTHER_TICKET" \
  "$(sk_status detail)|$(sk_events detail)|$(sjq detail 'sj && sj.ticket')"
sk_fx h-t6b detail
sq mark "$SID" detail in_progress > /dev/null
rsj_new "$T_X" true true
check "row 6 (no judgment): RECORDED=superseded, nothing written" "superseded|0" "$(kv RECORDED)|$(sk_events detail)"
case_end

case_begin "jj-rsj-same-ticket-twice" "bin/workflow/record-skip-judgment"
sk_fx h-tw detail
rsj_new "$T_X" true true
SJ1="$(sjq detail 'sj && JSON.stringify(sj)')"; M1="$(sq state-mtime "$SID")"
sleep 1.1
rsj_new "$T_X" true true
check "twice: second call exit 0 with REPLAYED=1" "0|1" "$RSJ_RC|$(grep -c '^REPLAYED=1' "$OUT")"
check "twice: skip_judgment content unchanged" "$SJ1" "$(sjq detail 'sj && JSON.stringify(sj)')"
check "twice: state file mtime unchanged (no second write or advance)" "$M1" "$(sq state-mtime "$SID")"
check "twice: one event" "1" "$(sk_events detail)"
case_end

case_begin "jj-rsj-arg-validation" "bin/workflow/record-skip-judgment"
sk_fx h-av detail
rsj --session "$SID" --target detail --cond "$K1=true" --source jev --ticket "$T_X" --advance
check "missing --cond key: exit 2, nothing written" "2|0" "$RSJ_RC|$(sk_events detail)"
rsj --session "$SID" --target detail --cond "$K1=true" --cond "$K2=true" --c1 true --source jev --ticket "$T_X"
check "new and old args mixed: exit 2, nothing written" "2|0" "$RSJ_RC|$(sk_events detail)"
rsj --session "$SID" --target detail --cond "$K1=true;touch pwned" --cond "$K2=true" --source jev --ticket "$T_X"
check "metacharacters in --cond: exit 2, nothing written" "2|0" "$RSJ_RC|$(sk_events detail)"
check "metacharacters in --cond: nothing executed" "absent" "$([ -e "$FX/cwd/pwned" ] && echo present || echo absent)"
rsj --session "$SID" --target detail --cond "$K1=true" --cond "$K2=true" --cond sd_c1=true --source jev --ticket "$T_X"
check "extra key in --cond: exit 2, nothing written" "2|0" "$RSJ_RC|$(sk_events detail)"
rsj --session "$SID" --target detail --cond "$K1=true" --cond "$K2=true" --source jev --ticket 'zz$(id)'
check "malformed --ticket: rejected, nothing written" "2|0" "$RSJ_RC|$(sk_events detail)"
case_end
