# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/baseline-cases.sh
# Tests: bin/lib/run-all-ledger-migrate.sh
# Tags: tests, bin, ledger, baseline, migration, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# Baseline ledger migration (#2079 S7, plan cases 1-11b; b12-b16 in baseline-recovery-cases.sh): a pre-#2079 `<tok>-<e>-<p>.seg`
# becomes `v2.<current tok>-<e>-<p>.seg` with 7-field lines, the same mtime and the same
# epochs, so the 30-day windows neither stretch nor shrink and no record is lost.

# ---- child side (LM_LIBSET=base) ------------------------------------------------

lb_dir() { rtb_ledger_dir; }

# lb_plant_old <raw-s> <host> <epoch> <pid> <age-min> <suffix|-> <rel:res:sha | RAW:a~b~c>...
lb_plant_old() {
  local s="$1" host="$2" e="$3" p="$4" age="$5" sfx="$6" tok f kv rel res sha; shift 6
  [ "$sfx" = "-" ] && sfx=""
  tok="$(lm_oldtok "$s" "$host")"; f="$(lb_dir)/$tok-$e-$p.seg$sfx"
  mkdir -p "$(lb_dir)"; : > "$f"
  for kv in "$@"; do
    case "$kv" in
      RAW:*) printf '%s\n' "${kv#RAW:}" | tr '~' '\t' >> "$f" ;;
      *) rel="${kv%%:*}"; res="${kv#*:}"; sha="${res#*:}"; res="${res%%:*}"
         printf 'v1\t%s\t%s\t%s\t%s\t%s\n' "$sha" "$tok" "$rel" "$res" "$e" >> "$f" ;;
    esac
  done
  lm_age "$f" "$age"
  say mtime "$(lm_mtime "$f")"
}

# lb_plant_v2 <tok-word> <epoch> <pid> — a new-format file of another identity.
lb_plant_v2() {
  local f; f="$(lb_dir)/v2.$1-$2-$3.seg"
  mkdir -p "$(lb_dir)"
  printf 'v2\tabcdef9\t%s\ttests/n.sh\tfail\t%s\tLinux/6.8.0\n' "$1" "$2" > "$f"
  lm_age "$f" 120
}

# lb_age_old <raw-s> <host> <epoch> <pid> <age-min>
lb_age_old() { lm_age "$(lb_dir)/$(lm_oldtok "$1" "$2")-$3-$4.seg" "$5"; }

# lb_same <sha> <rel> / lb_inh <rel> — run the real lookups (they trigger the migration).
lb_same() { say same "$(rtb_ledger_lookup_same_base "$1" "$2")"; }
lb_inh() { say inh "$(rtb_ledger_lookup_inheritable "$1" | tr '\n' ' ')"; }

# lb_append <sha> <rel> <fail|pass> — the writer path: init (migration hook), then one record.
lb_append() { rtb_ledger_append "$@"; }

# lb_show <raw-s> <host> <epoch> <pid> — the destination and the source of one old file.
lb_show() {
  local tok old dest src
  tok="$(lm_tok)"; old="$(lm_oldtok "$1" "$2")"
  dest="$(lb_dir)/v2.$tok-$3-$4.seg"; src="$(lb_dir)/$old-$3-$4.seg"
  say tok "$tok"
  say dest "$([ -f "$dest" ] && echo 1 || echo 0)"
  say lines "$(tr '\t' '~' < "$dest" 2>/dev/null | tr '\n' ';')"
  say dmtime "$(lm_mtime "$dest")"
  say src "$([ -f "$src" ] && echo 1 || echo 0)"
  say srcsum "$(lm_sum "$src")"
  say srclines "$(tr '\t' '~' < "$src" 2>/dev/null | tr '\n' ';')"
  say mig "$([ -f "$src.migrating" ] && echo 1 || echo 0)"
  say migs "$(lm_count_in "$(lb_dir)" '*.migrating')"
}

