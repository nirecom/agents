# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/consolidate-cases.sh
# Tests: bin/lib/run-all-durations-consolidate.sh
# Tags: tests, bin, ledger, durations, consolidate, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n18 (1)-(15) (#2079 S7b): closed segments, old bases and leftovers fold into one base per
# OS attribute; each key keeps the value with the newest provenance, never the file order.

[ "${DC_LIB_LOADED:-0}" = "1" ] || . "${BASH_SOURCE[0]%/*}/_lib-consolidate.sh"

# ---- child side ---------------------------------------------------------------

c18_two_attrs() {
  dc_plant "${DC_D}T010000-101.closed" 30 "#os $DC_L" 5:a.sh 6:b.sh
  dc_plant "${DC_D}T020000-102.closed" 30 "#os $DC_W" 7:c.sh
  dc_plant "${DC_D}T030000-103.closed" 30 "#os $DC_L" 8:d.sh
}

# (2) base: K from T0, J from T2 (S = T2); a closed T1 segment has a newer K.
c18_prov() {
  dc_plant "${DC_D}T020000-01" 30 "#os $DC_L" "#run ${DC_D}T000000-10" 1:k.sh "#run ${DC_D}T020000-12" 2:j.sh
  dc_plant "${DC_D}T010000-11.closed" 30 "#os $DC_L" 9:k.sh
}

c18_same_prov() { dc_plant "${DC_D}T010000-11.closed" 30 "#os $DC_L" 3:x.sh 4:x.sh 5:y.sh; }

# (4) S is the newest provenance; then an open segment of that same second, younger value.
c18_name() {
  dc_plant "${DC_D}T040000-500.closed" 30 "#os $DC_L" 5:p.sh
  dc_plant "${DC_D}T030000-7.closed" 30 "#os $DC_L" 6:q.sh
}
c18_same_second() { dc_plant "${DC_D}T040000-9" 5 "#os $DC_L" 8:p.sh; }

# (5) one key per state, no consolidation: open, closed, consolidating, base, moved-aside base.
c18_states() {
  dc_plant "${DC_D}T010000-11" 5 "#os $DC_L" 1:o.sh
  dc_plant "${DC_D}T020000-12.closed" 5 "#os $DC_L" 2:c.sh
  dc_plant "${DC_D}T030000-13.consolidating" 5 "#os $DC_L" 3:g.sh
  dc_plant "${DC_D}T040000-01" 5 "#os $DC_L" "#run ${DC_D}T040000-14" 4:b.sh
  dc_plant "${DC_D}T000000-01.consolidating" 5 "#os $DC_L" "#run ${DC_D}T000000-15" 5:a.sh
  say vals "$(lm_get o.sh c.sh g.sh b.sh a.sh)"
}

c18_quiet_base() { dc_plant "${DC_D}T030000-01" 30 "#os $DC_L" "#run ${DC_D}T030000-5" 1:a.sh; }
c18_quiet_young() { dc_plant "${DC_D}T040000-6" 30 "#os $DC_L" 2:b.sh; }
c18_spied() {
  local d rc; d="$(lm_dur_dir)"; dc_spy_on
  run_all_dur_consolidate "$d" "$DC_NOW"; rc=$?
  dc_spy_off; say rc "$rc"
}

c18_two_s() {
  dc_plant "${DC_D}T010000-01" 30 "#os $DC_L" "#run ${DC_D}T010000-5" 1:a.sh
  dc_plant "${DC_D}T020000-01" 30 "#os $DC_L" "#run ${DC_D}T020000-6" 2:b.sh
}

