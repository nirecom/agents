# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/exec-state.sh
# Tests: bin/lib/run-tests-baseline-exec.sh
# Tags: run-tests, baseline, exec, test-result-contract, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# #2501: rtb_exec_one exports RUN_ALL_TIMEOUT_SECONDS=<timeout>, the launcher's TIMEOUT authority
# and, with bash's null registry timeout, its only bound (watchdog = +10 s backstop); it writes
# <logdir>/<i>.state, <i>.timedout on TIMEOUT, <i>.unrunnable on UNRUNNABLE, and the caller
# sees RTB_EXEC_STATE and RTB_EXEC_UNRUNNABLE beside RTB_EXEC_RC / RTB_EXEC_TIMEDOUT.

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"

# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"

# exec_state_probe <wt> <rel-path> <timeout> <logdir> — prints
# "RC=<n> TIMEDOUT=<0|1> STATE=<s> UNRUNNABLE=<0|1>" from one rtb_exec_one call (cwd = <wt>).
exec_state_probe() {
  mkdir -p "$4"
  (cd "$1" && run_with_timeout 60 bash -c \
    '. "$1" || exit 98; shift; rtb_exec_one "$@"; printf "RC=%s TIMEDOUT=%s STATE=%s UNRUNNABLE=%s\n" "${RTB_EXEC_RC:-unset}" "${RTB_EXEC_TIMEDOUT:-unset}" "${RTB_EXEC_STATE:-unset}" "${RTB_EXEC_UNRUNNABLE:-unset}"' \
    exec_state_probe "$EXEC_LIB" "$@" 2>/dev/null | grep '^RC=' | tail -1)
}

# state_file <logdir> — the single <i>.state a one-test probe left, or "<absent>".
state_file() {
  if [ -f "$1/1.state" ]; then tr -d '\r\n' < "$1/1.state"; else printf '<absent>'; fi
}

# mk_unrunnable_checkout <dir> — makes <dir> (already a checkout) carry its own launcher,
# registry and wrappers, with the bash entry requiring a tool no host has.
mk_unrunnable_checkout() {
  local d="$1"
  mkdir -p "$d/bin" "$d/hooks/lib"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$d/bin/"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$d/bin/run-with-timeout.sh"
  install_test_language_registry "$d" "$SCRIPT_CHECKOUT_ROOT" || return 1
  run_with_timeout 20 node -e '
const fs = require("fs");
const p = process.argv[1];
const t = JSON.parse(fs.readFileSync(p, "utf8"));
t.entries.find((e) => e.id === "bash").launch.requires = "no-such-tool-rtb";
fs.writeFileSync(p, JSON.stringify(t, null, 2) + "\n");
' "$(np "$d/hooks/lib/test-language-registry.json")"
}

run_exec_state_cases() {
  local wt="$TMPROOT/repo-exec-state" logs="$TMPROOT/exec-state-logs" r st
  mk_fixture_repo "$wt" >/dev/null
  printf '#!/usr/bin/env bash\nexit 124\n' > "$wt/tests/bin/test-exit124.sh"

  # ---- ES1: RTB_EXEC_STATE and <i>.state for PASS / FAIL / SKIP ----
  local rel want
  for rel in test-broken:PASS:0 test-preexisting:FAIL:1 test-skip:SKIP:77; do
    want="${rel#*:}"
    r="$(exec_state_probe "$wt" "tests/bin/${rel%%:*}.sh" 10 "$logs/es1-${rel%%:*}")"
    st="$(state_file "$logs/es1-${rel%%:*}")"
    if [ "$r" = "RC=${want#*:} TIMEDOUT=0 STATE=${want%%:*} UNRUNNABLE=0" ] && [ "$st" = "${want%%:*}" ]; then
      pass "ES1-${want%%:*}: ${rel%%:*} gives RTB_EXEC_STATE=${want%%:*} and a matching .state"
    else
      fail "ES1-${want%%:*}: expected RC=${want#*:} STATE=${want%%:*} UNRUNNABLE=0 + .state; got: ${r:-none} state=$st"
    fi
  done

  # ---- ES2: an immediate exit 124 is FAIL, not TIMEOUT (no .timedout) ----
  r="$(exec_state_probe "$wt" tests/bin/test-exit124.sh 10 "$logs/es2")"
  if [ "$r" = "RC=124 TIMEDOUT=0 STATE=FAIL UNRUNNABLE=0" ] && [ ! -e "$logs/es2/1.timedout" ]; then
    pass "ES2: immediate exit 124 → STATE=FAIL, no .timedout"
  else
    fail "ES2: expected RC=124 TIMEDOUT=0 STATE=FAIL, no .timedout; got: ${r:-none}"
  fi

  # ---- ES3: a per-test timeout is STATE=TIMEOUT with .timedout and .state ----
  r="$(exec_state_probe "$wt" tests/bin/test-sleep.sh 2 "$logs/es3")"
  st="$(state_file "$logs/es3")"
  if printf '%s' "$r" | grep -qE '^RC=124 TIMEDOUT=1 STATE=TIMEOUT UNRUNNABLE=0$' \
    && [ -e "$logs/es3/1.timedout" ] && [ "$st" = TIMEOUT ]; then
    pass "ES3: per-test timeout → RC=124 STATE=TIMEOUT with .timedout and .state"
  else
    fail "ES3: expected RC=124 TIMEDOUT=1 STATE=TIMEOUT + markers; got: ${r:-none} state=$st"
  fi
}

