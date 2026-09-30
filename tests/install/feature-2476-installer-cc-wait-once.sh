#!/usr/bin/env bash
# Tests: install.ps1, install.sh, install/lib/wait-cc-exit-target.ps1, install/lib/wait-cc-exit.ps1, install/lib/wait-cc-exit.sh, install/win/dotfileslink.ps1
# Tags: installer, wait-cc-exit, TL2, pwsh-required, scope:issue-specific
# #2476: parent waits for Claude Code once, hands the verdict to children via WAIT_CC_RESULT.

# TL3 gap:
#   - Real Desktop app (MSIX under WindowsApps) beside a CLI claude: real Get-Process .Path.
#   - install.ps1 / install.sh end-to-end (fnm/nvm, winget, network): static placement only.
#   - macOS `ps -o comm=` path lookup: Darwin-native only.
#   - ping.exe copies may be blocked (Defender/AppLocker); the store-path skip is predicate-only.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

# A value left behind by an interrupted install.ps1 must not steer the helpers under test.
unset WAIT_CC_RESULT WAIT_CC_PROCESS_OVERRIDE MOCK_PGREP_MODE WAIT_CC_POLL_INTERVAL WAIT_CC_MAX_POLLS

TMP="$(make_tmp)"
trap 'rm -rf "$TMP"' EXIT

_uname_s="$(uname -s 2>/dev/null || true)"
ON_WINDOWS_BASH=0
case "$_uname_s" in MINGW*|MSYS*|CYGWIN*) ON_WINDOWS_BASH=1 ;; esac
unset _uname_s

HAVE_PWSH=0
command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=1

WAIT_SH="$AGENTS_DIR/install/lib/wait-cc-exit.sh"
WAIT_PS="$AGENTS_DIR/install/lib/wait-cc-exit.ps1"
TARGET_PS="$AGENTS_DIR/install/lib/wait-cc-exit-target.ps1"
_SUBDIR="$AGENTS_DIR/tests/install/feature-2476-installer-cc-wait-once"

case_begin "desktop-shell-excluded-by-path-predicate" "install/lib/wait-cc-exit-target.ps1"
source "$_SUBDIR/target-predicate.sh"
case_end

case_begin "result-memo-short-circuits-helpers" "install/lib/wait-cc-exit.sh"
source "$_SUBDIR/memo.sh"
case_end

case_begin "helpers-list-waited-pids" "install/lib/wait-cc-exit.ps1"
source "$_SUBDIR/display.sh"
source "$_SUBDIR/display-mock.sh"
case_end

case_begin "parents-wait-once-before-children" "install.ps1"
source "$_SUBDIR/parent-placement.sh"
case_end

case_begin "dotfileslink-ps-skips-only-settings-write" "install/win/dotfileslink.ps1"
source "$_SUBDIR/dotfileslink-ps.sh"
case_end

case_begin "children-honor-parent-memo" "install/lib/wait-cc-exit.sh"
source "$_SUBDIR/child-memo-e2e.sh"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
