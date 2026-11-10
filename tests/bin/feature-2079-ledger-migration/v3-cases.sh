# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/v3-cases.sh
# Tests: bin/lib/run-all-durations.sh
# Tags: tests, bin, ledger, durations, consolidate, migration, v3, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher headers, tests/bin/feature-2079-ledger-migration-*.sh.
# n23 (#2932) ledger v3: rows `rid|secs|verdict|termination|key`; own dur.2 files migrate to
# `?|?` rows; the fold keeps the newest RUN_ALL_DUR_KEEP_PER_SERIES (5) per
# `rid|key|verdict|termination` and caps a base at RUN_ALL_DUR_BASE_MAX_RECORDS (40000);
# run_all_dur_file_result / run_all_dur_append map and sanitise the file result.

[ "${DC_LIB_LOADED:-0}" = "1" ] || . "${BASH_SOURCE[0]%/*}/_lib-consolidate.sh"

# ---- child side ---------------------------------------------------------------

v3_schema() { say schema "${RUN_ALL_DUR_SCHEMA:-unset}"; }

# v3_rows <key> — every current-format row for <key> in this host's files, repo id as `R`, sorted.
v3_rows() {
  local f rid; rid="$(lm_rid)"
  for f in "$(lm_dur_dir)"/"$LM_CUR"."$(lm_tok)".*; do
    [ -f "$f" ] || continue
    grep -F -- "|$1" "$f" | grep -v '^#'
  done | awk -F'|' -v k="$1" -v r="$rid" '$NF == k { sub("^" r "[|]", "R|"); print }' | LC_ALL=C sort | tr '\n' ';'
}

# v3_plant_dur2 <age-min> <header|-> <secs:key>... — one own-token legacy dur.2 segment.
v3_plant_dur2() {
  local age="$1" hdr="$2"; shift 2
  lm_plant_dur "dur.2.$(lm_tok).${LM_DAY}T000001-21.log" "$age" "$hdr" "$@"
}

c_v3_migrate() {
  v3_plant_dur2 "$LM_XVAR" "${V3_HDR:-Windows/10.0.26300}" 4:m1.sh 9:m2.sh
  local f="$(lm_dur_dir)/dur.2.$(lm_tok).${LM_DAY}T000001-21.log" sum
  sum="$(lm_sum "$f")"
  run_all_dur_writer_init "$LM_REPO"
  say dur2_left "$(lm_count 'dur.2.*')"
  say dur2_same "$([ "$(lm_sum "$f")" = "$sum" ] && echo 1 || echo 0)"
  say rows "$(v3_rows m1.sh)$(v3_rows m2.sh)"
  say vals "$(lm_get m1.sh m2.sh)"
  say attrs "$(for f in "$(lm_dur_dir)"/"$LM_CUR"."$(lm_tok)".*; do [ -f "$f" ] && grep -q '|m1\.sh$' "$f" && head -n 1 "$f"; done | tr '\n' ',')"
}

# c_v3_claim_boundary — own-token dur.2 .closed/.consolidating segments are claimed; a
# foreign-token dur.2 segment is neither claimed nor changed and none of its rows turn up as v3.
c_v3_claim_boundary() {
  local d ft alien sum; d="$(lm_dur_dir)"
  ft="$(run_all_dur_pad16 "foreignhost$(lm_tok)")"
  alien="dur.2.${ft}.${LM_DAY}T000004-24.log"
  lm_plant_dur "dur.2.$(lm_tok).${LM_DAY}T000002-22.closed.log" 120 "Windows/10.0.26300" 4:c1.sh
  lm_plant_dur "dur.2.$(lm_tok).${LM_DAY}T000003-23.consolidating.log" 120 "Windows/10.0.26300" 5:c2.sh
  lm_plant_dur "$alien" 120 "Windows/10.0.26300" 6:f1.sh
  sum="$(lm_sum "$d/$alien")"
  run_all_dur_writer_init "$LM_REPO"
  say own_left "$(lm_count "dur.2.$(lm_tok).*")"
  say alien_left "$(lm_count "dur.2.${ft}.*")"
  say alien_same "$([ "$(lm_sum "$d/$alien")" = "$sum" ] && echo 1 || echo 0)"
  say rows "$(v3_rows c1.sh)$(v3_rows c2.sh)"
  say alien_rows "$(v3_rows f1.sh)"
}

# c_v3_reinit — one more writer init over the same cache; the migrated rows' state after it.
c_v3_reinit() {
  run_all_dur_writer_init "$LM_REPO"
  say dur2_left "$(lm_count 'dur.2.*')"
  say rows "$(v3_rows m1.sh)$(v3_rows m2.sh)"
  say vals "$(lm_get m1.sh m2.sh)"
}

