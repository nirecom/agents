#!/bin/bash
# Tests: bin/get-config-var.ps1
# Tags: bin, pwsh, env, config, tests, scope:common, pwsh-required
# Drives the Pester suite for bin/get-config-var.ps1 (#893 + #954).
#
# Skip-gates: pwsh must be on PATH; otherwise exit 77 (skipped).
# Most assertions are pre-implementation and will fail until /write-code
# updates bin/get-config-var.ps1.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PESTER_FILE="$REPO_ROOT/tests/fix-get-config-var-hardening.Tests.ps1"

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 77; }

if [ ! -f "$PESTER_FILE" ]; then
    echo "FAIL: Pester file missing: $PESTER_FILE"
    exit 1
fi

# Convert bash-style path (e.g. /c/git/...) to Windows path (C:\git\...) for pwsh
PESTER_FILE_WIN="$PESTER_FILE"
if [[ "$PESTER_FILE" =~ ^/([a-zA-Z])/ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${PESTER_FILE#/?/}"
    PESTER_FILE_WIN="${drive^^}:/${rest}"
fi

rc=0
run_with_timeout pwsh -NoProfile -Command "Invoke-Pester -Path '$PESTER_FILE_WIN' -CI" || rc=$?
exit "$rc"