lm_count_in() { local n=0 f; for f in "$1"/$2; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

# lb_listing — every entry with its checksum: the whole directory state.
lb_listing() {
  local f out=""
  for f in "$(lb_dir)"/* "$(lb_dir)"/.[!.]*; do
    [ -e "$f" ] || continue
    out="$out ${f##*/}:$(lm_sum "$f" | tr ' ' '_')"
  done
  say listing "$out"
}

lb_same_seam() {
  run_all_ledger_migrate_before_delete() { printf 'v1\tabcdef5\t%s\ttests/late.sh\tfail\t%s\n' "$(lm_oldtok "$LM_STUB_S")" "$LM_XVAR" >> "$1"; }
  lb_same "$@"
}

# lb_same_crash — the child dies after publishing the destination, before deleting the claim.
lb_same_crash() {
  run_all_ledger_migrate_before_delete() { exit 0; }
  lb_same "$@"
}

lb_same_mvfail() { lm_mv_fail_claim; lb_same "$@"; }
lb_same_cut() { lm_mv_cut_publish; lb_same "$@"; }
lb_lock_age() { [ -d "$(lb_dir)/.ledger.lock" ] && lm_age "$(lb_dir)/.ledger.lock" "$1"; return 0; }
# lb_oldname <raw-s> <host> <epoch> <pid> — the pre-#2079 file name.
lb_oldname() { say name "$(lm_oldtok "$1" "$2")-$3-$4.seg"; }

# ---- parent side ------------------------------------------------------------

lb_win() { LM_S="$LM_W26300"; LM_HOST=stubhost; LM_R="3.5.4-0.x86_64"; LM_LIBSET=base; }
lb_now() { date +%s; }
W_ATTR="Windows/10.0.26300"
U_ATTR="Windows/unknown-migrated"

# lb_lines <tok> <attr> <epoch> <sha:rel:res>... — the expected `~`-joined destination.
lb_lines() {
  local tok="$1" attr="$2" e="$3" x out=""; shift 3
  for x in "$@"; do
    out="${out}v2~${x%%:*}~$tok~$(printf '%s' "$x" | cut -d: -f2)~${x##*:}~$e~$attr;"
  done
  printf '%s' "$out"
}

run_baseline_format_cases() {
  local c e s tok
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 101 120 - "tests/a.sh:fail:abcdef1" "tests/b.sh:pass:abcdef2" >/dev/null
  lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 101)"; tok="$(lm_v "$s" tok)"
  ck "b1/renamed-to-v2-current-token" "1:0:0:0" "$(lm_v "$s" dest):$(lm_v "$s" src):$(lm_v "$s" mig):$(lm_v "$s" migs)"
  ck "b1/lines-v2-7-fields-same-epoch" "$(lb_lines "$tok" "$W_ATTR" "$e" abcdef1:tests/a.sh:fail abcdef2:tests/b.sh:pass)" "$(lm_v "$s" lines)"
}

run_baseline_attr_cases() {
  local c e s tok spec raw host want
  lb_win; e=$(( $(lb_now) - 7200 ))
  for spec in "$LM_M26300 stubhost $W_ATTR" "$LM_M26200 stubhost $U_ATTR" "$LM_W26300 otherhost $U_ATTR"; do
    set -- $spec; raw="$1"; host="$2"; want="$3"
    c="$(lm_cache)"
    lm_run "$c" lb_plant_old "$raw" "$host" "$e" 102 120 - "tests/a.sh:fail:abcdef1" >/dev/null
    lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
    s="$(lm_run "$c" lb_show "$raw" "$host" "$e" 102)"; tok="$(lm_v "$s" tok)"
    ck "b2/attr-$raw-$host" "$(lb_lines "$tok" "$want" "$e" abcdef1:tests/a.sh:fail)" "$(lm_v "$s" lines)"
  done
}

