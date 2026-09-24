#!/bin/bash
# Tests: install/win/pwsh.ps1
# Tags: pwsh-required, installer, scope:common, TL2
# Drives the Pester suite for install/win/pwsh.ps1.
# TL3 gap: real winget/MSI execution on a Windows host; only unit/stub assertions run here.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PESTER_FILE="$REPO_ROOT/tests/main-pwsh.Tests.ps1"

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 77; }
[ -f "$PESTER_FILE" ] || { echo "FAIL: Pester file missing: $PESTER_FILE"; exit 1; }

PESTER_FILE_WIN="$PESTER_FILE"
if [[ "$PESTER_FILE" =~ ^/([a-zA-Z])/ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${PESTER_FILE#/?/}"
    PESTER_FILE_WIN="${drive^^}:/${rest}"
fi

rc=0
bash "$REPO_ROOT/bin/run-with-timeout.sh" 180 pwsh -NoProfile -Command "Invoke-Pester -Path '$PESTER_FILE_WIN' -CI" || rc=$?
exit "$rc"
