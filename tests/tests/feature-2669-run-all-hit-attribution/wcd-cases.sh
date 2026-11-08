#!/usr/bin/env bash
# tests/tests/feature-2669-run-all-hit-attribution/wcd-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh, bin/lib/run-all-hits.sh, bin/lib/run-all-worktree-change-detect.sh
# Tags: run-all, worktree-change-detection, hit-attribution, scope:issue-specific, tl2
# A worktree change is never one test's FAIL (tests run alongside each other), so it is a HIT
# that names the changed paths. The launcher protects the checkout it is loaded from, so the
# run goes through a committed copy of the launcher ("fixture checkout"), never the real one.

# ha_wcd_checkout <dir> [file...] — a committed copy of what tests/run-all.sh needs, plus one
# data file (clean.txt) and each extra relative data file named.
ha_wcd_checkout() {
  local d="$1" f
  shift
  mkdir -p "$d/bin" "$d/hooks/lib" "$d/tests/bin" || return 1
  cp -R "$ROOT_N/bin/lib" "$d/bin/" || return 1
  cp "$ROOT_N/bin/run-with-timeout.sh" "$ROOT_N/bin/test-language-registry" "$ROOT_N/bin/get-config-var" "$d/bin/" || return 1
  cp "$ROOT_N"/hooks/lib/test-language-registry.* "$ROOT_N/hooks/lib/load-env.js" "$d/hooks/lib/" || return 1
  # #2681: bin/get-config-var resolves through hooks/lib/config-flag.js (guarded until the module exists).
  if [ -f "$ROOT_N/hooks/lib/config-flag.js" ]; then cp "$ROOT_N/hooks/lib/config-flag.js" "$d/hooks/lib/" || return 1; fi
  cp -R "$ROOT_N/hooks/lib/test-language-registry" "$d/hooks/lib/" || return 1
  cp -R "$ROOT_N/tests/lib" "$d/tests/" || return 1
  cp "$ROOT_N/tests/run-all.sh" "$d/tests/" || return 1
  cp "$ROOT_N/tests/bin/feature-2561-root-names-residue.sh" "$d/tests/bin/" || return 1
  # #2473: the launcher reads the target's .agents.json tests section (CLI and reader copied when present).
  printf '%s\n' '{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"hooks","covers":["hooks"]},{"dir":"bin","covers":["bin"]},{"dir":"skills","covers":["skills"]},{"dir":"agents","covers":["agents"]},{"dir":"install","covers":["install"]},{"dir":"tests","covers":["tests"]}],"supportDirs":["_archive","lib"],"testHarness":"on","caseMarker":"on"}}' >"$d/.agents.json"
  if [ -f "$ROOT_N/bin/repo-settings" ]; then cp "$ROOT_N/bin/repo-settings" "$d/bin/" || return 1; fi
  if [ -d "$ROOT_N/hooks/lib/repo-settings" ]; then cp -R "$ROOT_N/hooks/lib/repo-settings" "$d/hooks/lib/" || return 1; fi
  if [ -f "$ROOT_N/hooks/lib/repo-settings.js" ]; then cp "$ROOT_N/hooks/lib/repo-settings.js" "$d/hooks/lib/" || return 1; fi
  printf 'clean\n' >"$d/clean.txt"
  for f in "$@"; do
    mkdir -p "$(dirname "$d/$f")" || return 1
    printf 'clean\n' >"$d/$f" || return 1
  done
  harness_git_init "$d" || return 1
  git -C "$d" -c core.autocrlf=false add -A || return 1
  git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m base || return 1
}