run_baseline_mtime_lookup_cases() {
  local c e s m
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 29 * 86400 ))
  m="$(lm_v "$(lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 103 $((29 * 1440)) - "tests/a.sh:fail:abcdef1")" mtime)"
  ck "b4/lookup-same-base-reads-migrated" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 103)"
  ck "b3/mtime-preserved-29-days" "1:$m" "$(lm_v "$s" dest):$(lm_v "$s" dmtime)"
  ck "b4/lookup-inheritable-reads-migrated" "abcdef1 " "$(lm_v "$(lm_run "$c" lb_inh tests/a.sh)" inh)"
}

run_baseline_keep_lines_cases() {
  local c e s tok
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 104 120 - "tests/a.sh:fail:abcdef1" "RAW:garbage line" "RAW:v1~abcdef3~x~tests/c.sh~fail" "RAW:v0~abcdef4~x~tests/d.sh~fail~$e" >/dev/null
  lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 104)"; tok="$(lm_v "$s" tok)"
  ck "b5/other-lines-kept-verbatim" "$(lb_lines "$tok" "$W_ATTR" "$e" abcdef1:tests/a.sh:fail)garbage line;v1~abcdef3~x~tests/c.sh~fail;v0~abcdef4~x~tests/d.sh~fail~$e;" "$(lm_v "$s" lines)"
}

run_baseline_untouched_cases() {
  local c e before after s
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_v2 abcdef0123456789 "$e" 105
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 106 30 - "tests/a.sh:fail:abcdef1" >/dev/null
  before="$(lm_v "$(lm_run "$c" lb_listing)" listing)"
  lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
  after="$(lm_v "$(lm_run "$c" lb_listing)" listing)"
  case "$before" in *" v2.abcdef0123456789-$e-105.seg:"*) : ;; *) fail "b6/fixture-planted" "listing=[$before]" ;; esac
  case "$before" in *"-$e-106.seg:"*) : ;; *) fail "b8/fixture-planted" "listing=[$before]" ;; esac
  ck "b6-b8/new-format-and-young-old-untouched" "$before" "$after"
}

# lb_check_foreign <label> <show-before> <show-after> — one foreign file: it existed with a
# real checksum, and afterwards is still there, byte-identical, not claimed, with no v2 copy.
lb_check_foreign() {
  local bsum; bsum="$(lm_v "$2" srcsum)"
  if [ "$(lm_v "$2" src)" = "1" ] && [ -n "$bsum" ] && [ "$bsum" != "none" ]; then pass "$1/fixture-exists"
  else fail "$1/fixture-exists" "src=[$(lm_v "$2" src)] srcsum=[$bsum]"; fi
  ck "$1/untouched-same-checksum-no-copy" "1:$bsum:0:0" "$(lm_v "$3" src):$(lm_v "$3" srcsum):$(lm_v "$3" mig):$(lm_v "$3" dest)"
}

run_baseline_nonwindows_cases() {
  local s c e r tok before after m fb1 fb2 fa1 fa2
  for s in Linux Darwin; do
    LM_S="$s"; LM_HOST=stubhost; LM_R="6.8.0"; LM_LIBSET=base
    c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
    m="$(lm_v "$(lm_run "$c" lb_plant_old "$s" stubhost "$e" 107 120 - "tests/a.sh:fail:abcdef1")" mtime)"
    lm_run "$c" lb_plant_old "$s" otherhost "$e" 108 120 - "tests/a.sh:pass:abcdef1" >/dev/null
    lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 109 120 - "tests/a.sh:pass:abcdef1" >/dev/null
    fb1="$(lm_run "$c" lb_show "$s" otherhost "$e" 108)"; fb2="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 109)"
    before="$fb1$fb2"
    ck "b7/$s-lookup-reads-own-token" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
    r="$(lm_run "$c" lb_show "$s" stubhost "$e" 107)"; tok="$(lm_v "$r" tok)"
    ck "b7/$s-own-token-converted" "1:0:$m" "$(lm_v "$r" dest):$(lm_v "$r" src):$(lm_v "$r" dmtime)"
    ck "b7/$s-attr-unknown-migrated" "$(lb_lines "$tok" "$s/unknown-migrated" "$e" abcdef1:tests/a.sh:fail)" "$(lm_v "$r" lines)"
    fa1="$(lm_run "$c" lb_show "$s" otherhost "$e" 108)"; fa2="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 109)"
    after="$fa1$fa2"
    lb_check_foreign "b7/$s-other-host-file" "$fb1" "$fa1"
    lb_check_foreign "b7/$s-windows-file" "$fb2" "$fa2"
    ck "b7/$s-other-tokens-untouched" "$(printf '%s' "$before" | grep -E '^(src|srcsum|mig)=' | tr '\n' ' ')" "$(printf '%s' "$after" | grep -E '^(src|srcsum|mig)=' | tr '\n' ' ')"
  done
}

