#!/bin/bash
# tests/feature-2284-install-cc-claude-codex-cli.sh
# Tests: install/lib/wait-cc-exit.sh, install/lib/wait-cc-exit.ps1, install/linux/claude-code.sh, install/win/claude-code.ps1, install/linux/codex.sh, install/win/codex.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
# Dispatcher — logic in tests/feature-2284-install-cc-claude-codex-cli/ (split at 500-line limit).
# TL3 gap: real process detection and real update execution; see sub-file headers for details.
# Closest-to-action: bin/check-verification-gate.sh category: installer.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE_DIR="$AGENTS_DIR/tests/install/feature-2284-install-cc-claude-codex-cli"

FAIL=0
for _sub in "$SUITE_DIR/wait-helper.sh" "$SUITE_DIR/install-update.sh" "$SUITE_DIR/exec-integration.sh"; do
    bash "$_sub" || FAIL=$((FAIL + 1))
done

[ "$FAIL" -eq 0 ] || exit 1
exit 0
