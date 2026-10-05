# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/attr-cases.sh
# Tests: bin/lib/run-all-durations-consolidate.sh
# Tags: tests, bin, ledger, durations, consolidate, os-attribute, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n18 (16) (#2079 S6/S7b): one (repo, key) measured under two OS attributes. The winner is
# global per (repo, key) by provenance, lands in its own attribute's base only, and later
# rounds neither regress, duplicate nor lose it.

[ "${DC_LIB_LOADED:-0}" = "1" ] || . "${BASH_SOURCE[0]%/*}/_lib-consolidate.sh"
CA_OLD="Windows/10.0.26200"

# ---- child side ---------------------------------------------------------------

# Old attribute measured first (k=5), the current one later (k=9).
ca_round1() {
  dc_plant "${DC_D}T010000-11.closed" 30 "#os $CA_OLD" 5:k.sh 1:o.sh
  dc_plant "${DC_D}T020000-12.closed" 30 "#os $DC_W" 9:k.sh 2:c.sh
}
# An older-provenance segment under the old attribute: nothing may regress.
ca_older() { dc_plant "${DC_D}T000000-10.closed" 30 "#os $CA_OLD" 3:k.sh 7:o.sh; }
# A newer-provenance segment under the old attribute: k moves to the old attribute's base.
ca_newer_old() { dc_plant "${DC_D}T030000-13.closed" 30 "#os $CA_OLD" 4:k.sh; }
# Fresh ledger, reversed: the current attribute is older, the old attribute newer.
ca_reversed() {
  dc_plant "${DC_D}T010000-21.closed" 30 "#os $DC_W" 5:k.sh
  dc_plant "${DC_D}T020000-22.closed" 30 "#os $CA_OLD" 9:k.sh
}

ca_report() {
  say vals "$(lm_get k.sh o.sh c.sh)"
  say body "$(dc_body)"
  say ls "$(dc_ls)"
  say nk "$(dc_body | tr ';' '\n' | grep -c '|k\.sh$')"
}

# ---- parent side --------------------------------------------------------------

run_attr_cross_cases() {
  local c r b body1 body3 snap
  dc_lib_ck n18/16; c="$(lm_cache)"
  b="dur.2.T.${DC_D}"
  body1="#os $CA_OLD;#run ${DC_D}T010000-11;R|1|o.sh;#os $DC_W;#run ${DC_D}T020000-12;R|2|c.sh;R|9|k.sh;"
  lm_run "$c" ca_round1; lm_run "$c" dc_cons
  r="$(lm_run "$c" ca_report)"
  ck "n18/16/newest-provenance-wins-across-attributes" "9 1 2" "$(lm_v "$r" vals)"
  ck "n18/16/winner-only-in-its-own-attribute-base" "$body1" "$(lm_v "$r" body)"
  ck "n18/16/one-base-per-attribute-shared-s" "${b}T020000-01.log ${b}T020000-02.log" "$(lm_v "$r" ls)"
  ck "n18/16/no-duplicate-key" "1" "$(lm_v "$r" nk)"

  lm_run "$c" ca_older; lm_run "$c" dc_cons
  r="$(lm_run "$c" ca_report)"
  ck "n18/16/round2-older-input-no-regression" "9 1 2" "$(lm_v "$r" vals)"
  ck "n18/16/round2-bases-unchanged" "$body1|${b}T020000-01.log ${b}T020000-02.log" \
    "$(lm_v "$r" body)|$(lm_v "$r" ls)"

  lm_run "$c" ca_newer_old
  ck "n18/16/round3-reader-before-consolidation" "4 1 2" "$(lm_v "$(lm_run "$c" ca_report)" vals)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" ca_report)"
  body3="#os $CA_OLD;#run ${DC_D}T010000-11;R|1|o.sh;#run ${DC_D}T030000-13;R|4|k.sh;#os $DC_W;#run ${DC_D}T020000-12;R|2|c.sh;"
  ck "n18/16/round3-newer-old-attribute-wins" "4 1 2" "$(lm_v "$r" vals)"
  ck "n18/16/round3-key-moves-to-old-attribute-base" "$body3" "$(lm_v "$r" body)"
  ck "n18/16/round3-no-duplicate-no-loss" "1|${b}T030000-01.log ${b}T030000-02.log" \
    "$(lm_v "$r" nk)|$(lm_v "$r" ls)"

  snap="$(lm_run "$c" dc_snap)"
  lm_run "$c" dc_cons
  ck "n18/16/round4-rerun-stable" "$snap|4 1 2" "$(lm_run "$c" dc_snap)|$(lm_v "$(lm_run "$c" ca_report)" vals)"

  c="$(lm_cache)"
  lm_run "$c" ca_reversed; lm_run "$c" dc_cons
  r="$(lm_run "$c" ca_report)"
  ck "n18/16/reversed-newer-old-attribute-wins" "9 - -" "$(lm_v "$r" vals)"
  ck "n18/16/reversed-loser-attribute-gets-no-base" "#os $CA_OLD;#run ${DC_D}T020000-22;R|9|k.sh;|${b}T020000-01.log" \
    "$(lm_v "$r" body)|$(lm_v "$r" ls)"
}
