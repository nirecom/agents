# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/robust-cases.sh
# Tests: bin/lib/run-all-ledger-migrate.sh
# Tags: tests, bin, ledger, migration, concurrency, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n17 (9)-(13), (15), (15b), 16-17 (#2079 S7): quiet path, lock, 60-minute window, foreign repos,
# invalid lines, appends around the claim, interruption recovery and a retried failed claim rename.

# ---- child side ---------------------------------------------------------------

# c_leftovers <name>... — ledger entries other than the named ones.
c_leftovers() {
  local e others=""
  for e in $(lm_ls); do
    case " $* " in *" $e "*) continue ;; esac
    others="$others $e"
  done
  say others "$others"
  say n "$(lm_ls | wc -w | tr -d ' ')"
}

c_leftovers_new() { c_leftovers "$1" "dur.2.$(lm_tok).${LM_DAY}T000001-5.log"; }
c_plant_cur_new() { lm_plant_dur "dur.2.$(lm_tok).${LM_DAY}T000001-5.log" 120 "Windows/10.0.26300" "1:n1"; }
c_plant_old() { lm_plant_dur "dur.1.$(lm_oldtok "$LM_W26300").${LM_DAY}T000001-21.log${3:-}" "$1" - "$2"; }
c_age_old() { lm_age "$(lm_dur_dir)/dur.1.$(lm_oldtok "$LM_W26300").${LM_DAY}T000001-21.log${2:-}" "$1"; }

c_lock() { mkdir -p "$(lm_dur_dir)/.ledger.lock"; lm_age "$(lm_dur_dir)/.ledger.lock" "$1"; }

# c_state <keys> — values, lock, outputs, claims and the old file's checksum.
c_state() {
  local f old
  old="$(lm_dur_dir)/dur.1.$(lm_oldtok "$LM_W26300").${LM_DAY}T000001-21.log"
  say vals "$(lm_get $1)"
  say lock "$([ -e "$(lm_dur_dir)/.ledger.lock" ] && echo 1 || echo 0)"
  say outs "$(lm_count "dur.2.$(lm_tok).*-0*.log")"
  say mig "$(lm_count '*.migrating')"
  say oldsum "$(lm_sum "$old")"
  say body "$(for f in "$(lm_dur_dir)"/dur.2."$(lm_tok)".*-0*.log; do [ -f "$f" ] && grep -v '^#' "$f"; done | tr '\n' ';')"
  say rid "$(lm_rid)"
}

# c_plant_raw <lines...> — one old segment holding exact lines; `RID` becomes this repo's id.
c_plant_raw() {
  local rid f l; rid="$(lm_rid)"
  f="$(lm_dur_dir)/dur.1.$(lm_oldtok "$LM_W26300").${LM_DAY}T000001-21.log"
  mkdir -p "$(lm_dur_dir)"; : > "$f"
  for l in "$@"; do printf '%s\n' "${l//RID/$rid}" >> "$f"; done
  lm_age "$f" 120
}

c_init_seam() {
  run_all_dur_before_delete() { printf '%s|9|late/key\n' "$(lm_rid)" >> "$1"; }
  run_all_dur_writer_init "$LM_REPO"
}

# A second old segment (key m3), and its name / checksum / claim state.
c_old2_path() { printf '%s/dur.1.%s.%sT000002-22.log' "$(lm_dur_dir)" "$(lm_oldtok "$LM_W26300")" "$LM_DAY"; }
c_plant_old2() { lm_plant_dur "$(basename "$(c_old2_path)")" 120 - "7:m3"; }
c_old2() {
  local f; f="$(c_old2_path)"
  say name "${f##*/}"; say sum "$(lm_sum "$f")"; say mig2 "$([ -e "$f.migrating" ] && echo 1 || echo 0)"
}
c_init_mvfail() { lm_mv_fail_claim; run_all_dur_writer_init "$LM_REPO"; }
c_init_cut() { lm_mv_cut_publish; run_all_dur_writer_init "$LM_REPO"; }

# c_shape_vals <key>... — one `v<i>=<value>` line per key, `-` when it does not resolve.
c_shape_vals() {
  local i=0 k
  for k in "$@"; do i=$((i + 1)); say "v$i" "$(lm_get "$k")"; done
}

# ---- parent side --------------------------------------------------------------

semi_sort() { printf '%s' "$1" | tr ';' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ';'; }

run_migrate_quiet_cases() {
  local c seg r
  lm_win; c="$(lm_cache)"
  seg="$(lm_v "$(lm_run "$c" c_init)" seg)"
  r="$(lm_run "$c" c_leftovers "$seg")"
  ck "n17/9/empty-dir-only-own-segment" ":1" "$(lm_v "$r" others):$(lm_v "$r" n)"
  c="$(lm_cache)"
  lm_run "$c" c_plant_cur_new
  seg="$(lm_v "$(lm_run "$c" c_init)" seg)"
  r="$(lm_run "$c" c_leftovers_new "$seg")"
  ck "n17/9/new-only-dir-gains-nothing" ":2" "$(lm_v "$r" others):$(lm_v "$r" n)"
}

