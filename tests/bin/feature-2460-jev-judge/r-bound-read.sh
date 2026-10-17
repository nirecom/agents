#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, caller-contract, bound-read, signals-csv, failsafe, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# a newer ticket may overwrite the fixed file between finalize and the caller's read, so the
# caller's downstream takes finalize's SIGNALS_CSV, never the fixed file. While the ticket
# still owns the marker, a done-marker replay prints its own SIGNALS_CSV, not the file's.

echo "=== jev-judge: SIGNALS_CSV bound to the ticket ==="
need_mod bin/workflow/jev-judge || return 0
. "$JJ_DIR/two-stage-lib.sh"

ST="outline"
derive_sig() { bash "$RWT" 30 node "$DERIVE" --stage "$ST" --signals "$1" 2>/dev/null | tr -d '\r' | paste -sd'|' -; }
derive_sess() { bash "$RWT" 30 node "$DERIVE" --stage "$ST" --session "$SID" 2>/dev/null | tr -d '\r' | paste -sd'|' -; }
record_ce() { bash "$RWT" 30 node "$RECORD_CE" --session "$SID" --signals "$1" 2>/dev/null | tr -d '\r'; }
level_of() { printf '%s' "$1" | tr '|' '\n' | grep -m1 '^level=' | sed 's/^level=//'; }
# overwrite_with_b: ticket B (all signals absent) is queried and finalized. Jev never adopts
# an absence (false: null), so B's "none" comes from the subagent answer.
overwrite_with_b() {
  mock_p 0.01
  ts_query "$ST" complexity-judge "$F_PRODUCTION"; TB="$TICKET"
  answer_with "SIGNALS: none"
  jj finalize --session "$SID" --ticket "$TB"
  check "B finalize overwrites: SETTLE=ok, SIGNALS_CSV empty" "ok|" "$(kv SETTLE)|$(kv SIGNALS_CSV)"
  check "fixed file now holds B (empty)" "" "$(fixed_csv "$ST")"
  check "owner is B" "\"$TB\"" "$(pb json-get "$(np "$(ctl "$ST-signals-owner.json")")" owner_id)"
}

case_begin "r-bound-read-finalize" "bin/workflow/jev-judge"
jj_fx r-final
mock_p 0.01 S2-architecture 0.95
ts_query "$ST" complexity-judge "$F_PRODUCTION"; TA="$TICKET"
jj finalize --session "$SID" --ticket "$TA"
check "A finalize: SETTLE=ok, SIGNALS_CSV=S2-architecture" "0|ok|S2-architecture" "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
A_CSV="$(kv SIGNALS_CSV)"; A_OUT="$(out_text)"
check "fixed file holds A's result" "S2-architecture" "$(fixed_csv "$ST")"
# An unowned overwrite leaves A the marker owner, so the done-marker replay keeps A's value
# (a newer-owner replay turns superseded instead; i-idempotent.sh covers that case).
printf '\n' > "$(ctl "$ST-signals.txt")"
jj finalize --session "$SID" --ticket "$TA"
check "A re-run after an unowned overwrite: SIGNALS_CSV=S2-architecture, not the file's" "0|S2-architecture" \
  "$JJ_RC|$(kv SIGNALS_CSV)"
check "A re-run: stdout byte-equal to the first finalize" "$A_OUT" "$(out_text)"
overwrite_with_b
A_DERIVED="$(derive_sig "$A_CSV")"
check "caller A derives from its SIGNALS_CSV: high (S2)" "high" "$(level_of "$A_DERIVED")"
check "caller A records the evaluation with S2" "1" "$(record_ce "$A_CSV" | grep -c 'signals=S2-architecture')"
check "control: derive --session reads B's fixed file instead" "$(derive_sig "")" "$(derive_sess)"
check "control: the fixed-file path disagrees with A's bound value" "differs" \
  "$([ "$(derive_sess)" != "$A_DERIVED" ] && echo differs || echo same)"
case_end

case_begin "r-bound-read-failsafe" "bin/workflow/jev-judge"
jj_fx r-failsafe
mock_p 0.01 S2-architecture 0.95
ts_query "$ST" complexity-judge "$F_PRODUCTION"; TA="$TICKET"
jj failsafe --session "$SID" --point complexity-judge --stage "$ST" --ticket "$TA"
check "failsafe --ticket A: SETTLE=ok, SIGNALS_CSV=S0-undecidable" "0|ok|S0-undecidable" \
  "$JJ_RC|$(kv SETTLE)|$(kv SIGNALS_CSV)"
FS_CSV="$(kv SIGNALS_CSV)"
overwrite_with_b
check "caller passes the failsafe SIGNALS_CSV: high / opus" "level=high|model=opus" \
  "$(derive_sig "$FS_CSV" | tr '|' '\n' | grep -E '^(level|model)=' | paste -sd'|' -)"
check "control: derive --session follows B" "$(derive_sig "")" "$(derive_sess)"
no_secret_leak "r-bound-read"
case_end
