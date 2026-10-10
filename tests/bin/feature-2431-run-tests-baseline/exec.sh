# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/exec.sh
# Tests: bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, exec, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# Plan contract: rtb_exec_one <wt> <rel-path> <timeout> <logdir> launches via run_all_exec
# (<wt>/bin/lib/run-all-launch.sh if present) and returns RTB_EXEC_RC / RTB_EXEC_TIMEDOUT;
# TIMEDOUT comes from <logdir>/<i>.timedout, never from the exit code.

# exec_probe <wt> <rel-path> <timeout> <logdir> — prints "RC=<n> TIMEDOUT=<0|1>".
# cwd is the checkout, as the CLI runs it.
exec_probe() {
  mkdir -p "$4"
  (cd "$1" && run_with_timeout 60 bash -c \
    '. "$1" || exit 98; shift; rtb_exec_one "$@"; printf "RC=%s TIMEDOUT=%s\n" "${RTB_EXEC_RC:-unset}" "${RTB_EXEC_TIMEDOUT:-unset}"' \
    exec_probe "$EXEC_LIB" "$@" 2>/dev/null | grep '^RC=' | tail -1)
}

run_exec_cases() {
  if [ ! -f "$EXEC_LIB" ]; then
    local id
    for id in E1 E2 E3 E4 E5 E6; do
      fail "$id: bin/lib/run-tests-baseline-exec.sh not found (impl pending)"
    done
    return
  fi
  local wt="$TMPROOT/repo-exec" logs="$TMPROOT/exec-logs" r
  mk_fixture_repo "$wt" >/dev/null
  printf '#!/usr/bin/env bash\nexit 124\n' > "$wt/tests/bin/test-exit124.sh"
  mkdir -p "$logs"

  # ---- E1 / E2: plain fail and pass ----
  r="$(exec_probe "$wt" tests/bin/test-preexisting.sh 10 "$logs/e1")"
  [ "$r" = "RC=1 TIMEDOUT=0" ] && pass "E1: exit-1 test → RTB_EXEC_RC=1, not timed out" \
    || fail "E1: expected RC=1 TIMEDOUT=0, got: ${r:-none}"
  r="$(exec_probe "$wt" tests/bin/test-broken.sh 10 "$logs/e2")"
  [ "$r" = "RC=0 TIMEDOUT=0" ] && pass "E2: exit-0 test → RTB_EXEC_RC=0" \
    || fail "E2: expected RC=0 TIMEDOUT=0, got: ${r:-none}"

  # ---- E3: watchdog timeout → TIMEDOUT=1 and a .timedout marker in logdir ----
  local t0 t1
  t0="$(date +%s)"
  r="$(exec_probe "$wt" tests/bin/test-sleep.sh 1 "$logs/e3")"
  t1="$(date +%s)"
  if printf '%s' "$r" | grep -q 'TIMEDOUT=1$' \
    && [ -n "$(find "$logs/e3" -name '*.timedout' 2>/dev/null | head -1)" ] \
    && [ $((t1 - t0)) -lt 30 ]; then
    pass "E3: per-test timeout → RTB_EXEC_TIMEDOUT=1 with .timedout file"
  else
    fail "E3: expected TIMEDOUT=1 + .timedout within 30s, got: ${r:-none} ($((t1 - t0))s)"
  fi

  # ---- E4: exit 77 surfaces as RC=77 (skip-at-base is decided by the CLI) ----
  r="$(exec_probe "$wt" tests/bin/test-skip.sh 10 "$logs/e4")"
  [ "$r" = "RC=77 TIMEDOUT=0" ] && pass "E4: exit-77 test → RTB_EXEC_RC=77" \
    || fail "E4: expected RC=77 TIMEDOUT=0, got: ${r:-none}"

  # ---- E5: exit 124 without the watchdog firing is NOT a timeout ----
  r="$(exec_probe "$wt" tests/bin/test-exit124.sh 10 "$logs/e5")"
  [ "$r" = "RC=124 TIMEDOUT=0" ] && pass "E5: TIMEDOUT comes from the .timedout file, not exit 124" \
    || fail "E5: expected RC=124 TIMEDOUT=0, got: ${r:-none}"

  # ---- E6: the checkout's own bin/lib/run-all-launch.sh is preferred ----
  local wt6="$TMPROOT/repo-exec-own-launcher"
  mk_fixture_repo "$wt6" >/dev/null
  mkdir -p "$wt6/bin/lib"
  printf 'run_all_exec() { printf used > "%s"; return 5; }\n' "$(np "$TMPROOT/e6-marker")" \
    > "$wt6/bin/lib/run-all-launch.sh"
  r="$(exec_probe "$wt6" tests/bin/test-broken.sh 10 "$logs/e6")"
  if [ "$r" = "RC=5 TIMEDOUT=0" ] && [ -f "$TMPROOT/e6-marker" ]; then
    pass "E6: <wt>/bin/lib/run-all-launch.sh run_all_exec is used when present"
  else
    fail "E6: checkout launcher not used, got: ${r:-none}"
  fi
}