run_baseline_collision_idempotent_cases() {
  local c e s tok first second
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 110 120 - "tests/a.sh:fail:abcdef1" >/dev/null
  tok="$(lm_v "$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 110)" tok)"
  lm_run "$c" lb_plant_v2 "$tok" "$e" 110
  lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 110)"
  ck "b9/existing-destination-leaves-source" "1:0:0" "$(lm_v "$s" src):$(lm_v "$s" mig):$(lm_v "$s" migs)"
  ck "b9/existing-destination-not-overwritten" "v2~abcdef9~$tok~tests/n.sh~fail~$e~Linux/6.8.0;" "$(lm_v "$s" lines)"
  c="$(lm_cache)"
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 111 120 - "tests/a.sh:fail:abcdef1" >/dev/null
  lm_run "$c" lb_plant_old "$LM_M26200" stubhost "$e" 112 120 - "tests/b.sh:fail:abcdef2" >/dev/null
  lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
  first="$(lm_v "$(lm_run "$c" lb_listing)" listing)"
  lm_run "$c" lb_same abcdef1 tests/a.sh >/dev/null
  second="$(lm_v "$(lm_run "$c" lb_listing)" listing)"
  case "$first" in *"v2.$tok-$e-111.seg"*"v2.$tok-$e-112.seg"*) pass "b10/first-call-migrated-both" ;; *) fail "b10/first-call-migrated-both" "listing=[$first]" ;; esac
  ck "b10/second-call-changes-nothing" "$first" "$second"
}

run_baseline_late_append_cases() {
  local c e s tok mm
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  mm="$(lm_v "$(lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 113 120 .migrating "tests/a.sh:fail:abcdef1")" mtime)"
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 113 5 - "tests/b.sh:fail:abcdef2" >/dev/null
  ck "b11/claimed-line-readable" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 113)"; tok="$(lm_v "$s" tok)"
  ck "b11/claimed-to-v2-mtime-kept" "1:$mm:0" "$(lm_v "$s" dest):$(lm_v "$s" dmtime):$(lm_v "$s" mig)"
  ck "b11/reborn-original-left" "1" "$(lm_v "$s" src)"
  lm_run "$c" lb_age_old "$LM_W26300" stubhost "$e" 113 61
  # Plan (11) is pinned strictly: the aged reborn line is readable by the new reader, even
  # though its destination name is the one the claimed file already produced (cf. (9)).
  lm_run "$c" lb_same abcdef2 tests/b.sh >/dev/null
  ck "b11/reborn-line-readable-after-aging" "fail:fail" "$(lm_v "$(lm_run "$c" lb_same abcdef2 tests/b.sh)" same):$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  c="$(lm_cache)"
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 114 120 - "tests/a.sh:fail:abcdef1" >/dev/null
  LM_XVAR="$e"
  lm_run "$c" lb_same_seam abcdef1 tests/a.sh >/dev/null
  LM_XVAR=""
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 114)"
  ck "b11b/changed-claim-kept-no-destination" "1:0" "$(lm_v "$s" mig):$(lm_v "$s" dest)"
  ck "b11b/late-line-readable-next-round" "fail:fail" "$(lm_v "$(lm_run "$c" lb_same abcdef5 tests/late.sh)" same):$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 114)"
  ck "b11b/claim-consumed-next-round" "0:1" "$(lm_v "$s" mig):$(lm_v "$s" dest)"
}