run_migrate_window_lock_cases() {
  local c r before
  lm_win
  c="$(lm_cache)"
  lm_run "$c" c_plant_old 30 "4:f1"
  before="$(lm_v "$(lm_run "$c" c_state f1)" oldsum)"
  [ "$before" != "none" ] && [ -n "$before" ] || fail "n17/10/fixture-planted" "old segment missing"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state f1)"
  ck "n17/10/young-old-segment-untouched" "$before:0:0" "$(lm_v "$r" oldsum):$(lm_v "$r" outs):$(lm_v "$r" mig)"
  c="$(lm_cache)"
  lm_run "$c" c_plant_old 120 "4:f1"
  lm_run "$c" c_lock 1
  before="$(lm_v "$(lm_run "$c" c_state f1)" oldsum)"
  [ "$before" != "none" ] && [ -n "$before" ] || fail "n17/11/fixture-planted" "old segment missing"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state f1)"
  ck "n17/11/live-lock-blocks" "$before:0:0:1" "$(lm_v "$r" oldsum):$(lm_v "$r" outs):$(lm_v "$r" mig):$(lm_v "$r" lock)"
  c="$(lm_cache)"
  lm_run "$c" c_plant_old 120 "4:f1"
  lm_run "$c" c_lock 15
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state f1)"
  ck "n17/11/stale-lock-reclaimed" "4:none:1:0" "$(lm_v "$r" vals):$(lm_v "$r" oldsum):$(lm_v "$r" outs):$(lm_v "$r" lock)"
}

run_migrate_line_cases() {
  local c r rid long
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_raw "RID|4|mine/k" "ffffffffffffffff|8|other/key"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state mine/k)"; rid="$(lm_v "$r" rid)"
  ck "n17/12/other-repo-rows-kept" "4|$(semi_sort "$rid|4|mine/k;ffffffffffffffff|8|other/key;")" \
    "$(lm_v "$r" vals)|$(semi_sort "$(lm_v "$r" body)")"
  long="$(printf 'k%.0s' $(seq 1 600))"
  c="$(lm_cache)"
  lm_run "$c" c_plant_raw "RID|4|ok/key" "RID|12345|bad/a" "RID|x|bad/b" "abc|3|bad/c" "RID|3|" "RID|3|a|b" "RID|5|$long"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state ok/key)"
  ck "n17/13/only-reader-valid-lines-carried" "4|$(lm_v "$r" rid)|4|ok/key;:0" "$(lm_v "$r" vals)|$(lm_v "$r" body):$(lm_v "$r" mig)"
}

# Review C5, table-driven: each row is `label:expected:key-suffix:line`; KEY in the line is
# the row's key (k<row> + suffix), RID this repo's id. Expected `-` = the line must be dropped.
run_migrate_line_shape_cases() {
  local c r row i=0 label want sfx line n="" long400 long600 v
  local -a keys=() lines=() labels=() wants=()
  long400="$(printf 'x%.0s' $(seq 1 400))"; long600="$(printf 'x%.0s' $(seq 1 600))"
  for row in \
    "min-secs:0::RID|0|KEY" "max-four-digits:9999::RID|9999|KEY" "leading-zeros:007::RID|007|KEY" \
    "key-with-space:5: sp ace:RID|5|KEY" "key-with-slash-and-dot:6:/a.b:RID|6|KEY" \
    "key-400-bytes:7:$long400:RID|7|KEY" \
    "five-digit-secs:-::RID|12345|KEY" "non-numeric-secs:-::RID|x|KEY" "negative-secs:-::RID|-1|KEY" \
    "empty-secs:-::RID||KEY" "pipe-in-key:-::RID|3|KEY|x" "short-repo-id:-::abc|3|KEY" \
    "long-repo-id:-::RIDX|3|KEY" "commented-out:-::#RID|3|KEY" "other-repo:-::ffffffffffffffff|3|KEY" \
    "line-over-512-bytes:-:$long600:RID|3|KEY"; do
    i=$((i + 1))
    IFS=: read -r label want sfx line <<< "$row"
    labels+=("$label"); wants+=("$want"); keys+=("k$i$sfx"); lines+=("${line//KEY/k$i$sfx}")
  done
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_raw "${lines[@]}"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_shape_vals "${keys[@]}")"
  for i in "${!labels[@]}"; do
    v="$(lm_v "$r" "v$((i + 1))")"
    ck "n17/19/line-shape-${labels[$i]}" "${wants[$i]}" "$v"
  done
}