# c_v3_keep — 7 closed runs of one series: secs 1..7, oldest first.
c_v3_keep() {
  local i
  for i in 1 2 3 4 5 6 7; do dc_plant "${DC_D}T0${i}0000-1$i.closed" 30 "#os $DC_L" "$i:s.sh"; done
  dc_cons
  say secs "$(dc_body | tr ';' '\n' | grep '|s\.sh$' | cut -d'|' -f2 | tr '\n' ' ')"
  say val "$(lm_get s.sh)"
}

# c_v3_series — 6 PASS runs and one later FAIL run of the same key.
c_v3_series() {
  local i
  for i in 1 2 3 4 5 6; do dc_plant "${DC_D}T0${i}0000-1$i.closed" 30 "#os $DC_L" "$i:v.sh"; done
  dc_plant "${DC_D}T070000-17.closed" 30 "#os $DC_L" "=RID|9|FAIL|completed|v.sh"
  dc_cons
  say split "$(dc_body | tr ';' '\n' | grep -c '|PASS|completed|v\.sh$')/$(dc_body | tr ';' '\n' | grep -c '|FAIL|completed|v\.sh$')"
}

# c_v3_cap — a base of 39998 (provenance A) + 2 (B) records, then a closed run C of 3:
# 40003 rows exceed the 40000 cap, so A (the oldest) loses rows and B and C survive whole.
c_v3_cap() {
  local f rid; rid="$(lm_rid)"; mkdir -p "$(lm_dur_dir)"
  f="$(lm_dur_dir)/$(dc_name "${DC_D}T010000-01")"
  awk -v r="$rid" -v l="$DC_L" -v d="$DC_D" 'BEGIN {
    print "#os " l; print "#run " d "T010000-11"
    for (i = 1; i <= 39998; i++) printf "%s|1|PASS|completed|old%d.sh\n", r, i
    print "#run " d "T015000-13"
    printf "%s|2|PASS|completed|mid1.sh\n%s|2|PASS|completed|mid2.sh\n", r, r
  }' > "$f"
  lm_age "$f" 30
  dc_plant "${DC_D}T020000-12.closed" 30 "#os $DC_L" 3:new1.sh 3:new2.sh 3:new3.sh
  dc_cons
  say nrec "$(dc_body | tr ';' '\n' | grep -vc '^#')"
  say nold "$(dc_body | tr ';' '\n' | grep -c '|old[0-9]*\.sh$')"
  say vals "$(lm_get mid1.sh mid2.sh new1.sh new2.sh new3.sh)"
}

c_v3_file_result() {
  local st out=""
  if ! command -v run_all_dur_file_result >/dev/null 2>&1; then say have no; return 0; fi
  say have yes
  for st in PASS FAIL SKIP TIMEOUT UNRUNNABLE UNSUPPORTED; do
    out="$out $st=$(run_all_dur_file_result "$st" 2>/dev/null | tr ' \t' '||')"
  done
  say map "${out# }"
}

c_v3_append() {
  local seg rid; rid="$(lm_rid)"
  run_all_dur_writer_init "$LM_REPO"
  seg="$RUN_ALL_DUR_SEGMENT"
  run_all_dur_append "ap.sh" 5 PASS completed
  run_all_dur_append "to.sh" 6 - timeout
  run_all_dur_append "bv.sh" 7 "BAD VERDICT" completed
  run_all_dur_append "bt.sh" 8 FAIL "bad.term"
  run_all_dur_append "na.sh" 9
  say rows "$(grep -v '^#' "$seg" 2>/dev/null | sed "s/^$rid|/R|/" | tr '\n' ';')"
  say vals "$(lm_get ap.sh to.sh bv.sh bt.sh na.sh)"
}

# c_v3_file_result_default — an empty and an unknown state, each after a valid one.
c_v3_file_result_default() {
  local st out=""
  for st in "" BOGUS; do
    run_all_dur_file_result_into PASS
    run_all_dur_file_result_into "$st"
    out="$out ${st:-empty}=$RUN_ALL_DUR_FR_VERDICT|$RUN_ALL_DUR_FR_TERM"
  done
  say map "${out# }"
}

# c_v3_append_width — verdict / termination tokens of exactly 16 and of 17 characters.
c_v3_append_width() {
  local rid; rid="$(lm_rid)"
  run_all_dur_writer_init "$LM_REPO"
  run_all_dur_append "w16.sh" 3 ABCDEFGHIJKLMNOP abcdefghijklmnop
  run_all_dur_append "w17.sh" 4 ABCDEFGHIJKLMNOPQ abcdefghijklmnopq
  say rows "$(grep -v '^#' "$RUN_ALL_DUR_SEGMENT" 2>/dev/null | sed "s/^$rid|/R|/" | tr '\n' ';')"
}

