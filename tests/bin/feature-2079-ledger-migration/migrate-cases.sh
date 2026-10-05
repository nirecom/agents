# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/migrate-cases.sh
# Tests: bin/lib/run-all-ledger-migrate.sh
# Tags: tests, bin, ledger, migration, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n17 (1)-(8) (#2079 S7): the writer's init folds pre-#2079 `dur.1.*` segments into
# `dur.2.<current token>` outputs, one per OS attribute, without losing a key or the
# newest-first order, and never touches new-format or (off Windows) foreign-token files.

W_KEYS="a1 a2 a3 a4 a5 a6 a7 a8 b1 b2 b3 b4 b5 b6 c1 c2 c3 c4 d1 d2"
W_VALS="11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30"
W_S="${LM_DAY}T000029"

# ---- child side ---------------------------------------------------------------

# 20 old segments over 4 old tokens: A current build (MINGW64), B current build (MSYS),
# C another build, D another hostname. Key <letter><n> holds 10 + its global index.
c_plant_w() {
  local i=0 spec p s h n t j
  for spec in "a:$LM_W26300:stubhost:8" "b:$LM_M26300:stubhost:6" "c:$LM_M26200:stubhost:4" "d:$LM_W26300:otherhost:2"; do
    IFS=: read -r p s h n <<< "$spec"
    t="$(lm_oldtok "$s" "$h")"
    for j in $(seq 1 "$n"); do
      i=$((i + 1))
      lm_plant_dur "dur.1.$t.${LM_DAY}T0000$((i + 9))-$((1000 + i)).log" 120 - "$((10 + i)):$p$j"
    done
  done
}

c_init() {
  run_all_dur_writer_init "$LM_REPO"
  say seg "${RUN_ALL_DUR_SEGMENT##*/}"
}

# c_report <keys> <own-seg>... — values, leftovers, and the attribute split of the outputs.
c_report() {
  local keys="$1" tok dir f hdr k cur="" unk="" hdrs="" outs="" sums="" others="" own e; shift
  tok="$(lm_tok)"; dir="$(lm_dur_dir)"
  say vals "$(lm_get $keys)"
  say old "$(lm_count 'dur.1.*')"
  say mig "$(lm_count '*.migrating')"
  for f in "$dir"/dur.2."$tok".*-0*.log; do
    [ -f "$f" ] || continue
    outs="$outs ${f##*/}"; sums="$sums $(lm_sum "$f")"
    hdr="$(head -n 1 "$f")"; hdrs="$hdrs,$hdr"
    k="$(grep -v '^#' "$f" | cut -d'|' -f3 | LC_ALL=C sort | tr '\n' ' ')"
    case "$hdr" in
      "#os Windows/10.0.26300") cur="$cur$k" ;;
      *unknown-migrated) unk="$unk$k" ;;
    esac
  done
  for e in $(lm_ls); do
    case " $outs $* " in *" $e "*) continue ;; esac
    others="$others $e"
  done
  say outs "$outs"; say outsum "$sums"; say hdrs "${hdrs#,}"
  say cur "$cur"; say unk "$unk"; say others "$others"
}

c_plant_order() {
  local t; t="$(lm_tok)"
  lm_plant_dur "dur.1.$(lm_oldtok "$LM_W26300").${LM_DAY}T000020-50.log" 120 - "5:x" "2:y" "9:z"
  lm_plant_dur "dur.2.$t.${LM_DAY}T000010-40.log" 120 "Windows/10.0.26300" "3:x"
  lm_plant_dur "dur.2.$t.${LM_DAY}T000030-60.log" 120 "Windows/10.0.26300" "7:y"
}

# c_plant_i <plain|mig|mig12> — three old segments, as files or as interrupted claims.
c_plant_i() {
  local t sfx1="" sfx2="" sfx3=""
  t="$(lm_oldtok "$LM_W26300")"
  case "$1" in
    mig) sfx1=".migrating"; sfx2=".migrating"; sfx3=".migrating" ;;
    mig12) sfx1=".migrating"; sfx2=".migrating" ;;
  esac
  [ "$1" = "mig12" ] || lm_plant_dur "dur.1.$t.${LM_DAY}T000003-503.log$sfx3" 120 - "3:k3" "3:k4"
  lm_plant_dur "dur.1.$t.${LM_DAY}T000001-501.log$sfx1" 120 - "1:k1" "1:k2"
  lm_plant_dur "dur.1.$t.${LM_DAY}T000002-502.log$sfx2" 120 - "2:k2" "2:k3"
}

