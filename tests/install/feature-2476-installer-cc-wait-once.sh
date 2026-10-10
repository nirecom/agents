#!/usr/bin/env bash
# Tests: install.ps1, install.sh, install/lib/wait-cc-exit.sh
# Tags: installer, wait-cc-exit, TL2, pwsh-required, scope:issue-specific
# #2476: parent waits for Claude Code once, hands the verdict to children via WAIT_CC_RESULT.
# pwsh-executing cases: tests/install/feature-2476-installer-cc-wait-once.Tests.ps1.

# TL3 gap:
#   - install.sh end-to-end (nvm, network): static placement only.
#   - macOS `ps -o comm=` path lookup: Darwin-native only.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/home-userprofile-pin.sh"

# A value left behind by an interrupted install.ps1 must not steer the helpers under test.
unset WAIT_CC_RESULT WAIT_CC_PROCESS_OVERRIDE MOCK_PGREP_MODE WAIT_CC_POLL_INTERVAL WAIT_CC_MAX_POLLS

TMP="$(make_tmp)"
trap 'rm -rf "$TMP"' EXIT

_uname_s="$(uname -s 2>/dev/null || true)"
ON_WINDOWS_BASH=0
case "$_uname_s" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS_BASH=1 ;; esac
unset _uname_s

WAIT_SH="$SCRIPT_CHECKOUT_ROOT/install/lib/wait-cc-exit.sh"
_SUBDIR="$SCRIPT_CHECKOUT_ROOT/tests/install/feature-2476-installer-cc-wait-once"
source "$_SUBDIR/parent-placement-lib.sh"

case_begin "result-memo-short-circuits-helpers" "install/lib/wait-cc-exit.sh"
source "$_SUBDIR/memo.sh"
case_end

case_begin "helpers-list-waited-pids" "install/lib/wait-cc-exit.sh"
source "$_SUBDIR/display.sh"
case_end

case_begin "ps-parent-waits-once-before-children" "install.ps1"
source "$_SUBDIR/parent-placement-ps.sh"
case_end

case_begin "sh-parent-waits-once-before-children" "install.sh"
source "$_SUBDIR/parent-placement-sh.sh"
case_end

case_begin "children-honor-parent-memo" "install/lib/wait-cc-exit.sh"
source "$_SUBDIR/child-memo-e2e.sh"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