# c_v3_base — an own-token dur.2 base segment (`<S>-01`) is migrated like any other state.
c_v3_base() {
  lm_plant_dur "dur.2.$(lm_tok).${LM_DAY}T000005-01.log" 120 "Windows/10.0.26300" 7:b1.sh 8:b2.sh
  run_all_dur_writer_init "$LM_REPO"
  say dur2_left "$(lm_count 'dur.2.*')"
  say rows "$(v3_rows b1.sh)$(v3_rows b2.sh)"
  say vals "$(lm_get b1.sh b2.sh)"
}

# c_v3_broken_name — one writer init over an own-token dur.2 segment whose name has no
# `<stamp>-<pid>`; reports the plain / claimed counts, the claim's checksum and `pending`.
c_v3_broken_name() {
  local d n rc=0; d="$(lm_dur_dir)"; n="dur.2.$(lm_tok).notastamp.log"
  [ -e "$d/$n" ] || [ -e "$d/$n.migrating" ] || lm_plant_dur "$n" 120 "Windows/10.0.26300" 6:x1.sh
  [ -e "$d/$n" ] && say sum0 "$(lm_sum "$d/$n")"
  run_all_dur_writer_init "$LM_REPO"
  run_all_ledger_migrate_durations_pending "$d" || rc=$?
  say state "$(lm_count "$n"):$(lm_count "$n.migrating"):$rc"
  say sum "$(lm_sum "$d/$n.migrating")"
  say rows "$(v3_rows x1.sh)"
}

# ---- parent side --------------------------------------------------------------

v3_lib_ck() { ck "$1/schema-is-3" "3" "$(lm_v "$(lm_run "$(lm_cache)" v3_schema)" schema)"; }

run_v3_migrate_rows_cases() {
  local c r
  v3_lib_ck n23/migrate; lm_win; c="$(lm_cache)"
  r="$(LM_XVAR=120 lm_run "$c" c_v3_migrate)"
  ck "n23/migrate/dur2-claimed" "0" "$(lm_v "$r" dur2_left)"
  ck "n23/migrate/three-field-rows-become-question-v3" "R|4|?|?|m1.sh;R|9|?|?|m2.sh;" "$(lm_v "$r" rows)"
  ck "n23/migrate/lookup-same-secs" "4 9" "$(lm_v "$r" vals)"
  r="$(lm_run "$c" c_v3_reinit)"
  ck "n23/migrate/rerun-converges" "0|R|4|?|?|m1.sh;R|9|?|?|m2.sh;|4 9" "$(lm_v "$r" dur2_left)|$(lm_v "$r" rows)|$(lm_v "$r" vals)"
}

run_v3_migrate_attr_cases() {
  local r
  lm_win
  r="$(LM_XVAR=120 V3_HDR="$DC_L" lm_run "$(lm_cache)" c_v3_migrate)"
  ck "n23/attr/list-dash-takes-os-header" "#os $DC_L," "$(lm_v "$r" attrs)"
  ck "n23/attr/rows-migrated" "R|4|?|?|m1.sh;R|9|?|?|m2.sh;" "$(lm_v "$r" rows)"
}

run_v3_migrate_window_cases() {
  local r
  lm_win
  r="$(LM_XVAR=30 lm_run "$(lm_cache)" c_v3_migrate)"
  ck "n23/window/young-dur2-not-claimed" "1:1" "$(lm_v "$r" dur2_left):$(lm_v "$r" dur2_same)"
  ck "n23/window/no-v3-rows-yet" "" "$(lm_v "$r" rows)"
}

run_v3_migrate_claim_cases() {
  local r
  lm_win
  r="$(lm_run "$(lm_cache)" c_v3_claim_boundary)"
  ck "n23/claim/own-closed-and-consolidating-claimed" "0" "$(lm_v "$r" own_left)"
  ck "n23/claim/own-rows-become-v3" "R|4|?|?|c1.sh;R|5|?|?|c2.sh;" "$(lm_v "$r" rows)"
  ck "n23/claim/foreign-token-dur2-kept-unchanged" "1:1" "$(lm_v "$r" alien_left):$(lm_v "$r" alien_same)"
  ck "n23/claim/foreign-rows-not-migrated" "" "$(lm_v "$r" alien_rows)"
  r="$(lm_run "$(lm_cache)" c_v3_base)"
  ck "n23/claim/own-base-segment-claimed" "0" "$(lm_v "$r" dur2_left)"
  ck "n23/claim/own-base-rows-become-v3" "R|7|?|?|b1.sh;R|8|?|?|b2.sh;" "$(lm_v "$r" rows)"
  ck "n23/claim/own-base-lookup-same-secs" "7 8" "$(lm_v "$r" vals)"
}

