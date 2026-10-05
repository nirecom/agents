#!/usr/bin/env bash
# tests/install/feature-2513-plan-sync-init-ps1.sh
# Tests: install/win/plan-sync-init.ps1
# Tags: plan-sync, installer, pwsh-required, node-stub, TL2, scope:issue-specific
# #2513: the install.ps1 step wrapper driven by real pwsh with a stub `node` first on PATH.
# The driver mirrors Invoke-InstallStep (StrictMode, EAP=Stop, `& $Path`, then $LASTEXITCODE).
# Exit 77 (skip) when pwsh is unavailable.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - the real install.ps1 run calling this wrapper through Invoke-InstallStep
# - the real node binary executing bin/plan-sync-init (covered by tests/hooks/feature-2513-plan-sync-e2e.sh)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: pwsh-required.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

PWSH_BIN="$(command -v pwsh 2>/dev/null || true)"
if [[ -z "$PWSH_BIN" ]]; then
  skip "pwsh not available — plan-sync-init.ps1 cases skipped"
  exit 77
fi

PSI_IS_WIN=0
case "${OSTYPE:-}" in msys* | cygwin* | win32*) PSI_IS_WIN=1 ;; esac
case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) PSI_IS_WIN=1 ;; esac

PSI_ROOT="$(make_tmp)"
trap 'cd / 2>/dev/null; rm -rf "$PSI_ROOT"' EXIT
harness_isolate "$PSI_ROOT"
mkdir -p "$PSI_ROOT/neutral" "$PSI_ROOT/stub-bin" "$PSI_ROOT/empty-bin"
cd "$PSI_ROOT/neutral" || exit 1

# psi_host_path <path> — the form pwsh / cmd receive (Windows form on Windows).
psi_host_path() {
  if [[ "$PSI_IS_WIN" == 1 ]]; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

WRAPPER="$AGENTS_DIR/install/win/plan-sync-init.ps1"
DRIVER="$PSI_ROOT/driver.ps1"
printf '%s\n' \
  'param([string]$Wrapper)' \
  'Set-StrictMode -Version Latest' \
  '$ErrorActionPreference = "Stop"' \
  '$global:LASTEXITCODE = 99' \
  'try { & $Wrapper } catch { Write-Output "THREW=$($_.Exception.Message)" }' \
  'Write-Output "LEC=$global:LASTEXITCODE"' \
  'exit 0' > "$DRIVER"

STUB_LOG="$PSI_ROOT/node-stub.log"
if [[ "$PSI_IS_WIN" == 1 ]]; then
  printf '@echo off\r\n>>"%%PSI_STUB_LOG%%" echo(%%~1\r\nif not "%%~2"=="" >>"%%PSI_STUB_LOG%%" echo(EXTRA\r\nexit /b %%PSI_STUB_RC%%\r\n' \
    > "$PSI_ROOT/stub-bin/node.cmd"
  SYS_DIR="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"
  STUB_PATH="$PSI_ROOT/stub-bin:$SYS_DIR"
else
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$1" >> "$PSI_STUB_LOG"' \
    'if [ "$#" -gt 1 ]; then printf "EXTRA\n" >> "$PSI_STUB_LOG"; fi' 'exit "$PSI_STUB_RC"' \
    > "$PSI_ROOT/stub-bin/node"
  chmod +x "$PSI_ROOT/stub-bin/node"
  STUB_PATH="$PSI_ROOT/stub-bin:/usr/bin:/bin"
fi
export PSI_STUB_LOG; PSI_STUB_LOG="$(psi_host_path "$STUB_LOG")"

# run_wrapper <PATH value> <stub rc> <wrapper path> — sets OUT, LEC, STUB_LINES.
run_wrapper() {
  local ep=()
  [[ "$PSI_IS_WIN" == 1 ]] && ep=(-ExecutionPolicy Bypass)
  : > "$STUB_LOG"
  OUT="$(PSI_STUB_RC="$2" run_with_timeout 120 env PATH="$1" "$PWSH_BIN" -NoProfile -NonInteractive "${ep[@]}" \
    -File "$(psi_host_path "$DRIVER")" -Wrapper "$(psi_host_path "$3")" 2>&1)"
  LEC="$(printf '%s\n' "$OUT" | tr -d '\r' | sed -n 's/^LEC=//p' | tail -n 1)"
  STUB_LINES="$(tr -d '\r' < "$STUB_LOG" | tr '\\' '/')"
}

# expect_eq <name> <got> <want>
expect_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$3") got=$(printf '%q' "$2") out=$(printf '%q' "$OUT")"; fi
}

# expect_no_throw <name>
expect_no_throw() {
  if [[ "$OUT" == *"THREW="* ]]; then fail "$1" "out=$OUT"; else pass "$1"; fi
}

EXPECTED_CLI="$(np "$AGENTS_DIR")/bin/plan-sync-init"

case_begin "node-present-invokes-cli" "install/win/plan-sync-init.ps1"
run_wrapper "$STUB_PATH" 0 "$WRAPPER"
expect_eq "P1 node invoked once with the CLI two levels above install/win" "$STUB_LINES" "$EXPECTED_CLI"
if [[ -f "$STUB_LINES" ]]; then pass "P1 the resolved CLI path is the real bin/plan-sync-init file"
else fail "P1 the resolved CLI path is the real bin/plan-sync-init file" "not a file: $STUB_LINES"; fi
expect_eq "P1 LASTEXITCODE 0 when the CLI exits 0" "$LEC" "0"
expect_no_throw "P1 the step does not throw"
case_end

case_begin "node-absent-skips" "install/win/plan-sync-init.ps1"
run_wrapper "$PSI_ROOT/empty-bin" 0 "$WRAPPER"
if [[ "$OUT" == *"node not found. Plan sync skipped."* ]]; then pass "P2 prints the node-not-found skip message"
else fail "P2 prints the node-not-found skip message" "out=$OUT"; fi
expect_eq "P2 LASTEXITCODE reset to 0 (driver seeded 99)" "$LEC" "0"
expect_eq "P2 stub never invoked" "$STUB_LINES" ""
expect_no_throw "P2 the step does not throw"
case_end

case_begin "cli-failure-propagates-exit-code" "install/win/plan-sync-init.ps1"
run_wrapper "$STUB_PATH" 3 "$WRAPPER"
expect_eq "P3 LASTEXITCODE carries the CLI exit code 3" "$LEC" "3"
expect_eq "P3 node invoked once with the CLI" "$STUB_LINES" "$EXPECTED_CLI"
expect_no_throw "P3 a non-zero CLI exit is reported via LASTEXITCODE, not a throw"
case_end

case_begin "space-in-repo-path-single-arg" "install/win/plan-sync-init.ps1"
SPACED="$PSI_ROOT/repo with space"
mkdir -p "$SPACED/install/win"
cp "$WRAPPER" "$SPACED/install/win/plan-sync-init.ps1"
run_wrapper "$STUB_PATH" 0 "$SPACED/install/win/plan-sync-init.ps1"
expect_eq "P4 path with a space reaches node as one argument" "$STUB_LINES" "$(np "$SPACED")/bin/plan-sync-init"
expect_eq "P4 LASTEXITCODE 0" "$LEC" "0"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