# exec_isolation_probe <wt> <logdir> — rtb_exec_one on test-broken.sh with RTB_EXEC_SEQ=41 and
# leaked session vars in the caller; prints "RET=<n> SEQ=<n> RC=<v>" (RET = rtb_exec_one's status).
exec_isolation_probe() {
  mkdir -p "$2"
  (cd "$1" && export CLAUDE_CODE_SESSION_ID=leak-csid && run_with_timeout 60 bash -c \
    '. "$1" || exit 98; RTB_EXEC_SEQ=41; rtb_exec_one "$2" tests/bin/test-broken.sh 10 "$3"; printf "RET=%s SEQ=%s RC=%s\n" "$?" "$RTB_EXEC_SEQ" "${RTB_EXEC_RC:-unset}"' \
    _ "$EXEC_LIB" "$1" "$2" 2>/dev/null | grep '^RET=' | tail -1)
}

# E7-E9: the base checkout's launcher is sourced in a subshell only, a launcher that fails to
# source is a setup failure (return 2), and the test child sees an isolated environment.
run_exec_isolation_cases() {
  local logs="$TMPROOT/exec-iso-logs" wt r
  wt="$TMPROOT/repo-exec-e7"; mk_fixture_repo "$wt" >/dev/null; mkdir -p "$wt/bin/lib"
  printf 'RTB_EXEC_SEQ=999\nRTB_EXEC_RC=zzz\nrun_all_exec() { RTB_EXEC_SEQ=998; return 3; }\n' \
    > "$wt/bin/lib/run-all-launch.sh"
  r="$(exec_isolation_probe "$wt" "$logs/e7")"
  [ "$r" = "RET=0 SEQ=42 RC=3" ] && pass "E7: launcher writes to RTB_EXEC_SEQ/RC never reach the caller" \
    || fail "E7: expected RET=0 SEQ=42 RC=3, got: ${r:-none}"

  wt="$TMPROOT/repo-exec-e8"; mk_fixture_repo "$wt" >/dev/null; mkdir -p "$wt/bin/lib"
  printf 'return 1\nrun_all_exec() { return 0; }\n' > "$wt/bin/lib/run-all-launch.sh"
  r="$(exec_isolation_probe "$wt" "$logs/e8")"
  [ "$r" = "RET=2 SEQ=42 RC=unset" ] && pass "E8: a launcher that fails to source makes rtb_exec_one return 2" \
    || fail "E8: expected RET=2 SEQ=42 RC=unset, got: ${r:-none}"

  wt="$TMPROOT/repo-exec-e9"; mk_fixture_repo "$wt" >/dev/null; mkdir -p "$wt/bin/lib"
  cat > "$wt/bin/lib/run-all-launch.sh" << 'EOF'
run_all_exec() {
  printf 'CSID=%s\nWF=%s\nPL=%s\nTR=%s\nHOME=%s\n' \
    "${CLAUDE_CODE_SESSION_ID-<unset>}" \
    "${WORKFLOW_STATE_DIR-}" "${WORKFLOW_PLANS_DIR-}" "${CLAUDE_TRANSCRIPT_BASE_DIR-}" "$HOME" > "$2"
  return 0
}
EOF
  r="$(exec_isolation_probe "$wt" "$logs/e9")"
  local dump="$logs/e9/42.out" v iso
  v="$(grep -E '^CSID=' "$dump" 2>/dev/null | tr '\n' ' ')"
  [ "$r" = "RET=0 SEQ=42 RC=0" ] && [ "$v" = "CSID=<unset> " ] \
    && pass "E9-session: CLAUDE_CODE_SESSION_ID unset in the base test" \
    || fail "E9-session: probe=${r:-none} session vars=${v:-none}"
  iso="$(sed -n 's/^WF=\(.*\)\/workflow$/\1/p' "$dump" 2>/dev/null)"
  if [ -n "$iso" ] && grep -qxF "PL=$iso/plans" "$dump" && grep -qxF "TR=$iso/transcripts" "$dump" \
    && [ ! -e "$iso" ]; then
    pass "E9-dirs: workflow/plans/transcript dirs share one temp parent, removed after return"
  else
    fail "E9-dirs: iso=${iso:-none} exists=$([ -n "$iso" ] && [ -e "$iso" ] && echo yes || echo no) dump=$(tr '\n' '|' < "$dump" 2>/dev/null)"
  fi
  grep -qxF "HOME=$HOME" "$dump" && pass "E9-home: HOME is passed through unchanged (the temp home of this test)" \
    || fail "E9-home: HOME changed; dump HOME=$(grep '^HOME=' "$dump" 2>/dev/null)"
}