# A broken-name claim is kept (never folded, never deleted), so `pending` reports work every round.
run_v3_migrate_broken_cases() {
  local c r s0 i
  lm_win; c="$(lm_cache)"
  r="$(lm_run "$c" c_v3_broken_name)"; s0="$(lm_v "$r" sum0)"
  for i in 1 2; do
    [ "$i" = 1 ] || r="$(lm_run "$c" c_v3_broken_name)"
    ck "n23/broken/round$i-claimed-not-deleted-pending" "0:1:0" "$(lm_v "$r" state)"
    ck "n23/broken/round$i-claim-unchanged" "$s0" "$(lm_v "$r" sum)"
    ck "n23/broken/round$i-rows-not-folded" "" "$(lm_v "$r" rows)"
  done
}

run_v3_fold_cases() {
  local r
  dc_lib_ck n23/fold; v3_lib_ck n23/fold; lm_win
  r="$(lm_run "$(lm_cache)" c_v3_keep)"
  ck "n23/fold/seven-runs-keep-newest-five" "3 4 5 6 7 " "$(lm_v "$r" secs)"
  ck "n23/fold/lookup-newest" "7" "$(lm_v "$r" val)"
  r="$(lm_run "$(lm_cache)" c_v3_series)"
  ck "n23/fold/other-verdict-is-own-series" "5/1" "$(lm_v "$r" split)"
}

run_v3_cap_cases() {
  local r n o
  v3_lib_ck n23/cap; lm_win
  r="$(lm_run "$(lm_cache)" c_v3_cap)"
  n="$(lm_v "$r" nrec)"; o="$(lm_v "$r" nold)"
  if [ "$n" -le 40000 ] 2>/dev/null && [ "$n" -ge 5 ]; then pass "n23/cap/base-within-40000"
  else fail "n23/cap/base-within-40000" "nrec=[$n]"; fi
  if [ "$o" -lt 39998 ] 2>/dev/null; then pass "n23/cap/oldest-provenance-dropped"
  else fail "n23/cap/oldest-provenance-dropped" "old rows=[$o]"; fi
  ck "n23/cap/newer-provenances-kept" "2 2 3 3 3" "$(lm_v "$r" vals)"
}

run_v3_writer_lib_cases() {
  local r
  v3_lib_ck n23/writer; lm_win
  r="$(lm_run "$(lm_cache)" c_v3_file_result)"
  ck "n23/writer/file-result-defined" "yes" "$(lm_v "$r" have)"
  ck "n23/writer/file-result-map" "PASS=PASS|completed FAIL=FAIL|completed SKIP=SKIP|completed TIMEOUT=-|timeout UNRUNNABLE=-|unrunnable UNSUPPORTED=-|unsupported" "$(lm_v "$r" map)"
  r="$(lm_run "$(lm_cache)" c_v3_append)"
  ck "n23/writer/append-five-fields-invalid-as-question" "R|5|PASS|completed|ap.sh;R|6|-|timeout|to.sh;R|7|?|completed|bv.sh;R|8|FAIL|?|bt.sh;R|9|?|?|na.sh;" "$(lm_v "$r" rows)"
  ck "n23/writer/appended-rows-readable" "5 6 7 8 9" "$(lm_v "$r" vals)"
  r="$(lm_run "$(lm_cache)" c_v3_file_result_default)"
  ck "n23/writer/file-result-empty-and-unknown-are-question" "empty=?|? BOGUS=?|?" "$(lm_v "$r" map)"
  r="$(lm_run "$(lm_cache)" c_v3_append_width)"
  ck "n23/writer/append-token-16-kept-17-question" "R|3|ABCDEFGHIJKLMNOP|abcdefghijklmnop|w16.sh;R|4|?|?|w17.sh;" "$(lm_v "$r" rows)"
}

run_v3_harvest_cases() {
  local r
  c21_runner_load; r="$C21_OUT"
  ck "n23/harvest/timeout-and-pass-recorded" "q1.sh=PASS|completed slow.sh=-|timeout" "$(lm_v "$r" timeout_vt)"
  ck "n23/harvest/fail-and-pass-recorded" "bad.sh=FAIL|completed q1.sh=PASS|completed" "$(lm_v "$r" fail_vt)"
}