# (14) a real runner: old-format measurements still drive longest-first after the next run.
run_migrate_runner_lpt_cases() {
  local out r tiers
  out="$(run_with_timeout 280 env -u RUN_ALL_DUR_REPO_ID -u RUN_ALL_DUR_HOST_TOKEN AGENTS_DIR="$AGENTS_DIR" \
    bash "$LM_PARTS/_runner-lpt.sh" 2>/dev/null)"
  r="$(printf '%s\n' "$out" | sed -n 's/^R14 //p')"
  ck "n17/14/fixture-warm-run-measured" "3" "$(lm_v "$r" warm)"
  if [ "$(lm_v "$r" planted)" -ge 1 ] 2>/dev/null; then
    pass "n17/14/fixture-old-segments-planted"
  else
    fail "n17/14/fixture-old-segments-planted" "planted=[$(lm_v "$r" planted)]"
  fi
  ck "n17/14/plan-longest-first" "z2.sh z3.sh z1.sh " "$(lm_v "$r" order)"
  tiers="$(lm_v "$r" tiers)"
  case "$tiers" in
    *z2.sh:99*|*z3.sh:99*|"") fail "n17/14/old-measurements-resolved" "tiers=[$tiers]" ;;
    *) pass "n17/14/old-measurements-resolved" ;;
  esac
  ck "n17/14/old-format-segments-migrated" "0" "$(lm_v "$r" old_left)"
}

run_migrate_late_append_cases() {
  local c r before
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_old 120 "4:m1" ".migrating"
  lm_run "$c" c_plant_old 5 "6:m2"
  before="$(lm_v "$(lm_run "$c" c_state m1)" oldsum)"
  [ "$before" != "none" ] && [ -n "$before" ] || fail "n17/15/fixture-planted" "young original missing"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state "m1 m2")"
  ck "n17/15/claimed-file-migrated" "4:0" "$(lm_v "$r" vals | cut -d' ' -f1):$(lm_v "$r" mig)"
  ck "n17/15/reborn-original-left-alone" "$before" "$(lm_v "$r" oldsum)"
  lm_run "$c" c_age_old 61
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state "m1 m2")"
  ck "n17/15/reborn-original-migrated-later" "4 6:none:0" "$(lm_v "$r" vals):$(lm_v "$r" oldsum):$(lm_v "$r" mig)"
  c="$(lm_cache)"
  lm_run "$c" c_plant_old 120 "4:m1"
  lm_run "$c" c_init_seam >/dev/null
  r="$(lm_run "$c" c_state "m1 late/key")"
  ck "n17/15b/changed-claim-not-deleted" "1" "$(lm_v "$r" mig)"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state "m1 late/key")"
  ck "n17/15b/late-line-migrated-next-round" "4 9:0" "$(lm_v "$r" vals):$(lm_v "$r" mig)"
}

# S7 recovery: a leftover claim is input whatever its age; a temp file older than 60 min
# left by an interrupted round is deleted by the next round.
run_migrate_recovery_cases() {
  local c r rec tmp
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_old 5 "4:m1" ".migrating"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state m1)"
  ck "n17/16/young-leftover-claim-migrated" "4:0" "$(lm_v "$r" vals):$(lm_v "$r" mig)"
  c="$(lm_cache)"; rec="$LM_TMP/cut.$RANDOM"
  lm_run "$c" c_plant_old 120 "4:m1"
  LM_XVAR="$rec"; lm_run "$c" c_init_cut >/dev/null; LM_XVAR=""
  tmp="$(cat "$rec" 2>/dev/null)"
  if [ -n "$tmp" ] && [ -e "$tmp" ]; then pass "n17/16/fixture-interrupted-temp-left"
  else fail "n17/16/fixture-interrupted-temp-left" "no temp recorded or it is gone: [$tmp]"; fi
  [ -n "$tmp" ] && lm_run "$c" lm_age "$tmp" 61
  lm_run "$c" c_lock 15
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state m1)"
  ck "n17/16/stale-temp-deleted" "0" "$([ -n "$tmp" ] && [ -e "$tmp" ] && echo 1 || echo 0)"
  ck "n17/16/interrupted-round-redone" "4:0:0" "$(lm_v "$r" vals):$(lm_v "$r" mig):$(lm_v "$r" lock)"
}

# S7: a file whose claim rename fails is skipped this round and migrated in the next.
run_migrate_rename_fail_cases() {
  local c r o before
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_old 120 "4:m1"
  lm_run "$c" c_plant_old2
  o="$(lm_run "$c" c_old2)"; before="$(lm_v "$o" sum)"
  [ "$before" != "none" ] && [ -n "$before" ] || fail "n17/17/fixture-planted" "second old segment missing"
  LM_XVAR="$(lm_v "$o" name)"; lm_run "$c" c_init_mvfail >/dev/null; LM_XVAR=""
  r="$(lm_run "$c" c_state "m1 m3")"; o="$(lm_run "$c" c_old2)"
  ck "n17/17/other-file-migrated" "4 -:none" "$(lm_v "$r" vals):$(lm_v "$r" oldsum)"
  ck "n17/17/failed-claim-untouched" "$before:0" "$(lm_v "$o" sum):$(lm_v "$o" mig2)"
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_state "m1 m3")"; o="$(lm_run "$c" c_old2)"
  ck "n17/17/retried-next-round" "4 7:none:0" "$(lm_v "$r" vals):$(lm_v "$o" sum):$(lm_v "$r" mig)"
}
