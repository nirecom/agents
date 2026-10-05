# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/expiry-cases.sh
# Tests: bin/lib/run-all-durations-consolidate.sh
# Tags: tests, bin, ledger, durations, consolidate, retention, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n20 (1)-(8) (#2079 S7b): the 30-day retention judged on the winning value's provenance,
# computed from the stamp (calendar arithmetic, not mtime), and the base's `#run` layout.

[ "${DC_LIB_LOADED:-0}" = "1" ] || . "${BASH_SOURCE[0]%/*}/_lib-consolidate.sh"

# ---- child side ---------------------------------------------------------------

# c20_edge <keep-stamp> <drop-stamp> — exactly 30 days before "now", and one second more.
c20_edge() {
  dc_plant "$1-1.closed" 30 "#os $DC_L" 1:keep.sh
  dc_plant "$2-2.closed" 30 "#os $DC_L" 2:drop.sh
}

c20_winner() {
  dc_plant "20260201T000000-1.closed" 30 "#os $DC_L" 1:w.sh 1:gone.sh
  dc_plant "${DC_D}T000000-2.closed" 30 "#os $DC_L" 2:w.sh
}

# (3) provenances planted out of order, two records sharing P2.
c20_layout() {
  dc_plant "${DC_D}T030000-3.closed" 30 "#os $DC_L" 3:c.sh
  dc_plant "${DC_D}T010000-1.closed" 30 "#os $DC_L" 1:a.sh
  dc_plant "${DC_D}T020000-2.closed" 30 "#os $DC_L" 2:b.sh
}
c20_layout_shared() { dc_plant "${DC_D}T020000-2.closed" 30 "#os $DC_L" 2:b.sh 4:d.sh; }
c20_runs() { dc_body | tr ';' '\n' | grep '^#run' | tr '\n' ';'; }

c20_all_expired() {
  dc_plant "20260101T000000-1.closed" 30 "#os $DC_L" 1:x.sh
  dc_plant "20260102T000000-01" 30 "#os $DC_L" "#run 20260102T000000-2" 2:y.sh
}

# (6) legacy `dur.1.*` segments (Windows stub): one stamped 31 days before now, one 2 days.
c20_legacy() {
  local t; t="$(lm_oldtok "$LM_W26300")"
  lm_plant_dur "dur.1.$t.20260207T110000-5.log" 120 - "1:old.sh"
  lm_plant_dur "dur.1.$t.20260308T110000-6.log" 120 - "2:new.sh"
}

c20_env_days() {
  say days "${RUN_ALL_DUR_RETENTION_DAYS:-unset}"
  dc_plant "20260308T120000-1.closed" 30 "#os $DC_L" 2:two.sh
  dc_plant "20260207T120000-2.closed" 30 "#os $DC_L" 3:old.sh
}

# (8) a base named 2 days back whose `#run` lines say 31 days and 2 days.
c20_aside_prov() {
  dc_plant "20260308T120000-01" 30 "#os $DC_L" "#run 20260207T120000-76" 1:old.sh "#run 20260308T120000-77" 2:new.sh
  dc_plant "20260309T120000-9.closed" 30 "#os $DC_L" 5:z.sh
}

# ---- parent side --------------------------------------------------------------

# c20_edge_ck <label> <now> <keep-stamp> <drop-stamp>
c20_edge_ck() {
  local c
  c="$(lm_cache)"
  lm_run "$c" c20_edge "$3" "$4"; lm_run "$c" dc_cons "$2"
  ck "n20/$1" "1 -" "$(lm_v "$(lm_run "$c" dc_report keep.sh drop.sh)" vals)"
}

run_expiry_boundary_cases() {
  dc_lib_ck n20/1
  # DC_NOW is 2026-03-10 12:00: 30 days back crosses February (28 days) to 02-08 12:00.
  c20_edge_ck "1/exactly-30-days-kept-one-second-more-dropped" "$DC_NOW" "20260208T120000" "20260208T115959"
  c20_edge_ck "4/month-end-non-leap-february" "20250301T000000" "20250130T000000" "20250129T235959"
  c20_edge_ck "4/year-end" "20260115T060000" "20251216T060000" "20251216T055959"
  c20_edge_ck "4/leap-day" "20240310T000000" "20240209T000000" "20240208T235959"
  c20_edge_ck "4/leap-year-end-of-february" "20240301T000000" "20240131T000000" "20240130T235959"
}

run_expiry_winner_cases() {
  local c r
  dc_lib_ck n20/2; c="$(lm_cache)"
  lm_run "$c" c20_winner; lm_run "$c" dc_cons
  ck "n20/2/expiry-judged-on-winner" "2 -" "$(lm_v "$(lm_run "$c" dc_report w.sh gone.sh)" vals)"
  c="$(lm_cache)"
  lm_run "$c" c20_layout; lm_run "$c" dc_cons
  ck "n20/3/one-run-per-provenance-oldest-first" \
    "#os $DC_L;#run ${DC_D}T010000-1;R|1|a.sh;#run ${DC_D}T020000-2;R|2|b.sh;#run ${DC_D}T030000-3;R|3|c.sh;" \
    "$(lm_run "$c" dc_body)"
  c="$(lm_cache)"
  lm_run "$c" c20_layout_shared; lm_run "$c" dc_cons
  ck "n20/3/shared-provenance-one-run-line" "#run ${DC_D}T020000-2;" "$(lm_run "$c" c20_runs)"
  c="$(lm_cache)"
  lm_run "$c" c20_all_expired; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report x.sh y.sh)"
  ck "n20/5/all-expired-no-base-inputs-deleted" "- -||0" "$(lm_v "$r" vals)|$(lm_v "$r" ls)|$(lm_v "$r" ncons)"
}

run_expiry_migrated_cases() {
  local c r
  dc_lib_ck n20/6; c="$(lm_cache)"
  lm_run "$c" c20_legacy; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report old.sh new.sh)"
  ck "n20/6/31-day-migrated-record-dropped" "- 2" "$(lm_v "$r" vals)"
  ck "n20/6/legacy-inputs-gone" "0:0" "$(lm_run "$c" lm_count 'dur.1.*'):$(lm_run "$c" lm_count '*.migrating')"
}

run_expiry_env_cases() {
  local c r
  dc_lib_ck n20/7; c="$(lm_cache)"
  r="$(export RUN_ALL_DUR_RETENTION_DAYS=0; lm_run "$c" c20_env_days)"
  ck "n20/7/library-overrides-env-retention" "30" "$(lm_v "$r" days)"
  r="$(export RUN_ALL_DUR_RETENTION_DAYS=0; lm_run "$c" dc_cons; lm_run "$c" dc_report two.sh old.sh)"
  ck "n20/7/env-retention-ignored-library-30-days" "2 -" "$(lm_v "$r" vals)"
  c="$(lm_cache)"
  lm_run "$c" c20_aside_prov; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report old.sh new.sh z.sh)"
  ck "n20/8/run-line-dates-records-after-aside" "- 2 5" "$(lm_v "$r" vals)"
  case ";$(lm_run "$c" c20_runs)" in
    *";#run 20260308T120000-77;"*) pass "n20/8/kept-key-provenance-unchanged" ;;
    *) fail "n20/8/kept-key-provenance-unchanged" "runs=[$(lm_run "$c" c20_runs)]" ;;
  esac
}