# c_foreign_sums <glob> — name:cksum of the other tokens' files this host must leave alone.
c_foreign_sums() {
  local f mine; mine="$(lm_tok)"
  for f in "$(lm_dur_dir)"/$1; do
    [ -f "$f" ] || continue
    case "${f##*/}" in dur.2."$mine".*|dur.1."$mine".*) continue ;; esac
    printf '%s:%s ' "${f##*/}" "$(lm_sum "$f")"
  done
  echo
}

c_plant_new_foreign() {
  lm_plant_dur "dur.2.0123456789abcdef.${LM_DAY}T000001-5.log" 120 "Linux/6.8.0" "1:q1"
  lm_plant_dur "dur.2.$(lm_oldtok Linux).${LM_DAY}T000002-6.log" 120 "Linux/6.8.0" "2:q2"
  lm_plant_dur "dur.1.$(lm_oldtok "$LM_W26300").${LM_DAY}T000003-7.log" 120 - "3:w1"
}

c_plant_nonwin() {
  local cur o1 o2; cur="$(lm_tok)"; o1="$(lm_oldtok "$LM_W26300")"; o2="$(lm_oldtok "$LM_STUB_S" otherhost)"
  lm_plant_dur "dur.1.$cur.${LM_DAY}T000001-11.log" 120 - "1:l1" "1:l2"
  lm_plant_dur "dur.1.$cur.${LM_DAY}T000002-12.log" 120 - "2:l2"
  lm_plant_dur "dur.1.$cur.${LM_DAY}T000003-13.log" 120 - "3:l3"
  lm_plant_dur "dur.1.$o1.${LM_DAY}T000004-14.log" 120 - "4:o1"
  lm_plant_dur "dur.1.$o2.${LM_DAY}T000005-15.log" 120 - "5:o2"
  lm_plant_dur "dur.1.$o1.${LM_DAY}T000006-16.log.migrating" 120 - "6:o3"
}

c_report_nonwin() {
  local cur f outs="" hdrs=""; cur="$(lm_tok)"
  for f in "$(lm_dur_dir)"/dur.2."$cur".*-0*.log; do
    [ -f "$f" ] || continue
    outs="$outs ${f##*/}"; hdrs="$hdrs$(head -n 1 "$f");"
  done
  say outs "$(set -- $outs; echo $#)"; say hdrs "$hdrs"
  say vals "$(lm_get l1 l2 l3)"
  say oldmine "$(lm_count "dur.1.$cur.*")"
}

# c_plant_cur_segs <yyyymmdd> [.closed] — 16 current-format segments (the old keep limit),
# stamped that day, 120 minutes quiet: open (young, never consolidated) or closed.
c_plant_cur_segs() {
  local i tok; tok="$(lm_tok)"
  for i in $(seq 1 16); do
    lm_plant_dur "dur.2.$tok.$1T0000$(printf '%02d' "$i")-$((300 + i))${2:-}.log" 120 "Windows/10.0.26300" "$((40 + i)):cur$i"
  done
}

# c_seg_report <key>... — the values the reader resolves, how many own-token segments remain,
# how many are closed, and how many bases carry the current build's attribute.
c_seg_report() {
  local f n=0 tok; tok="$(lm_tok)"
  say vals "$(lm_get "$@")"
  say segs "$(lm_count "dur.2.$tok.*.log")"
  say closed "$(lm_count "dur.2.$tok.*.closed.log")"
  for f in "$(lm_dur_dir)"/dur.2."$tok".*-0*.log; do
    [ -f "$f" ] || continue
    case "$f" in *.consolidating.log) continue ;; esac
    [ "$(head -n 1 "$f")" = "#os Windows/10.0.26300" ] && n=$((n + 1))
  done
  say curbases "$n"
}

# ---- parent side --------------------------------------------------------------

lm_win() { LM_S="$LM_W26300"; LM_HOST=stubhost; LM_R="3.5.4-0.x86_64"; LM_LIBSET=dur; }

