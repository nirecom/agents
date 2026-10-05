# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/abandoned-cases.sh
# Tests: bin/lib/run-all-durations-consolidate.sh
# Tags: tests, bin, ledger, durations, consolidate, concurrency, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n19 (1)-(8) (#2079 S7b): the 6-hour abandon boundary, a misjudged live writer, the lock,
# and every interruption or failure point of publish-then-delete converging next round.

[ "${DC_LIB_LOADED:-0}" = "1" ] || . "${BASH_SOURCE[0]%/*}/_lib-consolidate.sh"

# ---- child side ---------------------------------------------------------------

c19_boundary() {
  dc_plant "${DC_D}T010000-21" 365 "#os $DC_L" 1:a.sh
  dc_plant "${DC_D}T020000-22" 355 "#os $DC_L" 2:b.sh
}

# (1b) one minute either side of 360; exactly 360 is not planted: `find -mmin` works in whole
# minutes, so the result at 360 flips with the seconds the run takes (timing-fragile).
c19_tight() {
  dc_plant "${DC_D}T030000-24" 361 "#os $DC_L" 3:c.sh
  dc_plant "${DC_D}T040000-25" 359 "#os $DC_L" 4:d.sh
}
c19_tight_sum() { say sum "$(lm_sum "$(lm_dur_dir)/$(dc_name "${DC_D}T040000-25")")"; }

# (2) this child is a live writer whose 6-hour-quiet segment another round takes away.
c19_misjudged() {
  dc_plant "${DC_D}T010000-23" 365 "#os $DC_L" 1:a.sh
  run_all_dur_repo_id "$LM_REPO" >/dev/null
  RUN_ALL_DUR_SEGMENT="$(lm_dur_dir)/$(dc_name "${DC_D}T010000-23")"
  RUN_ALL_DUR_WRITE_OK=1; RUN_ALL_DUR_OS_ATTR="$DC_L"
  dc_cons
  say renamed "$([ -e "$RUN_ALL_DUR_SEGMENT" ] && echo 0 || echo 1)"
  run_all_dur_append "late.sh" 6
  say head "$(head -n 1 "$RUN_ALL_DUR_SEGMENT" 2>/dev/null)"
}

c19_late_line() { dc_plant "${DC_D}T010000-31.closed" 30 "#os $DC_L" 1:a.sh; }
c19_cons_seam() {
  run_all_dur_before_delete() {
    case "$1" in *-31.consolidating.log) printf '%s|7|late.sh\n' "$(lm_rid)" >> "$1" ;; esac
    return 0
  }
  dc_cons
}

c19_lock() { mkdir -p "$(lm_dur_dir)/.ledger.lock"; lm_age "$(lm_dur_dir)/.ledger.lock" "$1"; }
c19_writer() {
  run_all_dur_writer_init "$LM_REPO"
  say own "$([ -n "$RUN_ALL_DUR_SEGMENT" ] && [ -f "$RUN_ALL_DUR_SEGMENT" ] && echo 1 || echo 0)"
}

# (5) a crash after publish, before delete: new base, moved-aside old base and input all present.
c19_after_publish() {
  dc_plant "${DC_D}T020000-01" 30 "#os $DC_L" "#run ${DC_D}T000000-5" 1:a.sh "#run ${DC_D}T020000-41" 2:b.sh
  dc_plant "${DC_D}T000000-01.consolidating" 30 "#os $DC_L" "#run ${DC_D}T000000-5" 1:a.sh
  dc_plant "${DC_D}T020000-41.consolidating" 30 "#os $DC_L" 2:b.sh
}

# (5b) two attributes; the second publish fails through the seam.
c19_two_attr_inputs() {
  dc_plant "${DC_D}T000000-01" 30 "#os $DC_L" "#run ${DC_D}T000000-1" 1:a.sh
  dc_plant "${DC_D}T010000-41.closed" 30 "#os $DC_L" 2:b.sh
  dc_plant "${DC_D}T020000-42.closed" 30 "#os $DC_W" 3:c.sh
}
c19_cons_fail_second() {
  run_all_dur_before_publish() { case "$1" in *-01.log) return 0 ;; *) return 1 ;; esac; }
  dc_cons
}

