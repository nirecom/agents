#!/usr/bin/env bash
# tests/bin/feature-2501-timed-exec.sh
# Tests: bin/lib/timed-exec.sh, bin/run-with-timeout.sh
# Tags: TL2, bin, timeout, signal, perl, process-group, scope:issue-specific, fired-file
# timed_exec (#2501) on both paths — GNU `timeout -k 2` and the perl fallback (PATH without
# `timeout`): expiry -> 124, exit-code passthrough, a TERM-ignoring child and its grandchild KILLed,
# a TERM to the caller reaching the wrapped test and its grandchild, the caller's traps restored —
# and the run-with-timeout.sh CLI that now delegates to it (perl path: 124, not 142).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
BG_PIDS=""
# Every pid a case spawns is recorded (BG_PIDS or a *.pid file) and KILLed here.
cleanup_te() {
  local p f
  for p in $BG_PIDS; do kill -KILL "$p" 2>/dev/null || true; done
  for f in "$TMPBASE"/p-*/*.pid; do
    [ -f "$f" ] || continue
    read -r p <"$f" || continue
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMPBASE"
}
trap cleanup_te EXIT
harness_isolate "$TMPBASE/iso"

TEX_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/timed-exec.sh"
RWT_CLI="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
BASH_BIN="${BASH:-$(command -v bash)}"

# te.sh <lib> <secs> <cmd...> — timed_exec in a fresh bash; exits with its rc (98: lib not loadable).
cat >"$TMPBASE/te.sh" <<'EOF'
. "$1" || exit 98
shift
timed_exec "$@"
exit $?
EOF

# ignorer.sh <piddir> — ignores TERM (its children inherit that) and keeps a grandchild sleep.
cat >"$TMPBASE/ignorer.sh" <<'EOF'
trap '' TERM
sleep 300 &
printf '%s\n' "$!" >"$1/gc.pid"
printf '%s\n' "$$" >"$1/c.pid"
while :; do sleep 1; done
EOF

# normal.sh <piddir> — an ordinary test holding a grandchild sleep.
cat >"$TMPBASE/normal.sh" <<'EOF'
sleep 300 &
printf '%s\n' "$!" >"$1/gc.pid"
printf '%s\n' "$$" >"$1/c.pid"
wait
EOF

# caller.sh <lib> <piddir> — a launcher-like caller blocked in timed_exec on normal.sh.
cat >"$TMPBASE/caller.sh" <<'EOF'
. "$1" || exit 98
timed_exec 60 bash "${0%/*}/normal.sh" "$2"
printf 'rc=%s\n' "$?" >"$2/caller.rc"
EOF

# traps.sh <lib> — traps before/after timed_exec (normal exit and expiry) and with no prior trap.
cat >"$TMPBASE/traps.sh" <<'EOF'
. "$1" || exit 98
d="${0%/*}"
trap 'echo X' TERM
trap 'echo Y' INT
trap 'echo Z' HUP
trap -p TERM INT HUP >"$d/trap.before"
timed_exec 5 bash -c 'exit 0'
trap -p TERM INT HUP >"$d/trap.after-ok"
timed_exec 1 sleep 5
trap -p TERM INT HUP >"$d/trap.after-expiry"
trap - TERM INT HUP
timed_exec 5 bash -c 'exit 0'
trap -p TERM INT HUP >"$d/trap.after-none"
EOF

# te <path-or-empty> <secs> <cmd...> — run te.sh, optionally under PATH=<path>; sets TE_RC, TE_EL.
te() {
  local p="$1" t0
  shift
  TE_RC=0
  t0=$SECONDS
  if [ -n "$p" ]; then
    run_with_timeout 40 env PATH="$p" "$BASH_BIN" "$TMPBASE/te.sh" "$TEX_LIB" "$@" >/dev/null 2>>"$TMPBASE/te.err" || TE_RC=$?
  else
    run_with_timeout 40 "$BASH_BIN" "$TMPBASE/te.sh" "$TEX_LIB" "$@" >/dev/null 2>>"$TMPBASE/te.err" || TE_RC=$?
  fi
  TE_EL=$((SECONDS - t0))
}

# rwt <path-or-empty> <args...> — the run-with-timeout.sh CLI; sets RWT_RC, RWT_EL.
rwt() {
  local p="$1" t0
  shift
  RWT_RC=0
  t0=$SECONDS
  if [ -n "$p" ]; then
    run_with_timeout 40 env PATH="$p" "$BASH_BIN" "$RWT_CLI" "$@" >/dev/null 2>>"$TMPBASE/rwt.err" || RWT_RC=$?
  else
    run_with_timeout 40 "$BASH_BIN" "$RWT_CLI" "$@" >/dev/null 2>>"$TMPBASE/rwt.err" || RWT_RC=$?
  fi
  RWT_EL=$((SECONDS - t0))
}

# wait_file <file> <secs> — 0 once <file> is non-empty.
wait_file() {
  local n=0 lim=$(($2 * 5))
  while [ ! -s "$1" ] && [ "$n" -lt "$lim" ]; do
    sleep 0.2
    n=$((n + 1))
  done
  [ -s "$1" ]
}

# wait_gone <secs> <pid>... — 0 once no pid answers kill -0; GONE_LEFT names survivors otherwise.
wait_gone() {
  local lim=$(($1 * 5)) n=0 p
  shift
  while :; do
    GONE_LEFT=""
    for p in "$@"; do
      if kill -0 "$p" 2>/dev/null; then GONE_LEFT="$GONE_LEFT $p"; fi
    done
    [ -z "$GONE_LEFT" ] && return 0
    [ "$n" -ge "$lim" ] && return 1
    sleep 0.2
    n=$((n + 1))
  done
}

# within <label> <elapsed> <max> <rc> — an elapsed-seconds bound, judged only on an expiry (rc 124);
# any other rc means the command never ran under timed_exec, so the bound cannot pass.
within() {
  if [ "$4" != 124 ]; then
    fail "$1" "no expiry observed (rc $4)"
  elif [ "$2" -le "$3" ]; then
    pass "$1 (${2}s <= ${3}s)"
  else
    fail "$1" "took ${2}s, bound ${3}s"
  fi
}

# trap_file <name> — a trap snapshot written by traps.sh, or <absent>.
trap_file() { if [ -f "$TMPBASE/trap.$1" ]; then cat "$TMPBASE/trap.$1"; else printf '<absent>'; fi; }

# check_kill <label> <path-or-empty> <allowed-rcs> — TERM-ignoring child + grandchild KILLed after expiry.
check_kill() {
  local pd="$TMPBASE/p-kill-$1" c gc
  mkdir -p "$pd"
  te "$2" 1 bash "$TMPBASE/ignorer.sh" "$pd"
  case " $3 " in
    *" $TE_RC "*) pass "$1: expiry rc $TE_RC" ;;
    *) fail "$1: expiry rc" "got $TE_RC, want one of: $3" ;;
  esac
  if ! wait_file "$pd/c.pid" 1; then
    fail "$1: wrapped child started" "no pid file (rc $TE_RC)"
    return 0
  fi
  read -r c <"$pd/c.pid"
  read -r gc <"$pd/gc.pid"
  if wait_gone 5 "$c" "$gc"; then
    pass "$1: TERM-ignoring child and grandchild gone"
  else
    fail "$1: TERM-ignoring child and grandchild gone" "alive:$GONE_LEFT"
  fi
}

# check_caller_term <label> <path-or-empty> — TERM to the caller reaches the test and its grandchild.
check_caller_term() {
  local pd="$TMPBASE/p-caller-$1" c gc cp
  mkdir -p "$pd"
  if [ -n "$2" ]; then
    PATH="$2" "$BASH_BIN" "$TMPBASE/caller.sh" "$TEX_LIB" "$pd" >/dev/null 2>>"$TMPBASE/caller.err" &
  else
    "$BASH_BIN" "$TMPBASE/caller.sh" "$TEX_LIB" "$pd" >/dev/null 2>>"$TMPBASE/caller.err" &
  fi
  cp=$!
  BG_PIDS="$BG_PIDS $cp"
  if ! wait_file "$pd/c.pid" 8; then
    fail "$1: wrapped test started under the caller" "no pid file"
    kill -KILL "$cp" 2>/dev/null || true
    return 0
  fi
  read -r c <"$pd/c.pid"
  wait_file "$pd/gc.pid" 2 || true
  read -r gc <"$pd/gc.pid"
  kill -TERM "$cp" 2>/dev/null || true
  if wait_gone 3 "$c" "$gc"; then
    pass "$1: wrapped test and grandchild gone within 3 s of the caller's TERM"
  else
    fail "$1: wrapped test and grandchild gone within 3 s of the caller's TERM" "alive:$GONE_LEFT"
  fi
  wait "$cp" 2>/dev/null || true
}

# --fired-file (#2501 C2): created only when timed_exec's own timer fires; the launcher's TIMEOUT
# verdict rests on it. A child returning 124 itself, any passthrough rc, a TERMed caller: absent.
# ff.sh <lib> <fired> <secs> <cmd...> — timed_exec --fired-file in a fresh bash (98: lib not loadable).
cat >"$TMPBASE/ff.sh" <<'EOF'
. "$1" || exit 98
f="$2"
shift 2
timed_exec --fired-file "$f" "$@"
exit $?
EOF

# ffcaller.sh <lib> <fired> <started> — blocks in timed_exec on a long sleep until TERMed.
cat >"$TMPBASE/ffcaller.sh" <<'EOF'
. "$1" || exit 98
timed_exec --fired-file "$2" 60 bash -c ': >"$1"; sleep 300' _ "$3"
EOF

# ff <path-or-empty> <tag> <secs> <cmd...> — sets FF_RC and FF_FIRED (fired|absent).
ff() {
  local p="$1" tag="$2" fired
  shift 2
  fired="$TMPBASE/$tag.fired"
  rm -f "$fired"
  FF_RC=0
  if [ -n "$p" ]; then
    run_with_timeout 40 env PATH="$p" "$BASH_BIN" "$TMPBASE/ff.sh" "$TEX_LIB" "$fired" "$@" >/dev/null 2>>"$TMPBASE/ff.err" || FF_RC=$?
  else
    run_with_timeout 40 "$BASH_BIN" "$TMPBASE/ff.sh" "$TEX_LIB" "$fired" "$@" >/dev/null 2>>"$TMPBASE/ff.err" || FF_RC=$?
  fi
  if [ -e "$fired" ]; then FF_FIRED=fired; else FF_FIRED=absent; fi
}

# check_fired <label> <path-or-empty> — the whole fired-file table on one timeout path.
check_fired() {
  local label="$1" p="$2" tag secs want_rc want_f cmd
  while IFS='|' read -r tag secs want_rc want_f cmd; do
    [ -n "$tag" ] || continue
    ff "$p" "$label-$tag" "$secs" bash -c "$cmd"
    assert_eq "$label $tag: rc=$FF_RC $FF_FIRED" "$label $tag: rc=$want_rc $want_f"
  done <<'ROWS'
expiry|1|124|fired|sleep 10
self-124-early|5|124|absent|exit 124
self-124-near-deadline|3|124|absent|sleep 2; exit 124
self-0|5|0|absent|exit 0
self-1|5|1|absent|exit 1
self-77|5|77|absent|exit 77
ROWS
  local pd="$TMPBASE/caller-ff-$label" cp n=0
  mkdir -p "$pd"
  if [ -n "$p" ]; then
    PATH="$p" "$BASH_BIN" "$TMPBASE/ffcaller.sh" "$TEX_LIB" "$pd/fired" "$pd/started" >/dev/null 2>>"$TMPBASE/ff.err" &
  else
    "$BASH_BIN" "$TMPBASE/ffcaller.sh" "$TEX_LIB" "$pd/fired" "$pd/started" >/dev/null 2>>"$TMPBASE/ff.err" &
  fi
  cp=$!
  BG_PIDS="$BG_PIDS $cp"
  while [ ! -e "$pd/started" ] && [ "$n" -lt 40 ]; do sleep 0.2; n=$((n + 1)); done
  if [ ! -e "$pd/started" ]; then
    fail "$label caller TERM: wrapped command started" "no start file"
    return 0
  fi
  kill -TERM "$cp" 2>/dev/null || true
  wait "$cp" 2>/dev/null || true
  if [ -e "$pd/fired" ]; then fail "$label caller TERM: no fired file" "fired file created"; else pass "$label caller TERM: no fired file"; fi
}

# --- perl-path environment: PATH holding only shims of the tools the cases need, none of them timeout.
SHIM="$TMPBASE/shim"
mkdir -p "$SHIM"
for tool in bash sh sleep perl cat env rm mkdir mktemp true false ps date dirname basename; do
  real="$(type -P "$tool" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  printf '#!%s\nexec "%s" "$@"\n' "$BASH_BIN" "$real" >"$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done
HAVE_GNU=0
if command -v timeout >/dev/null 2>&1; then HAVE_GNU=1; fi
HAVE_PERL_PATH=0
PERL_WHY="perl not on PATH"
if type -P perl >/dev/null 2>&1; then
  if env PATH="$SHIM" "$BASH_BIN" -c 'command -v timeout' >/dev/null 2>&1; then
    PERL_WHY="could not build a PATH without timeout"
  elif env PATH="$SHIM" "$BASH_BIN" -c 'perl -e "exit 0" && sleep 0' >/dev/null 2>&1; then
    HAVE_PERL_PATH=1
  else
    PERL_WHY="perl/sleep do not run through the shim PATH"
  fi
fi

case_begin "timed-exec-lib-present" "bin/lib/timed-exec.sh"
if [ -f "$TEX_LIB" ]; then
  pass "present: bin/lib/timed-exec.sh"
else
  fail "present: bin/lib/timed-exec.sh" "missing — every timed_exec case fails too"
fi
case_end

echo ""
echo "=== GNU timeout path ==="

case_begin "gnu-expiry-returns-124" "bin/lib/timed-exec.sh"
if [ "$HAVE_GNU" = 1 ]; then
  te "" 1 sleep 10
  assert_eq "gnu expiry rc: $TE_RC" "gnu expiry rc: 124"
  within "gnu expiry stops the command" "$TE_EL" 4 "$TE_RC"
else
  skip "gnu expiry: no timeout command on PATH"
fi
case_end

case_begin "gnu-exit-code-passthrough" "bin/lib/timed-exec.sh"
if [ "$HAVE_GNU" = 1 ]; then
  te "" 5 bash -c 'exit 0'
  assert_eq "gnu passthrough 0: $TE_RC" "gnu passthrough 0: 0"
  te "" 5 bash -c 'exit 3'
  assert_eq "gnu passthrough 3: $TE_RC" "gnu passthrough 3: 3"
else
  skip "gnu passthrough: no timeout command on PATH"
fi
case_end

case_begin "gnu-term-ignoring-child-is-killed" "bin/lib/timed-exec.sh"
if [ "$HAVE_GNU" = 1 ]; then
  check_kill gnu "" "124"
  # Only an expiry is rewritten: a command that dies of KILL before the limit keeps 137.
  te "" 10 bash -c 'kill -KILL $$'
  assert_eq "gnu own KILL before the limit: $TE_RC" "gnu own KILL before the limit: 137"
else
  skip "gnu kill: no timeout command on PATH"
fi
case_end

case_begin "gnu-caller-term-reaches-test-tree" "bin/lib/timed-exec.sh"
if [ "$HAVE_GNU" = 1 ]; then
  check_caller_term gnu ""
else
  skip "gnu caller TERM: no timeout command on PATH"
fi
case_end

case_begin "caller-traps-restored" "bin/lib/timed-exec.sh"
rm -f "$TMPBASE"/trap.*
tr_rc=0
run_with_timeout 40 "$BASH_BIN" "$TMPBASE/traps.sh" "$TEX_LIB" >/dev/null 2>>"$TMPBASE/traps.err" || tr_rc=$?
assert_eq "traps driver rc: $tr_rc" "traps driver rc: 0"
before="$(trap_file before)"
case "$before" in
  *"echo X"*"echo Y"*"echo Z"*) pass "traps set before the call" ;;
  *) fail "traps set before the call" "got [$before]" ;;
esac
# An absent snapshot (the driver stopped early) must not match an absent baseline.
for snap in after-ok after-expiry; do
  got="$(trap_file "$snap")"
  if [ "$got" = "<absent>" ]; then
    fail "$snap: traps restored" "no snapshot (driver rc $tr_rc)"
  else
    assert_eq "$snap: $got" "$snap: $before"
  fi
done
if [ -f "$TMPBASE/trap.after-none" ] && [ ! -s "$TMPBASE/trap.after-none" ]; then
  pass "no prior trap: none left behind"
else
  fail "no prior trap: none left behind" "$(cat "$TMPBASE/trap.after-none" 2>/dev/null || printf '<absent>')"
fi
case_end

echo ""
echo "=== perl fallback path ==="

case_begin "perl-expiry-returns-124" "bin/lib/timed-exec.sh"
if [ "$HAVE_PERL_PATH" = 1 ]; then
  te "$SHIM" 1 sleep 10
  assert_eq "perl expiry rc: $TE_RC" "perl expiry rc: 124"
  within "perl expiry stops the command" "$TE_EL" 4 "$TE_RC"
  te "$SHIM" 5 bash -c 'exit 3'
  assert_eq "perl passthrough 3: $TE_RC" "perl passthrough 3: 3"
else
  skip "perl path: $PERL_WHY"
fi
case_end

case_begin "perl-term-ignoring-child-is-killed" "bin/lib/timed-exec.sh"
if [ "$HAVE_PERL_PATH" = 1 ]; then
  check_kill perl "$SHIM" "124"
else
  skip "perl kill: $PERL_WHY"
fi
case_end

case_begin "perl-caller-term-reaches-test-tree" "bin/lib/timed-exec.sh"
if [ "$HAVE_PERL_PATH" = 1 ]; then
  check_caller_term perl "$SHIM"
else
  skip "perl caller TERM: $PERL_WHY"
fi
case_end

echo ""
echo "=== --fired-file ==="

case_begin "gnu-fired-file-only-on-own-expiry" "bin/lib/timed-exec.sh"
if [ "$HAVE_GNU" = 1 ]; then check_fired gnu ""; else skip "gnu fired-file: no timeout command on PATH"; fi
case_end

case_begin "perl-fired-file-only-on-own-expiry" "bin/lib/timed-exec.sh"
if [ "$HAVE_PERL_PATH" = 1 ]; then check_fired perl "$SHIM"; else skip "perl fired-file: $PERL_WHY"; fi
case_end

echo ""
echo "=== run-with-timeout.sh CLI ==="

case_begin "cli-passthrough-and-expiry-gnu" "bin/run-with-timeout.sh"
if [ "$HAVE_GNU" = 1 ]; then
  rwt "" 5 bash -c 'exit 3'
  assert_eq "cli gnu passthrough: $RWT_RC" "cli gnu passthrough: 3"
  rwt "" 1 sleep 10
  assert_eq "cli gnu expiry: $RWT_RC" "cli gnu expiry: 124"
  within "cli gnu expiry stops the command" "$RWT_EL" 4 "$RWT_RC"
else
  skip "cli gnu: no timeout command on PATH"
fi
case_end

case_begin "cli-passthrough-and-expiry-perl" "bin/run-with-timeout.sh"
if [ "$HAVE_PERL_PATH" = 1 ]; then
  rwt "$SHIM" 5 bash -c 'exit 3'
  assert_eq "cli perl passthrough: $RWT_RC" "cli perl passthrough: 3"
  rwt "$SHIM" 1 sleep 10
  assert_eq "cli perl expiry is 124 (not 142): $RWT_RC" "cli perl expiry is 124 (not 142): 124"
  within "cli perl expiry stops the command" "$RWT_EL" 4 "$RWT_RC"
else
  skip "cli perl: $PERL_WHY"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
