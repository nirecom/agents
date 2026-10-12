# A *.Tests.ps1 name holding ' $ ; and a backtick reaches Pester as one literal path:
# the wrapper gets it as one -File argv item and nothing in the name runs. Sourced by
# tests/tests/feature-2007-run-all-ps1-dispatch.sh (uses RUN_ALL, TMPDIR_FX, harness).
# shellcheck shell=bash

PQ="$TMPDIR_FX/pq"
PQ_NAME="x'; New-Item -ItemType File pq-sentinel; '\$y\`z.Tests.ps1"
mkdir -p "$PQ/fakebin"
printf 'Describe "q" { It "passes" { $true | Should -BeTrue } }\n' >"$PQ/$PQ_NAME"
PQ_DIR_NATIVE="$PQ"
if command -v cygpath >/dev/null 2>&1; then PQ_DIR_NATIVE="$(cygpath -m "$PQ")"; fi
# A stand-in pwsh first on PATH: it records its argv, one per line, and passes.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/argv"\nexit 0\n' "$PQ" >"$PQ/fakebin/pwsh"
chmod +x "$PQ/fakebin/pwsh"

# pq_run <tag> [PATH prefix] — the real runner on the file from $PQ; sets PQ_RC, keeps $PQ/<tag>.out.
pq_run() {
  PQ_RC=0
  (cd "$PQ" && PATH="${2:+$2:}$PATH" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 bash "$RUN_ALL" "$PQ/$PQ_NAME") \
    >"$PQ/$1.out" 2>&1 || PQ_RC=$?
}
pq_no_sentinel() {
  if [ -z "$(find "$PQ" -name 'pq-sentinel*' -print)" ]; then
    pass "$1: no pq-sentinel file — the name was never run as a command"
  else
    fail "$1: pq-sentinel exists — the test name was injected into the pwsh command"
  fi
}

case_begin "pester-path-quoting" "bin/lib/run-all-launch.sh"
# Q1 (#2501): pwsh runs the Pester wrapper with -File; the native path reaches it as ONE
# argv item with ' $ ; and the backtick verbatim (no quoting layer left to double into).
pq_run q1 "$PQ/fakebin"
q1_want="$(printf '%s\n' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '<wrapper>' \
  -Path "$PQ_DIR_NATIVE/$PQ_NAME" -MinVersion 5.0)"
q1_raw="$(cat "$PQ/argv" 2>/dev/null)"
# The wrapper item may be spelled through bin/lib/../..; compare it by file identity.
q1_wrap="$(printf '%s\n' "$q1_raw" | sed -n '6p')"
q1_wrap_posix="$q1_wrap"
if command -v cygpath >/dev/null 2>&1 && [ -n "$q1_wrap" ]; then q1_wrap_posix="$(cygpath -u "$q1_wrap")"; fi
q1_got="$(printf '%s\n' "$q1_raw" | sed '6s/.*/<wrapper>/')"
if [ "$PQ_RC" = "0" ] && [ "$q1_got" = "$q1_want" ] && [ -n "$q1_wrap" ] \
  && [ "$q1_wrap_posix" -ef "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/pester.ps1" ]; then
  pass "Q1: pwsh gets -File <pester wrapper> -Path <native path verbatim> -MinVersion 5.0"
else
  fail "Q1: pwsh argv mismatch — rc=$PQ_RC want=<<$q1_want>> got=<<$q1_got>> wrapper=<<$q1_wrap>>"
fi
pq_no_sentinel "Q1"

# Q2: with the real pwsh, Pester finds and passes the file and nothing else runs.
if command -v pwsh >/dev/null 2>&1; then
  pq_run q2
  if [ "$PQ_RC" = "0" ] && grep -qF "PASS: $PQ/$PQ_NAME" "$PQ/q2.out" && grep -qE 'Passed: 1' "$PQ/q2.out"; then
    pass "Q2: Pester runs the quoted file and its one test passes"
  else
    fail "Q2: quoted .Tests.ps1 did not pass under pwsh — rc=$PQ_RC out=$(tail -n 5 "$PQ/q2.out" | tr '\n' '|')"
  fi
  pq_no_sentinel "Q2"
else
  echo "INFO: Q2 skipped — pwsh not on PATH"
fi
case_end