# (8) a pre-revision migration output carries no `#run`: its name is the provenance.
c18_norun() {
  dc_plant "${DC_D}T010000-01" 30 "#os $DC_L" 4:m.sh
  dc_plant "${DC_D}T005000-3.closed" 30 "#os $DC_L" 9:m.sh
  dc_plant "${DC_D}T011000-4.closed" 30 "#os $DC_L" 7:n.sh
}
# The same with a name 31 days before DC_NOW: the name's date makes the key expire.
c18_norun_old() {
  dc_plant "20260207T110000-01" 30 "#os $DC_L" 4:old.sh
  dc_plant "${DC_D}T011000-4.closed" 30 "#os $DC_L" 7:n.sh
}

c18_foreign() {
  local long; long="$(printf 'k%.0s' $(seq 1 600))"
  lm_plant_dur "dur.2.0123456789abcdef.${DC_D}T010000-5.closed.log" 30 "$DC_L" "1:f.sh"
  dc_plant "garbage" 30 "#os $DC_L" 1:g1.sh
  dc_plant "${DC_D}T010000-abc.closed" 30 "#os $DC_L" 1:g2.sh
  dc_plant "2026030T010000-5.closed" 30 "#os $DC_L" 1:g3.sh
  dc_plant "${DC_D}T020000-21.closed" 30 "#os $DC_L" 2:ok/key "=ffffffffffffffff|3|z.sh" \
    "=RID|12345|bad/a" "=RID|x|bad/b" "=abc|3|bad/c" "=RID|3|" "=RID|3|a|b" "=RID|5|$long"
}
# c18_foreign_sums — name:cksum of everything consolidation must leave alone.
c18_foreign_sums() {
  local f
  for f in "$(lm_dur_dir)"/dur.2.0123456789abcdef.* "$(lm_dur_dir)"/*garbage* "$(lm_dur_dir)"/*-abc.closed.log \
    "$(lm_dur_dir)"/*.2026030T*; do
    [ -f "$f" ] && printf '%s:%s ' "${f##*/}" "$(lm_sum "$f")"
  done | sed "s/$(lm_tok)/T/g"
  echo
}

# (13) old bases B (-01) and C (-02) plus a closed segment of a new attribute A.
c18_reorder() {
  dc_plant "${DC_D}T020000-01" 30 "#os $DC_L" "#run ${DC_D}T020000-5" 2:b.sh
  dc_plant "${DC_D}T020000-02" 30 "#os $DC_W" "#run ${DC_D}T010000-4" 3:c.sh
  dc_plant "${DC_D}T030000-7.closed" 30 "#os $DC_A" 1:a.sh
}

# (14) a moved-aside `<S>-01` left by an earlier round, and an input whose provenance is S.
c18_aside_left() {
  dc_plant "${DC_D}T050000-01.consolidating" 30 "#os $DC_L" "#run ${DC_D}T040000-3" 1:a.sh
  dc_plant "${DC_D}T050000-8.closed" 30 "#os $DC_L" 2:b.sh
}

# (15) 70 closed segments, one key each, stamps one minute apart: more than the 64-segment
# read window, so a window-limited round would drop k1.sh (the oldest) and delete its input.
C18_MANY=70
c18_many_stamp() { printf '%sT%02d%02d00' "$DC_D" $((10 + $1 / 60)) $(($1 % 60)); }
c18_many() {
  local i
  for ((i = 1; i <= C18_MANY; i++)); do dc_plant "$(c18_many_stamp "$i")-$((100 + i)).closed" 30 "#os $DC_L" "$i:k$i.sh"; done
}
c18_cons_rc() { dc_cons; say rc "$?"; }

# ---- parent side --------------------------------------------------------------

run_cons_attr_cases() {
  local c r b="dur.2.T.${DC_D}T030000"
  dc_lib_ck n18/1; c="$(lm_cache)"
  lm_run "$c" c18_two_attrs; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh c.sh d.sh)"
  ck "n18/1/all-keys-readable" "5 6 7 8" "$(lm_v "$r" vals)"
  ck "n18/1/one-base-per-attr-in-attr-order" "$b-01.log $b-02.log" "$(lm_v "$r" ls)"
  ck "n18/1/base-headers" "$DC_L,$DC_W" "$(lm_v "$r" heads)"
  # (6) a second round over a consolidated ledger changes nothing.
  local snap; snap="$(lm_run "$c" dc_snap)"
  lm_run "$c" dc_cons
  ck "n18/6/second-round-idempotent" "$snap|5 6 7 8" "$(lm_run "$c" dc_snap)|$(lm_v "$(lm_run "$c" dc_report a.sh b.sh c.sh d.sh)" vals)"
}