# ES4: the timeout reaches the test's whole tree — a backgrounded `sleep 300` grandchild is gone
# within 3 s of rtb_exec_one returning.
run_exec_grandchild_cases() {
  local wt="$TMPROOT/repo-exec-gc" logs="$TMPROOT/exec-gc-logs" pidf="$TMPROOT/gc.pid" r gpid n alive
  mk_fixture_repo "$wt" >/dev/null
  printf '#!/usr/bin/env bash\nsleep 300 &\necho $! > "%s"\nwait\n' "$(np "$pidf")" > "$wt/tests/bin/test-grandchild.sh"
  r="$(exec_state_probe "$wt" tests/bin/test-grandchild.sh 2 "$logs/es4")"
  gpid="$(tr -d '\r\n' < "$pidf" 2>/dev/null)"
  if [ -z "$gpid" ]; then
    fail "ES4: fixture error — the grandchild pid was never written (probe: ${r:-none})"
    return
  fi
  alive=1
  for n in 1 2 3 4 5 6; do
    if ! kill -0 "$gpid" 2>/dev/null; then alive=0; break; fi
    sleep 0.5
  done
  if [ "$alive" -eq 0 ] && printf '%s' "$r" | grep -q 'STATE=TIMEOUT'; then
    pass "ES4: timeout kills the sleep 300 grandchild within 3 s (STATE=TIMEOUT)"
  else
    fail "ES4: grandchild $gpid alive=$alive after 3 s; probe: ${r:-none}"
    kill -9 "$gpid" 2>/dev/null || true
  fi
}

# ES5: a base checkout whose table requires a missing tool for the test's language gives
# RC=79, RTB_EXEC_UNRUNNABLE=1, STATE=UNRUNNABLE and <i>.unrunnable naming the tool.
run_exec_unrunnable_cases() {
  local wt="$TMPROOT/repo-exec-unrun" logs="$TMPROOT/exec-unrun-logs" r
  mk_fixture_repo "$wt" >/dev/null
  if ! mk_unrunnable_checkout "$wt"; then
    fail "ES5: fixture error — could not install the registry into $wt"
    return
  fi
  r="$(exec_state_probe "$wt" tests/bin/test-preexisting.sh 10 "$logs/es5")"
  if [ "$r" = "RC=79 TIMEDOUT=0 STATE=UNRUNNABLE UNRUNNABLE=1" ]; then
    pass "ES5: missing requires at base → RC=79 STATE=UNRUNNABLE RTB_EXEC_UNRUNNABLE=1"
  else
    fail "ES5: expected RC=79 TIMEDOUT=0 STATE=UNRUNNABLE UNRUNNABLE=1; got: ${r:-none}"
  fi
  if grep -qF no-such-tool-rtb "$logs/es5/1.unrunnable" 2>/dev/null; then
    pass "ES5: <i>.unrunnable names the missing tool"
  else
    fail "ES5: <i>.unrunnable missing or without the tool label; logdir: $(ls -A "$logs/es5" 2>/dev/null | tr '\n' ' ')"
  fi
}