run_migrate_bulk_cases() {
  local c seg1 seg2 r1 r2 outs n bad=""
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_w
  seg1="$(lm_v "$(lm_run "$c" c_init)" seg)"
  r1="$(lm_run "$c" c_report "$W_KEYS" "$seg1")"
  ck "n17/1/all-20-keys-readable" "$W_VALS" "$(lm_v "$r1" vals)"
  ck "n17/1/no-old-or-claimed-left" "0:0" "$(lm_v "$r1" old):$(lm_v "$r1" mig)"
  ck "n17/1/only-outputs-and-own-segment" "" "$(lm_v "$r1" others)"
  outs="$(lm_v "$r1" outs)"; n=0
  for seg2 in $outs; do
    n=$((n + 1))
    printf '%s\n' "$seg2" | grep -qE "^dur\\.2\\.[A-Za-z0-9]{16}\\.$W_S-0[0-9]+\\.log\$" || bad="$bad $seg2"
  done
  ck "n17/1/two-outputs-named-by-max-stamp" "2:" "$n:$bad"
  ck "n17/2/attribute-headers" "#os Windows/10.0.26300,#os Windows/unknown-migrated" "$(lm_v "$r1" hdrs)"
  ck "n17/2/current-build-keys" "a1 a2 a3 a4 a5 a6 a7 a8 b1 b2 b3 b4 b5 b6 " "$(lm_v "$r1" cur)"
  ck "n17/3/other-build-and-host-keys" "c1 c2 c3 c4 d1 d2 " "$(lm_v "$r1" unk)"
  seg2="$(lm_v "$(lm_run "$c" c_init)" seg)"
  r2="$(lm_run "$c" c_report "$W_KEYS" "$seg1" "$seg2")"
  ck "n17/5/second-init-same-values" "$W_VALS" "$(lm_v "$r2" vals)"
  ck "n17/5/second-init-same-outputs" "$(lm_v "$r1" outs)|$(lm_v "$r1" outsum)" "$(lm_v "$r2" outs)|$(lm_v "$r2" outsum)"
  ck "n17/5/second-init-adds-only-its-segment" "" "$(lm_v "$r2" others)"
}

# Review C1: 16 current-format segments already sit next to the 20 old ones (the count the
# retired keep limit trimmed at). Young open segments are never consolidated, so all 16 stay
# beside the 2 migration bases and the writer's own segment (19). Closed ones fold into the
# current attribute's single base. "older" = existing segments predate the migrated data;
# "newer" = they postdate it.
run_migrate_young_open_cases() {
  local c r when day
  for when in older newer; do
    day="$LM_DAY_OLDER"; [ "$when" = "newer" ] && day="$LM_DAY_NEWER"
    lm_win; c="$(lm_cache)"
    lm_run "$c" c_plant_w
    lm_run "$c" c_plant_cur_segs "$day"
    lm_run "$c" c_init >/dev/null
    r="$(lm_run "$c" c_seg_report $W_KEYS)"
    ck "n17/18/$when-after-init-young-open-kept" "19" "$(lm_v "$r" segs)"
    ck "n17/18/$when-after-init-all-20-old-keys-readable" "$W_VALS" "$(lm_v "$r" vals)"
    lm_run "$c" c_init >/dev/null
    r="$(lm_run "$c" c_seg_report $W_KEYS)"
    ck "n17/18/$when-after-second-init-all-20-old-keys-readable" "$W_VALS" "$(lm_v "$r" vals)"
  done
}

# The same 16 under closed names: one init folds them and the migrated current-build data
# into one base per attribute (2 bases + the writer's own segment), every key readable.
run_migrate_closed_cases() {
  local c r when day keys="$W_KEYS" vals="$W_VALS" i
  for i in $(seq 1 16); do keys="$keys cur$i"; vals="$vals $((40 + i))"; done
  for when in older newer; do
    day="$LM_DAY_OLDER"; [ "$when" = "newer" ] && day="$LM_DAY_NEWER"
    lm_win; c="$(lm_cache)"
    lm_run "$c" c_plant_w
    lm_run "$c" c_plant_cur_segs "$day" .closed
    lm_run "$c" c_init >/dev/null
    r="$(lm_run "$c" c_seg_report $keys)"
    ck "n17/18c/$when-closed-folded-into-one-base" "0:1:3" "$(lm_v "$r" closed):$(lm_v "$r" curbases):$(lm_v "$r" segs)"
    ck "n17/18c/$when-all-36-keys-readable" "$vals" "$(lm_v "$r" vals)"
  done
}