# (5c) stopped mid-publish: A's new base published, B and C old bases moved aside, A's input
# still under its consolidating name.
c19_mid_publish() {
  dc_plant "${DC_D}T030000-01" 30 "#os $DC_A" "#run ${DC_D}T030000-51" 1:a.sh
  dc_plant "${DC_D}T000000-01.consolidating" 30 "#os $DC_L" "#run ${DC_D}T000000-2" 2:b.sh
  dc_plant "${DC_D}T000000-02.consolidating" 30 "#os $DC_W" "#run ${DC_D}T000000-3" 3:c.sh
  dc_plant "${DC_D}T030000-51.consolidating" 30 "#os $DC_A" 1:a.sh
}

# (6) the closed segment's rename target already exists.
c19_target_taken() {
  dc_plant "${DC_D}T010000-61.closed" 30 "#os $DC_L" 1:a.sh
  dc_plant "${DC_D}T010000-61.consolidating" 30 "#os $DC_L" 2:b.sh
}
c19_closed_sum() { say sum "$(lm_sum "$(lm_dur_dir)/$(dc_name "${DC_D}T010000-61.closed")")"; }

c19_tmps() {
  dc_plant "${DC_D}T010000-71.closed" 30 "#os $DC_L" 1:a.sh
  printf 'x\n' > "$(lm_dur_dir)/.dur.tmp.99999.1"; lm_age "$(lm_dur_dir)/.dur.tmp.99999.1" 11
  printf 'x\n' > "$(lm_dur_dir)/.dur.tmp.99998.1"; lm_age "$(lm_dur_dir)/.dur.tmp.99998.1" 5
}
c19_tmp_left() { say old "$(lm_count '.dur.tmp.99999.*')"; say young "$(lm_count '.dur.tmp.99998.*')"; }

# (8) moving the old base aside fails (Windows: another process holds it open).
c19_aside_inputs() {
  dc_plant "${DC_D}T000000-01" 30 "#os $DC_L" "#run ${DC_D}T000000-1" 1:a.sh
  dc_plant "${DC_D}T010000-81.closed" 30 "#os $DC_L" 2:b.sh
}
c19_cons_aside_fails() {
  mv() { local a=("$@"); case "${a[$# - 1]}" in *-01.consolidating.log) return 1 ;; esac; command mv "$@"; }
  dc_cons
}

# ---- parent side --------------------------------------------------------------

run_abandon_boundary_cases() {
  local c r
  dc_lib_ck n19/1; c="$(lm_cache)"
  lm_run "$c" c19_boundary; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n19/1/365-min-open-consolidated-355-kept" \
    "dur.2.T.${DC_D}T010000-01.log dur.2.T.${DC_D}T020000-22.log|1 2" "$(lm_v "$r" ls)|$(lm_v "$r" vals)"
  c="$(lm_cache)"
  r="$(lm_run "$c" c19_misjudged)"
  # The header check below only means something once the round really took the segment.
  ck "n19/2/quiet-live-segment-taken-by-round" "1" "$(lm_v "$r" renamed)"
  ck "n19/2/append-recreates-os-header" "#os $DC_L" "$(lm_v "$r" head)"
  ck "n19/2/old-and-new-lines-readable" "1 6" "$(lm_v "$(lm_run "$c" dc_report a.sh late.sh)" vals)"
}

run_abandon_tight_boundary_cases() {
  local c r before
  dc_lib_ck n19/1b; c="$(lm_cache)"
  lm_run "$c" c19_tight
  before="$(lm_v "$(lm_run "$c" c19_tight_sum)" sum)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report c.sh d.sh)"
  ck "n19/1b/361-min-open-consolidated-359-kept" \
    "dur.2.T.${DC_D}T030000-01.log dur.2.T.${DC_D}T040000-25.log|1|3 4" "$(lm_v "$r" ls)|$(lm_v "$r" nb)|$(lm_v "$r" vals)"
  ck "n19/1b/359-min-open-unchanged" "$before" "$(lm_v "$(lm_run "$c" c19_tight_sum)" sum)"
  [ "$before" != "none" ] || fail "n19/1b/fixture-planted" "359-min segment missing before the round"
}

run_abandon_late_line_cases() {
  local c r
  dc_lib_ck n19/3; c="$(lm_cache)"
  lm_run "$c" c19_late_line; lm_run "$c" c19_cons_seam
  r="$(lm_run "$c" dc_report a.sh late.sh)"
  ck "n19/3/changed-input-not-deleted" "1|1 7" "$(lm_v "$r" ncons)|$(lm_v "$r" vals)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh late.sh)"
  ck "n19/3/next-round-reads-late-line-and-deletes" "1 7|0|1" "$(lm_v "$r" vals)|$(lm_v "$r" ncons)|$(lm_v "$r" nb)"
}