ha_case_worktree_change_is_a_hit_with_paths() {
  local co="$TMP_ROOT/fixture checkout" fx="$HA_FX/wcd-tracked.sh" out errf="$TMP_ROOT/wcd.err" err rc hitn contn
  ha_wcd_checkout "$co" || { fail "wcd: fixture checkout" "cannot build it"; return 0; }
  out="$(ha_launched env FX_TREE="$co" bash "$co/tests/run-all.sh" -j 1 "$fx" 2>"$errf")"
  rc=$?
  err="$(cat "$errf" 2>/dev/null || true)"
  expect_eq "wcd: the fixture test made the change" "$(sed -n 2p "$co/clean.txt" 2>/dev/null)" "more"
  expect_eq "wcd: the stderr line still names the tree, the test and the kind" "$(count_lines "$err" "[run-all] worktree change: ")" "1"
  expect_has "wcd: the stderr line carries the changed path as a fourth field" "$err" "$TAB$fx${TAB}tracked${TAB}clean.txt"
  expect_eq "wcd: one HIT line for the change" "$(count_lines "$out" "HIT: worktree-change ")" "1"
  expect_has "wcd: the HIT line names the kind" "$(printf '%s\n' "$out" | grep '^HIT: worktree-change ' || true)" "kind=tracked"
  expect_has "wcd: the HIT line names the changed path" "$(printf '%s\n' "$out" | grep '^HIT: worktree-change ' || true)" "paths=clean.txt"
  expect_eq "wcd: the test that ran is not a failing name" "$(count_lines "$out" "FAIL: ")" "0"
  expect_eq "wcd: the test that ran is still a PASS" "$(count_lines "$out" "PASS: $fx")" "1"
  expect_eq "wcd: the contract has no failure and one hit" "$(last_nonempty "$out")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"
  hitn="$(line_no "$out" "HIT:")"
  contn="$(line_no "$out" "RUN_CONTRACT:")"
  expect_eq "wcd: the HIT line comes before the contract" "$([[ "$hitn" -gt 0 && "$hitn" -lt "$contn" ]] && echo before)" "before"
  expect_eq "wcd: run-all exits 1" "$rc" "1"
}

# ha_wcd_run <label> <checkout> <fixture> — runs the fixture through the checkout's launcher;
# sets WCD_OUT, WCD_ERR, WCD_RC and WCD_HIT (the one worktree-change HIT line).
ha_wcd_run() {
  local errf="$TMP_ROOT/wcd-$1.err"
  WCD_OUT="$(ha_launched env FX_TREE="$2" bash "$2/tests/run-all.sh" -j 1 "$3" 2>"$errf")"
  WCD_RC=$?
  WCD_ERR="$(cat "$errf" 2>/dev/null || true)"
  WCD_HIT="$(printf '%s\n' "$WCD_OUT" | tr -d '\r' | grep '^HIT: worktree-change ' || true)"
}

ha_case_worktree_change_path_with_spaces() {
  local co="$TMP_ROOT/fixture checkout space" fx="$HA_FX/wcd-space.sh" p="dir with space/file a.txt"
  ha_wcd_checkout "$co" "$p" || { fail "wcd space: fixture checkout" "cannot build it"; return 0; }
  ha_write_fixture "$fx" <<'FIXTURE'
printf 'more\n' >>"$FX_TREE/dir with space/file a.txt"
exit 0
FIXTURE
  ha_wcd_run space "$co" "$fx"
  expect_eq "wcd space: one HIT line for the change" "$(count_lines "$WCD_OUT" "HIT: worktree-change ")" "1"
  expect_has "wcd space: the HIT line keeps the path whole, spaces included" "$WCD_HIT" "kind=tracked paths=$p"
  expect_has "wcd space: the stderr line carries the whole path as its fourth field" "$WCD_ERR" "$TAB$fx${TAB}tracked${TAB}$p"
  expect_eq "wcd space: the contract has one hit" "$(last_nonempty "$WCD_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"
}