run_cons_provenance_cases() {
  local c r
  dc_lib_ck n18/2; c="$(lm_cache)"
  lm_run "$c" c18_prov
  ck "n18/2/fixture-base-read-first" "1 2" "$(lm_v "$(lm_run "$c" dc_report k.sh j.sh)" vals)"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report k.sh j.sh)"
  ck "n18/2/late-closed-newer-provenance-wins" "9 2" "$(lm_v "$r" vals)"
  ck "n18/2/one-base-named-by-max-provenance" "1:0:0" \
    "$(lm_v "$r" nb):$(lm_v "$r" ncons):$(lm_v "$r" nclosed)"
  case "$(lm_v "$r" bases)" in "dur.2.T.${DC_D}T020000-0"[1-9]".log") pass "n18/2/base-s-is-t2" ;;
    *) fail "n18/2/base-s-is-t2" "bases=[$(lm_v "$r" bases)]" ;; esac
  c="$(lm_cache)"
  lm_run "$c" c18_same_prov; lm_run "$c" dc_cons
  ck "n18/3/same-provenance-later-line-wins" "4 5" "$(lm_v "$(lm_run "$c" dc_report x.sh y.sh)" vals)"
  c="$(lm_cache)"
  lm_run "$c" c18_name; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report p.sh q.sh)"
  ck "n18/4/base-named-max-stamp-0k" "dur.2.T.${DC_D}T040000-01.log|5 6" "$(lm_v "$r" ls)|$(lm_v "$r" vals)"
  lm_run "$c" c18_same_second
  ck "n18/4/same-second-open-read-before-base" "8 6" "$(lm_v "$(lm_run "$c" dc_report p.sh q.sh)" vals)"
}

run_cons_reader_states_cases() {
  ck "n18/5/reader-reads-all-states-and-aside" "1 2 3 4 5" "$(lm_v "$(lm_run "$(lm_cache)" c18_states)" vals)"
}

run_cons_quiet_cases() {
  local c r before fn
  dc_lib_ck n18/6
  for fn in c18_quiet_base c18_quiet_young; do
    c="$(lm_cache)"
    lm_run "$c" "$fn"
    before="$(lm_run "$c" dc_snap)"
    r="$(lm_run "$c" c18_spied)"
    ck "n18/6/$fn-exit-0" "0" "$(lm_v "$r" rc)"
    ck "n18/6/$fn-starts-no-lock-rename-or-temp" "" "$(lm_v "$r" spy | sed 's/ *$//')"
    ck "n18/6/$fn-files-unchanged" "$before" "$(lm_run "$c" dc_snap)"
  done
}

run_cons_merge_cases() {
  local c r
  dc_lib_ck n18/7; c="$(lm_cache)"
  lm_run "$c" c18_two_s; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n18/7/two-s-bases-merge-into-one" "1 2|1|0" "$(lm_v "$r" vals)|$(lm_v "$r" nb)|$(lm_v "$r" ncons)"
  c="$(lm_cache)"
  lm_run "$c" c18_norun; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report m.sh n.sh)"
  ck "n18/8/runless-base-provenance-is-its-name" "4 7|1|0" "$(lm_v "$r" vals)|$(lm_v "$r" nb)|$(lm_v "$r" ncons)"
  c="$(lm_cache)"
  lm_run "$c" c18_norun_old; lm_run "$c" dc_cons
  ck "n18/8/runless-base-dated-by-its-name-after-aside" "- 7" "$(lm_v "$(lm_run "$c" dc_report old.sh n.sh)" vals)"
}