run_migrate_order_cases() {
  local c r
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_order
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_report "x y z")"
  ck "n17/4/newer-old-beats-older-current" "5" "$(lm_v "$r" vals | cut -d' ' -f1)"
  ck "n17/4/newer-current-beats-output" "7" "$(lm_v "$r" vals | cut -d' ' -f2)"
  ck "n17/4/old-only-key" "9" "$(lm_v "$r" vals | cut -d' ' -f3)"
}

run_migrate_interrupt_cases() {
  local ref refsum c r mode
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_i plain
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_report "k1 k2 k3 k4")"
  ref="$(lm_v "$r" vals)"; refsum="$(lm_v "$r" outs)|$(lm_v "$r" outsum)"
  ck "n17/6/reference-run" "1 2 3 3" "$ref"
  for mode in mig mig12; do
    c="$(lm_cache)"
    lm_run "$c" c_plant_i plain
    lm_run "$c" c_init >/dev/null
    lm_run "$c" c_plant_i "$mode"
    lm_run "$c" c_init >/dev/null
    r="$(lm_run "$c" c_report "k1 k2 k3 k4")"
    ck "n17/6/$mode-after-output-converges" "$ref:0:0" "$(lm_v "$r" vals):$(lm_v "$r" mig):$(lm_v "$r" old)"
    # Same S only when all three claims survive; mig12 lowers S, so S7 allows an extra older output.
    [ "$mode" = "mig" ] && ck "n17/6/mig-after-output-same-output" "$refsum" "$(lm_v "$r" outs)|$(lm_v "$r" outsum)"
  done
  c="$(lm_cache)"
  lm_run "$c" c_plant_i mig
  lm_run "$c" c_init >/dev/null
  r="$(lm_run "$c" c_report "k1 k2 k3 k4")"
  ck "n17/6/claims-without-output-converge" "$ref:0:0" "$(lm_v "$r" vals):$(lm_v "$r" mig):$(lm_v "$r" old)"
  ck "n17/6/claims-without-output-same-output" "$refsum" "$(lm_v "$r" outs)|$(lm_v "$r" outsum)"
}

run_migrate_foreign_new_cases() {
  local c before after r
  lm_win; c="$(lm_cache)"
  lm_run "$c" c_plant_new_foreign
  before="$(lm_run "$c" c_foreign_sums 'dur.2.*')"
  lm_run "$c" c_init >/dev/null
  after="$(lm_run "$c" c_foreign_sums 'dur.2.*')"
  r="$(lm_run "$c" c_report "w1")"
  ck "n17/7/migration-ran" "3:0" "$(lm_v "$r" vals):$(lm_v "$r" old)"
  if [ -n "$before" ] && [ "$before" = "$after" ] && [ "$(printf '%s' "$before" | grep -o 'dur\.2\.' | wc -l)" -eq 2 ]; then
    pass "n17/7/new-format-foreign-untouched"
  else
    fail "n17/7/new-format-foreign-untouched" "before=[$before] after=[$after]"
  fi
}

run_migrate_nonwindows_cases() {
  local s c before after r
  for s in Linux Darwin; do
    LM_S="$s"; LM_HOST=stubhost; LM_R="6.8.0"; LM_LIBSET=dur
    c="$(lm_cache)"
    lm_run "$c" c_plant_nonwin
    before="$(lm_run "$c" c_foreign_sums 'dur.1.*')"
    lm_run "$c" c_init >/dev/null
    after="$(lm_run "$c" c_foreign_sums 'dur.1.*')"
    r="$(lm_run "$c" c_report_nonwin)"
    ck "n17/8/$s-one-output" "1" "$(lm_v "$r" outs)"
    ck "n17/8/$s-header" "#os $s/unknown-migrated;" "$(lm_v "$r" hdrs)"
    ck "n17/8/$s-own-keys-readable" "1 2 3" "$(lm_v "$r" vals)"
    ck "n17/8/$s-own-old-removed" "0" "$(lm_v "$r" oldmine)"
    if [ -n "$before" ] && [ "$before" = "$after" ] && [ "$(printf '%s' "$before" | grep -o 'dur\.1\.' | wc -l)" -eq 3 ]; then
      pass "n17/8/$s-foreign-tokens-untouched"
    else
      fail "n17/8/$s-foreign-tokens-untouched" "before=[$before] after=[$after]"
    fi
  done
}