# #2803: the shared common config is foreign (not this session's own change), so a run whose only
# change is there has no HIT and passes; the checkout's own config.worktree stays a HIT.
ha_case_foreign_config_is_not_a_hit() {
  local co="$TMP_ROOT/fixture checkout foreign" fxc="$HA_FX/wcd-common-config.sh" fxw="$HA_FX/wcd-config-worktree.sh"
  ha_wcd_checkout "$co" || { fail "wcd foreign: fixture checkout" "cannot build it"; return 0; }
  ha_write_fixture "$fxc" <<'FIXTURE'
printf '[wcd]\n\tn = %s\n' "$RANDOM" >>"$FX_TREE/.git/config"
exit 0
FIXTURE
  ha_wcd_run foreign "$co" "$fxc"
  expect_eq "wcd foreign: a common config change is no HIT line" "$(count_lines "$WCD_OUT" "HIT: ")" "0"
  expect_eq "wcd foreign: the contract carries no HITS" "$(last_nonempty "$WCD_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
  expect_eq "wcd foreign: run-all exits 0" "$WCD_RC" "0"
  expect_eq "wcd foreign: no worktree change line on stderr" "$(count_lines "$WCD_ERR" "[run-all] worktree change: ")" "0"
  expect_has "wcd foreign: stderr still shows the change as foreign" "$WCD_ERR" "worktree-change (foreign, not a hit) tree="
  expect_has "wcd foreign: the foreign line names kind=config" "$(printf '%s\n' "$WCD_ERR" | grep -F '(foreign, not a hit)' || true)" "kind=config"

  ha_write_fixture "$fxw" <<'FIXTURE'
printf '[wcd]\n\tn = %s\n' "$RANDOM" >>"$FX_TREE/.git/config.worktree"
exit 0
FIXTURE
  ha_wcd_run config-worktree "$co" "$fxw"
  expect_eq "wcd config-worktree: the checkout's own config.worktree is one HIT" "$(count_lines "$WCD_OUT" "HIT: worktree-change ")" "1"
  expect_has "wcd config-worktree: the HIT line names kind=config-worktree" "$WCD_HIT" "kind=config-worktree"
  expect_eq "wcd config-worktree: the contract has one hit" "$(last_nonempty "$WCD_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"
  expect_eq "wcd config-worktree: run-all exits 1" "$WCD_RC" "1"
}

ha_case_worktree_change_with_many_paths() {
  local co2="$TMP_ROOT/fixture checkout two" co7="$TMP_ROOT/fixture checkout seven" fx2="$HA_FX/wcd-two.sh"
  local fx7="$HA_FX/wcd-seven.sh" i named=0
  ha_wcd_checkout "$co2" a.txt b.txt || { fail "wcd two: fixture checkout" "cannot build it"; return 0; }
  ha_write_fixture "$fx2" <<'FIXTURE'
printf 'more\n' >>"$FX_TREE/a.txt"
printf 'more\n' >>"$FX_TREE/b.txt"
exit 0
FIXTURE
  ha_wcd_run two "$co2" "$fx2"
  expect_eq "wcd two: two changed files are still one HIT" "$(count_lines "$WCD_OUT" "HIT: worktree-change ")" "1"
  case "$WCD_HIT" in
    *"paths=a.txt | b.txt"|*"paths=b.txt | a.txt") pass "wcd two: the HIT line names both paths, joined by ' | '" ;;
    *) fail "wcd two: the HIT line names both paths, joined by ' | '" "got: $WCD_HIT" ;;
  esac
  expect_eq "wcd two: the contract has one hit" "$(last_nonempty "$WCD_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"

  ha_wcd_checkout "$co7" m1.txt m2.txt m3.txt m4.txt m5.txt m6.txt m7.txt \
    || { fail "wcd seven: fixture checkout" "cannot build it"; return 0; }
  ha_write_fixture "$fx7" <<'FIXTURE'
for n in 1 2 3 4 5 6 7; do printf 'more\n' >>"$FX_TREE/m$n.txt"; done
exit 0
FIXTURE
  ha_wcd_run seven "$co7" "$fx7"
  expect_eq "wcd seven: seven changed files are still one HIT" "$(count_lines "$WCD_OUT" "HIT: worktree-change ")" "1"
  for i in 1 2 3 4 5 6 7; do
    case "$WCD_HIT" in *"m$i.txt"*) named=$((named + 1)) ;; esac
  done
  expect_eq "wcd seven: the HIT line names at most five paths" "$named" "5"
  expect_has "wcd seven: the HIT line counts the rest" "$WCD_HIT" "+2 more"
}
