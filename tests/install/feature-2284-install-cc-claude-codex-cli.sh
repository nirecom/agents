#!/bin/bash
# tests/install/feature-2284-install-cc-claude-codex-cli.sh
# Tests: install/lib/wait-cc-exit.sh, install/lib/wait-cc-exit.ps1, install/linux/claude-code.sh, install/win/claude-code.ps1, install/linux/codex.sh, install/win/codex.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
# Dispatcher — logic in tests/install/feature-2284-install-cc-claude-codex-cli/ (split at 500-line limit).
# TL3 gap: real process detection and real update execution; see sub-file headers for details.
# Closest-to-action: bin/check-verification-gate.sh category: installer.
# #2476: WAIT_CC_RESULT is unset here (parent memo: clear/timeout short-circuits the helper).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"
SUITE_DIR="$AGENTS_DIR/tests/install/feature-2284-install-cc-claude-codex-cli"

# #2476 result memo: a leftover WAIT_CC_RESULT would short-circuit the helper cases, and the
# PS installer path inherits the parent env.
unset WAIT_CC_RESULT

WAIT_SH="$AGENTS_DIR/install/lib/wait-cc-exit.sh"
WAIT_PS="$AGENTS_DIR/install/lib/wait-cc-exit.ps1"
CC_SH="$AGENTS_DIR/install/linux/claude-code.sh"
CC_PS="$AGENTS_DIR/install/win/claude-code.ps1"
CODEX_SH="$AGENTS_DIR/install/linux/codex.sh"
CODEX_PS="$AGENTS_DIR/install/win/codex.ps1"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Shared helpers: static update-guard detectors (Groups C/D, ORTH) and installer stub runners (Group F).
source "$SUITE_DIR/install-update.sh"
source "$SUITE_DIR/exec-integration.sh"

# --- Group A: wait-cc-exit helpers ---

case_begin "wait-sh-polls-until-claude-exits" "install/lib/wait-cc-exit.sh"
source "$SUITE_DIR/wait-helper.sh"
case_end

case_begin "wait-ps-polls-until-claude-exits" "install/lib/wait-cc-exit.ps1"
source "$SUITE_DIR/wait-helper-ps.sh"
case_end

# --- Group C: claude-code installers ---

case_begin "claude-code-sh-update-guarded" "install/linux/claude-code.sh"
check_update_group "C" "$CC_SH" "claude" "sh"
case_end

case_begin "claude-code-ps-update-guarded" "install/win/claude-code.ps1"
check_update_group "C4" "$CC_PS" "claude" "ps"
case_end

# --- Group D: codex installers ---

case_begin "codex-sh-update-guarded" "install/linux/codex.sh"
check_update_group "D" "$CODEX_SH" "codex" "sh"
case_end

case_begin "codex-ps-update-guarded" "install/win/codex.ps1"
check_update_group "D4" "$CODEX_PS" "codex" "ps"
case_end

# --- CPR-ORTH: guard is symmetric across both platforms ---

case_begin "claude-update-guard-symmetric" "install/linux/claude-code.sh"
orth_update_guard_pair "claude" "$CC_SH" "$CC_PS"
case_end

case_begin "codex-update-guard-symmetric" "install/linux/codex.sh"
orth_update_guard_pair "codex" "$CODEX_SH" "$CODEX_PS"
case_end

# --- Mutation probes: the detectors above must discriminate ---

case_begin "update-guard-detectors-reject-mutants" "install/linux/claude-code.sh"
source "$SUITE_DIR/mutation-probes.sh"
case_end

# --- Group E: exit-code contract ---

case_begin "sh-guard-timeout-keeps-caller-exit-0" "install/linux/claude-code.sh"
source "$SUITE_DIR/exit-contract-sh.sh"
case_end

# --- Group F: real installer execution with stubs ---

case_begin "claude-code-sh-exec-update-gated" "install/linux/claude-code.sh"
_run_exec_group_sh "F1" "$CC_SH" "claude"
case_end

case_begin "codex-sh-exec-update-gated" "install/linux/codex.sh"
_run_exec_group_sh "F2" "$CODEX_SH" "codex"
case_end

# pwsh-executing cases (A4-A6, E2/E2b, F3/F4) live in
# tests/install/feature-2284-install-cc-claude-codex-cli.Tests.ps1.

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
