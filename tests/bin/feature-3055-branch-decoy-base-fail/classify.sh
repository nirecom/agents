# shellcheck shell=bash
# tests/bin/feature-3055-branch-decoy-base-fail/classify.sh
# Tests: bin/lib/run-tests-baseline-classify.sh, bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, classify, scope:issue-specific, pwsh-not-required, TL2
# Lib cases of tests/bin/feature-3055-branch-decoy-base-fail.sh (detail plan step 6 a-g); one function
# per case, each on its own RUN_ALL_CACHE_DIR. Sourced by the entrypoint after _lib.sh.

bd_setup() {
  BD_REPO="$TMPROOT/repo-decoy"
  bd_repo "$BD_REPO"
  local rc=0
  git -C "$BD_REPO" diff --quiet "$BD_B2" -- tests/bin/t.sh || rc=$?
  bd_ck "fixture: t.sh is unchanged against the base" 0 "$rc"
  rc=0; git -C "$BD_REPO" diff --quiet "$BD_B2" -- tests/bin/added.sh || rc=$?
  bd_ck "fixture: added.sh is changed against the base" 1 "$rc"
}

# a. decoy + base failure + unchanged test: auto, the comparer is not consulted, NEWC 0 / NEWH [].
bd_unchanged_base_fail() {
  bd_drive "$TMPROOT/c-a" 'TESTS=(tests/bin/t.sh); BR_DECOY[0]=1; BR_END[0]=normal
rtb_cls_table1 0 "$ROOT" "$EMPTY_BASE" "" fails-at-base-exit-1'
  bd_ck "decoy + base fail + unchanged: root-decoy-hit-on-branch" \
    "R0 cls=undetermined det=root-decoy-hit-on-branch" "$(bd_line R0)"
  bd_lacks "decoy + base fail + unchanged: the comparer is not consulted" "COMPARE-CALLED"
  bd_ck "decoy + base fail + unchanged: no new lines" "N0 newc=0 newh=[]" "$(bd_line N0)"
}

# b. the same with a changed (new) test file: records missing (pending).
bd_changed_base_fail() {
  bd_drive "$TMPROOT/c-b" 'TESTS=(tests/bin/added.sh); BR_DECOY[0]=1; BR_END[0]=normal
rtb_cls_table1 0 "$ROOT" "$EMPTY_BASE" "" fails-at-base-exit-1'
  bd_ck "decoy + base fail + changed: records missing on the branch" \
    "R0 cls=new-case-failure-on-branch det=case-records-missing-on-branch" "$(bd_line R0)"
  bd_lacks "decoy + base fail + changed: the comparer is not consulted" "COMPARE-CALLED"
}

# c. git cannot tell (B2 is no commit: rtb_test_changed rc 2): records missing (fail-closed).
bd_git_unknown() {
  bd_drive "$TMPROOT/c-c" 'TESTS=(tests/bin/t.sh); BR_DECOY[0]=1; BR_END[0]=normal
B2=0123456789abcdef0123456789abcdef01234567
rc=0; rtb_test_changed "$B2" tests/bin/t.sh || rc=$?; echo "TC rc=$rc"
rtb_cls_table1 0 "$ROOT" "$EMPTY_BASE" "" fails-at-base-exit-1'
  bd_ck "fixture: rtb_test_changed cannot tell (rc 2)" "TC rc=2" "$(bd_line "TC rc=")"
  bd_ck "decoy + base fail + git unknown: records missing (fail-closed)" \
    "R0 cls=new-case-failure-on-branch det=case-records-missing-on-branch" "$(bd_line R0)"
}

# c2. the rename source is part of the change check: new-d.sh has old-d.sh's content, but the old
# path moved, so it counts as changed (records missing).
bd_rename_source() {
  bd_drive "$TMPROOT/c-ren" 'TESTS=(tests/bin/new-d.sh); BR_DECOY[0]=1; BR_END[0]=normal
rtb_cls_table1 0 "$ROOT" "$EMPTY_BASE" tests/bin/old-d.sh fails-at-base-exit-1'
  bd_ck "decoy + base fail via the rename source: records missing" \
    "R0 cls=new-case-failure-on-branch det=case-records-missing-on-branch" "$(bd_line R0)"
}

# d. decoy + base pass: records missing, never auto (the base pass carve-out).
bd_base_pass() {
  bd_drive "$TMPROOT/c-d" 'TESTS=(tests/bin/t.sh); BR_DECOY[0]=1; BR_END[0]=normal
rtb_cls_base_pass 0 passes-at-base'
  bd_ck "decoy + base pass: records missing on the branch (not broken, not auto)" \
    "R0 cls=new-case-failure-on-branch det=case-records-missing-on-branch" "$(bd_line R0)"
}

# e. unrunnable (BR_NOREC) + base failure + unchanged test: still records missing.
bd_unrunnable() {
  bd_drive "$TMPROOT/c-e" 'TESTS=(tests/bin/t.sh); BR_NOREC[0]=1; BR_END[0]=normal
rtb_cls_table1 0 "$ROOT" "$EMPTY_BASE" "" fails-at-base-exit-1'
  bd_ck "unrunnable + base fail + unchanged: records missing (not split off)" \
    "R0 cls=new-case-failure-on-branch det=case-records-missing-on-branch" "$(bd_line R0)"
}

# f. the timeout path is unchanged (regression control).
bd_timeout_control() {
  bd_drive "$TMPROOT/c-f" 'TESTS=(tests/bin/t.sh tests/bin/u.sh); BR_TIMEOUT[0]=1; BR_TIMEOUT[1]=1
rtb_cls_table1 0 "$ROOT" "$EMPTY_BASE" "" fails-at-base-exit-1
rtb_cls_base_pass 1 passes-at-base'
  bd_ck "timeout + base fail + unchanged: records missing" \
    "R0 cls=new-case-failure-on-branch det=case-records-missing-on-branch" "$(bd_line R0)"
  bd_ck "timeout + base pass: broken" "R1 cls=broken det=passes-at-base" "$(bd_line R1)"
}

# g. rtb_branch_classify splits decoy (BR_DECOY) from unrunnable (BR_NOREC).
bd_branch_flags() {
  bd_drive "$TMPROOT/c-g" 'TESTS=(tests/bin/t.sh tests/bin/u.sh)
rtb_branch_classify 0 inconclusive:decoy ""; rtb_branch_classify 1 inconclusive:unrunnable ""
for i in 0 1; do echo "G$i decoy=${BR_DECOY[i]:-} norec=${BR_NOREC[i]:-} end=${BR_END[i]:-} cls=${CLS[i]:-}"; done'
  bd_ck "decoy: BR_DECOY set, BR_NOREC empty" "G0 decoy=1 norec= end=normal cls=" "$(bd_line G0)"
  bd_ck "unrunnable: BR_NOREC set, BR_DECOY empty" "G1 decoy= norec=1 end=normal cls=" "$(bd_line G1)"
}