run_abandon_lock_cases() {
  local c r before
  dc_lib_ck n19/4; c="$(lm_cache)"
  lm_run "$c" c19_late_line; lm_run "$c" c19_lock 1
  before="$(lm_run "$c" dc_snap)"
  lm_run "$c" dc_cons
  ck "n19/4/live-lock-no-op" "$before" "$(lm_run "$c" dc_snap)"
  ck "n19/4/writer-still-creates-own-segment" "1" "$(lm_v "$(lm_run "$c" c19_writer)" own)"
  lm_run "$c" c19_lock 11; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh)"
  ck "n19/4/stale-lock-removed-and-round-runs" "1|0|1|0" \
    "$(lm_v "$r" vals)|$(lm_v "$r" nclosed)|$(lm_v "$r" nb)|$(lm_v "$r" lock)"
}

run_abandon_publish_cases() {
  local c r
  dc_lib_ck n19/5; c="$(lm_cache)"
  lm_run "$c" c19_after_publish; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n19/5/after-publish-converges" "1 2|1|0" "$(lm_v "$r" vals)|$(lm_v "$r" nb)|$(lm_v "$r" ncons)"
  c="$(lm_cache)"
  lm_run "$c" c19_two_attr_inputs; lm_run "$c" c19_cons_fail_second
  r="$(lm_run "$c" dc_report a.sh b.sh c.sh)"
  ck "n19/5b/only-first-base-published" "1|$DC_L" "$(lm_v "$r" nb)|$(lm_v "$r" heads)"
  ck "n19/5b/no-input-deleted-lock-released" "3|0|0|1 2 3" \
    "$(lm_v "$r" ncons)|$(lm_v "$r" lock)|$(lm_v "$r" ntmp)|$(lm_v "$r" vals)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh c.sh)"
  ck "n19/5b/next-round-converges" "2|$DC_L,$DC_W|0|1 2 3" \
    "$(lm_v "$r" nb)|$(lm_v "$r" heads)|$(lm_v "$r" ncons)|$(lm_v "$r" vals)"
  c="$(lm_cache)"
  lm_run "$c" c19_mid_publish
  ck "n19/5c/mid-publish-state-all-keys-readable" "1 2 3" "$(lm_v "$(lm_run "$c" dc_report a.sh b.sh c.sh)" vals)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh c.sh)"
  ck "n19/5c/converges-to-three-bases" "3|$DC_A,$DC_L,$DC_W|0|1 2 3" \
    "$(lm_v "$r" nb)|$(lm_v "$r" heads)|$(lm_v "$r" ncons)|$(lm_v "$r" vals)"
}

run_abandon_claim_cases() {
  local c r before
  dc_lib_ck n19/6; c="$(lm_cache)"
  lm_run "$c" c19_target_taken
  before="$(lm_v "$(lm_run "$c" c19_closed_sum)" sum)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n19/6/taken-target-closed-segment-skipped" "$before|1 2" "$(lm_v "$(lm_run "$c" c19_closed_sum)" sum)|$(lm_v "$r" vals)"
  c="$(lm_cache)"
  lm_run "$c" c19_tmps; lm_run "$c" dc_cons
  r="$(lm_run "$c" c19_tmp_left)"
  ck "n19/7/stale-temp-removed-young-kept" "0:1" "$(lm_v "$r" old):$(lm_v "$r" young)"
}

run_abandon_aside_fail_cases() {
  local c r before
  dc_lib_ck n19/8; c="$(lm_cache)"
  lm_run "$c" c19_aside_inputs
  before="$(lm_run "$c" dc_snap)"
  lm_run "$c" c19_cons_aside_fails
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n19/8/aside-failure-publishes-and-deletes-nothing" "$before" "$(lm_run "$c" dc_snap)"
  ck "n19/8/lock-released-keys-readable" "0|1 2" "$(lm_v "$r" lock)|$(lm_v "$r" vals)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n19/8/next-round-converges" "1|0|0|1 2" \
    "$(lm_v "$r" nb)|$(lm_v "$r" nclosed)|$(lm_v "$r" ncons)|$(lm_v "$r" vals)"
}