run_cons_foreign_cases() {
  local c r before body
  dc_lib_ck n18/9; c="$(lm_cache)"
  lm_run "$c" c18_foreign
  before="$(lm_run "$c" c18_foreign_sums)"
  [ "$(printf '%s' "$before" | grep -o 'dur\.2\.' | wc -l)" -eq 4 ] || fail "n18/9/fixture-planted" "before=[$before]"
  lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report ok/key)"
  ck "n18/9-12/other-token-and-other-state-names-untouched" "$before" "$(lm_run "$c" c18_foreign_sums)"
  ck "n18/9/consolidation-ran" "2|1|0" "$(lm_v "$r" vals)|$(lm_v "$r" nb)|$(lm_v "$r" nclosed)"
  body="$(printf '%s' "$(lm_run "$c" dc_body)" | tr ';' '\n' | grep -v '^#' | LC_ALL=C sort | tr '\n' ';')"
  ck "n18/10-11/other-repo-kept-invalid-dropped" "R|2|ok/key;ffffffffffffffff|3|z.sh;" "$body"
}

run_cons_reorder_cases() {
  local c r b="dur.2.T.${DC_D}T030000"
  dc_lib_ck n18/13; c="$(lm_cache)"
  lm_run "$c" c18_reorder; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh c.sh)"
  ck "n18/13/all-keys-readable" "1 2 3" "$(lm_v "$r" vals)"
  ck "n18/13/three-bases-no-old-or-aside" "$b-01.log $b-02.log $b-03.log" "$(lm_v "$r" ls)"
  ck "n18/13/headers-in-attr-order" "$DC_A,$DC_L,$DC_W" "$(lm_v "$r" heads)"
  c="$(lm_cache)"
  lm_run "$c" c18_aside_left; lm_run "$c" dc_cons
  r="$(lm_run "$c" dc_report a.sh b.sh)"
  ck "n18/14/publish-skips-leftover-aside-number" "dur.2.T.${DC_D}T050000-02.log" "$(lm_v "$r" ls)"
  ck "n18/14/leftover-aside-read-then-deleted" "1 2" "$(lm_v "$r" vals)"
}

run_cons_window_cases() {
  local c r i want got
  dc_lib_ck n18/15; c="$(lm_cache)"
  lm_run "$c" c18_many
  r="$(lm_run "$c" dc_report k1.sh "k$C18_MANY.sh")"
  ck "n18/15/fixture-70-closed-oldest-outside-read-window" "$C18_MANY|- $C18_MANY" "$(lm_v "$r" nclosed)|$(lm_v "$r" vals)"
  ck "n18/15/consolidate-exit-0" "0" "$(lm_v "$(lm_run "$c" c18_cons_rc)" rc)"
  r="$(lm_run "$c" dc_report k1.sh "k$C18_MANY.sh")"
  ck "n18/15/all-inputs-removed-one-base" "0|0|1" "$(lm_v "$r" nclosed)|$(lm_v "$r" ncons)|$(lm_v "$r" nb)"
  want="$(for ((i = 1; i <= C18_MANY; i++)); do printf 'R|%s|k%s.sh\n' "$i" "$i"; done | LC_ALL=C sort | tr '\n' ';')"
  got="$(printf '%s' "$(lm_run "$c" dc_body)" | tr ';' '\n' | grep -v '^#' | LC_ALL=C sort | tr '\n' ';')"
  ck "n18/15/base-holds-all-70-keys-and-values" "$want" "$got"
  case ";$got" in *";R|1|k1.sh;"*) pass "n18/15/oldest-stamp-key-in-base" ;;
    *) fail "n18/15/oldest-stamp-key-in-base" "body=[$got]" ;; esac
  ck "n18/15/oldest-and-newest-readable-after" "1 $C18_MANY" "$(lm_v "$r" vals)"
}
