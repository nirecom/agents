# #2483 at the run-all boundary: two Pester files run at -j 2 from one cwd. Each run writes
# its testResults.xml into its own result dir, so neither run reads the other's file, both
# pass, and the cwd holds no testResults.xml. Sourced by
# tests/tests/feature-2007-run-all-ps1-dispatch.sh (uses RUN_ALL, TMPDIR_FX, harness).
# shellcheck shell=bash

PP="$TMPDIR_FX/pp"
mkdir -p "$PP/cwd"
# Each file sleeps inside its test, so at -j 2 the two Pester runs overlap in time.
for n in 1 2; do
  printf 'Describe "pp%s" { It "pp%s-case" { Start-Sleep -Seconds 2; $true | Should -BeTrue } }\n' "$n" "$n" \
    >"$PP/cwd/pp$n.Tests.ps1"
done

pp_pester5() {
  command -v pwsh >/dev/null 2>&1 || return 1
  bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 pwsh -NoProfile -NonInteractive -Command \
    'if (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 }) { exit 0 } else { exit 1 }' \
    >/dev/null 2>&1
}

case_begin "pester-parallel-result-dirs" "tests/run-all.sh"
if ! pp_pester5; then
  skip "pester-parallel-result-dirs — pwsh or Pester 5 not available"
else
  PP_RC=0
  (cd "$PP/cwd" && bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 300 bash "$RUN_ALL" -j 2 \
    "$PP/cwd/pp1.Tests.ps1" "$PP/cwd/pp2.Tests.ps1") >"$PP/out" 2>&1 || PP_RC=$?
  assert_eq "pp rc=$PP_RC" "pp rc=0"
  for n in 1 2; do
    if grep -qE "^PASS: .*pp$n\.Tests\.ps1\$" "$PP/out"; then
      pass "pp$n: file-level PASS"
    else
      fail "pp$n: no file-level PASS line" "$(tail -n 8 "$PP/out" | tr '\n' '|')"
    fi
    # The case line is read from that unit's own result dir: a shared one would attribute
    # the other file's case here, or lose this one.
    other=$((3 - n))
    if grep -qE "^PASS [^ ]*pp$n\.Tests\.ps1::.*pp$n-case" "$PP/out" \
      && ! grep -qE "^[A-Z]+ [^ ]*pp$n\.Tests\.ps1::.*pp$other-case" "$PP/out"; then
      pass "pp$n: its own case record only"
    else
      fail "pp$n: case records missing or mixed between the two runs" "$(grep -E '::' "$PP/out" | tr '\n' '|')"
    fi
  done
  assert_eq "pp contract: $(grep -E '^RUN_CONTRACT: ' "$PP/out")" \
    "pp contract: RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
  if [ -e "$PP/cwd/testResults.xml" ]; then
    fail "pp: testResults.xml written into the shared cwd"
  else
    pass "pp: no testResults.xml in the shared cwd"
  fi
fi
case_end

# run-all removes its work dir on exit, so a third, plain bash unit run alongside the two
# Pester units copies every testResults.xml under run-all's TMPDIR out before the run ends.
case_begin "pester-parallel-distinct-xml" "tests/run-all.sh"
if ! pp_pester5; then
  skip "pester-parallel-distinct-xml — pwsh or Pester 5 not available"
else
  PX="$PP/x"
  mkdir -p "$PX/cwd" "$PX/tmp" "$PX/cap"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'px_root=%q\npx_cap=%q\n' "$PX/tmp" "$PX/cap"
    cat <<'PX_EOF'
for _ in $(seq 1 200); do
  [ "$(find "$px_root" -name testResults.xml 2>/dev/null | wc -l)" -ge 2 ] && break
  sleep 0.2
done
sleep 1
find "$px_root" -name testResults.xml 2>/dev/null >"$px_cap/list"
k=0
while IFS= read -r x; do k=$((k + 1)); cp "$x" "$px_cap/$k.xml"; done <"$px_cap/list"
exit 0
PX_EOF
  } >"$PX/cwd/ppx-collect.sh"
  PX_RC=0
  (cd "$PX/cwd" && TMPDIR="$PX/tmp" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 300 bash "$RUN_ALL" -j 3 \
    "$PP/cwd/pp1.Tests.ps1" "$PP/cwd/pp2.Tests.ps1" "$PX/cwd/ppx-collect.sh") >"$PX/out" 2>&1 || PX_RC=$?
  assert_eq "px rc=$PX_RC" "px rc=0"
  px_n="$(grep -c . "$PX/cap/list" 2>/dev/null)"
  px_a="$(sed -n 1p "$PX/cap/list" 2>/dev/null)"
  px_b="$(sed -n 2p "$PX/cap/list" 2>/dev/null)"
  if [ "${px_n:-0}" = "2" ] && [ "$px_a" != "$px_b" ] && [ "$(dirname "$px_a")" != "$(dirname "$px_b")" ]; then
    pass "px: two testResults.xml in two distinct result dirs"
  else
    fail "px: want 2 testResults.xml in distinct result dirs under run-all's work dir" \
      "n=${px_n:-0} list=<<$(tr '\n' '|' <"$PX/cap/list" 2>/dev/null)>> out=$(tail -n 6 "$PX/out" | tr '\n' '|')"
  fi
  px_seen=""
  for k in 1 2; do
    x="$PX/cap/$k.xml"
    own=""
    for n in 1 2; do grep -q "pp$n-case" "$x" 2>/dev/null && own="$own$n"; done
    if [ "$own" = "1" ] || [ "$own" = "2" ]; then
      other=$((3 - own))
      if grep -q "pp$own\.Tests\.ps1" "$x" && ! grep -q "pp$other\.Tests\.ps1" "$x"; then
        pass "px xml $k: names only pp$own's file and case"
        px_seen="$px_seen$own"
      else
        fail "px xml $k: names pp$own-case but its file reference is missing or mixed"
      fi
    else
      fail "px xml $k: names cases <<$own>> (want exactly one of pp1 / pp2)"
    fi
  done
  if [ "$px_seen" = "12" ] || [ "$px_seen" = "21" ]; then
    pass "px: pp1 and pp2 each own one result XML"
  else
    fail "px: result XMLs do not cover pp1 and pp2 once each" "seen=<<$px_seen>>"
  fi
fi
case_end
