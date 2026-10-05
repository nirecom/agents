# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/baseline-recovery-cases.sh
# Tests: bin/lib/run-all-ledger-migrate.sh
# Tags: tests, bin, ledger, baseline, migration, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# Baseline ledger migration recovery (#2079 S7, b12-b16): interrupted rounds, a failed claim
# rename, a crash after publishing (review C4), the append path and expired records.
# Helpers (lb_*, lm_*) live in baseline-cases.sh and _lib.sh; every part is loaded first.

# S7 recovery: a leftover claim is input whatever its age; a temp file older than 60 min
# left by an interrupted round is deleted by the next round.
run_baseline_recovery_cases() {
  local c e s rec tmp
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 115 5 .migrating "tests/a.sh:fail:abcdef1" >/dev/null
  ck "b12/young-leftover-claim-readable" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 115)"
  ck "b12/young-leftover-claim-consumed" "1:0" "$(lm_v "$s" dest):$(lm_v "$s" mig)"
  c="$(lm_cache)"; rec="$LM_TMP/cut.$RANDOM"
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 116 120 - "tests/a.sh:fail:abcdef1" >/dev/null
  LM_XVAR="$rec"; lm_run "$c" lb_same_cut abcdef1 tests/a.sh >/dev/null; LM_XVAR=""
  tmp="$(cat "$rec" 2>/dev/null)"
  if [ -n "$tmp" ] && [ -e "$tmp" ]; then pass "b12/fixture-interrupted-temp-left"
  else fail "b12/fixture-interrupted-temp-left" "no temp recorded or it is gone: [$tmp]"; fi
  [ -n "$tmp" ] && lm_run "$c" lm_age "$tmp" 61
  lm_run "$c" lb_lock_age 15
  ck "b12/interrupted-round-redone" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 116)"
  ck "b12/stale-temp-deleted" "0:1:0" "$([ -n "$tmp" ] && [ -e "$tmp" ] && echo 1 || echo 0):$(lm_v "$s" dest):$(lm_v "$s" mig)"
}

# S7: a file whose claim rename fails is skipped this round and migrated in the next.
run_baseline_rename_fail_cases() {
  local c e s before
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 117 120 - "tests/a.sh:fail:abcdef1" >/dev/null
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 118 120 - "tests/b.sh:fail:abcdef2" >/dev/null
  before="$(lm_v "$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 118)" srcsum)"
  [ "$before" != "none" ] && [ -n "$before" ] || fail "b13/fixture-planted" "second old file missing"
  LM_XVAR="$(lm_v "$(lm_run "$c" lb_oldname "$LM_W26300" stubhost "$e" 118)" name)"
  lm_run "$c" lb_same_mvfail abcdef1 tests/a.sh >/dev/null; LM_XVAR=""
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 117)"
  ck "b13/other-file-migrated" "1:0" "$(lm_v "$s" dest):$(lm_v "$s" src)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 118)"
  ck "b13/failed-claim-untouched" "$before:0:0" "$(lm_v "$s" srcsum):$(lm_v "$s" mig):$(lm_v "$s" dest)"
  ck "b13/retried-next-round-readable" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef2 tests/b.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 118)"
  ck "b13/retried-next-round-consumed" "1:0:0" "$(lm_v "$s" dest):$(lm_v "$s" src):$(lm_v "$s" mig)"
}

# S7: a round that died between publishing and deleting its claim is finished by the next
# round without merging the claim into its own output a second time (review C4).
run_baseline_crash_after_publish_cases() {
  local c e s tok m
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  m="$(lm_v "$(lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 119 120 - "tests/a.sh:fail:abcdef1" "tests/b.sh:pass:abcdef2" "tests/c.sh:fail:abcdef3")" mtime)"
  lm_run "$c" lb_same_crash abcdef1 tests/a.sh >/dev/null
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 119)"; tok="$(lm_v "$s" tok)"
  ck "b14/fixture-crashed-after-publish" "1:1" "$(lm_v "$s" dest):$(lm_v "$s" mig)"
  lm_run "$c" lb_lock_age 15
  ck "b14/rerun-lookup-reads-migrated" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 119)"
  ck "b14/rerun-claim-consumed" "1:0:0" "$(lm_v "$s" dest):$(lm_v "$s" mig):$(lm_v "$s" migs)"
  ck "b14/rerun-no-duplicate-lines" "$(lb_lines "$tok" "$W_ATTR" "$e" abcdef1:tests/a.sh:fail abcdef2:tests/b.sh:pass abcdef3:tests/c.sh:fail)" "$(lm_v "$s" lines)"
  ck "b14/rerun-mtime-kept" "$m" "$(lm_v "$s" dmtime)"
}

# Review C2: the writer path (append), not only a lookup, must fold legacy segments in.
run_baseline_append_path_cases() {
  local c e s
  lb_win; c="$(lm_cache)"; e=$(( $(lb_now) - 7200 ))
  lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$e" 120 120 - "tests/a.sh:fail:abcdef1" "tests/b.sh:pass:abcdef2" >/dev/null
  lm_run "$c" lb_append abcdef9 tests/n.sh fail >/dev/null
  s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$e" 120)"
  ck "b15/append-migrates-old-file" "1:0:0:0" "$(lm_v "$s" dest):$(lm_v "$s" src):$(lm_v "$s" mig):$(lm_v "$s" migs)"
  ck "b15/migrated-record-readable" "fail:pass" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same):$(lm_v "$(lm_run "$c" lb_same abcdef2 tests/b.sh)" same)"
  ck "b15/appended-record-readable" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef9 tests/n.sh)" same)"
  ck "b15/appended-record-inheritable" "abcdef9 " "$(lm_v "$(lm_run "$c" lb_inh tests/n.sh)" inh)"
}

# Review C4: a legacy record whose epoch is past the 30-day window stays out of the
# inheritable set after migration (the window keys on the record epoch, not the file mtime).
run_baseline_expired_record_cases() {
  local c old fresh s tok mode age
  lb_win; old=$(( $(lb_now) - 31 * 86400 )); fresh=$(( $(lb_now) - 86400 ))
  for mode in young-mtime old-mtime; do
    age=120; [ "$mode" = "old-mtime" ] && age=$((31 * 1440))
    c="$(lm_cache)"
    lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$old" 121 "$age" - "tests/a.sh:fail:abcdef1" >/dev/null
    lm_run "$c" lb_plant_old "$LM_W26300" stubhost "$fresh" 122 120 - "tests/a.sh:fail:abcdef3" >/dev/null
    ck "b16/$mode-only-in-window-record-inheritable" "abcdef3 " "$(lm_v "$(lm_run "$c" lb_inh tests/a.sh)" inh)"
    s="$(lm_run "$c" lb_show "$LM_W26300" stubhost "$old" 121)"; tok="$(lm_v "$s" tok)"
    ck "b16/$mode-expired-record-migrated-epoch-kept" "1:0:$(lb_lines "$tok" "$W_ATTR" "$old" abcdef1:tests/a.sh:fail)" "$(lm_v "$s" dest):$(lm_v "$s" src):$(lm_v "$s" lines)"
    ck "b16/$mode-expired-record-still-same-base" "fail" "$(lm_v "$(lm_run "$c" lb_same abcdef1 tests/a.sh)" same)"
  done
}
