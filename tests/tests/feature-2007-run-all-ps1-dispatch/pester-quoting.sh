# A *.Tests.ps1 name holding ' $ ; and a backtick reaches Pester as one literal path:
# {nativePathSq} doubles each ' and nothing in the name runs. Sourced by
# tests/tests/feature-2007-run-all-ps1-dispatch.sh (uses RUN_ALL, TMPDIR_FX, harness).
# shellcheck shell=bash

PQ="$TMPDIR_FX/pq"
PQ_NAME="x'; New-Item -ItemType File pq-sentinel; '\$y\`z.Tests.ps1"
PQ_NAME_SQ="x''; New-Item -ItemType File pq-sentinel; ''\$y\`z.Tests.ps1"
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
  (cd "$PQ" && PATH="${2:+$2:}$PATH" bash "$AGENTS_DIR/bin/run-with-timeout.sh" 180 bash "$RUN_ALL" "$PQ/$PQ_NAME") \
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
# Q1: the -Command argument is the registry row with {nativePathSq} filled in.
pq_run q1 "$PQ/fakebin"
q1_want="$(printf '%s\n' -NoProfile -Command "Invoke-Pester -Path '$PQ_DIR_NATIVE/$PQ_NAME_SQ' -CI")"
q1_got="$(cat "$PQ/argv" 2>/dev/null)"
if [ "$PQ_RC" = "0" ] && [ "$q1_got" = "$q1_want" ]; then
  pass "Q1: pwsh gets -Command with every ' doubled and \$ ; backtick kept literal"
else
  fail "Q1: pwsh argv mismatch — rc=$PQ_RC want=<<$q1_want>> got=<<$q1_got>>"
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
