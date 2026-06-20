#!/bin/bash
# Tests: bin/confirm-off.ps1
# Tags: pwsh-required, bin, env, config, scope:common
# Drives the Pester suite for bin/confirm-off.ps1.
#
# Skip-gates: pwsh on PATH AND bin/confirm-off.ps1 must exist; otherwise
# exit 77 (skipped). All assertions are pre-implementation and will fail
# until /write-code adds bin/confirm-off.ps1.
#
# L3 gap (what this test does NOT catch):
# - Real symlink from ~/.local/bin/confirm-off or ~/.local/bin/confirm-off.ps1
#   exercising the actual installed path on the user's machine.
# - Real Windows pwsh subprocess (not mocked) with actual AGENTS_CONFIG_DIR
#   pointing to the user's live C:\git\agents installation.
# - WSL bash PATH resolution for #677: confirm-off.ps1 is only reachable via
#   AGENTS_CONFIG_DIR absolute path from WSL bash; this test invokes pwsh
#   directly and cannot reproduce the WSL→Windows cross-boundary call.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PESTER_FILE="$REPO_ROOT/tests/feature-confirm-off.Tests.ps1"

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 77; }
[ -f "$REPO_ROOT/bin/confirm-off.ps1" ] || { echo "SKIP: bin/confirm-off.ps1 not implemented yet"; exit 77; }
[ -f "$PESTER_FILE" ] || { echo "FAIL: Pester file missing: $PESTER_FILE"; exit 1; }

# Convert bash-style path (/c/git/...) to Windows path (C:/git/...) for pwsh
PESTER_FILE_WIN="$PESTER_FILE"
if [[ "$PESTER_FILE" =~ ^/([a-zA-Z])/ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${PESTER_FILE#/?/}"
    PESTER_FILE_WIN="${drive^^}:/${rest}"
fi

rc=0
run_with_timeout pwsh -NoProfile -Command "Invoke-Pester -Path '$PESTER_FILE_WIN' -CI" || rc=$?
exit "$rc"
