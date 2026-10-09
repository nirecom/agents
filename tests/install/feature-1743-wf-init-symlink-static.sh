#!/bin/bash
# tests/install/feature-1743-wf-init-symlink-static.sh
# Tests: install/win/dotfileslink.ps1, install/linux/dotfileslink.sh, .gitignore
# Tags: installer, symlink, wf-init, gitignore, dotfileslink, scope:issue-specific
#
# Issue #1743: installer-created directory symlink alias /wf-init -> /workflow-init.
# Both installers must create skills/wf-init as a symlink to skills/workflow-init
# (CPR-ORTH symmetry), and the generated path must stay untracked (.gitignore).
#
# Layer: TL2 (static/grep over the real installer sources; no installer execution).
set -u

# TL3 gap (what this test does NOT catch):
# - Whether the symlink is actually created on a real Windows host (Developer Mode /
#   admin privileges, MSYS winsymlinks) and on a real POSIX host.
# - Whether Claude Code's skill scanner resolves /wf-init to the same SKILL.md
#   without erroring or double-counting the skill in the slash-command list.
# Accepted tradeoff: real-machine verification of the symlink approach was explicitly
# deferred by user decision for this session (see outline.md).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PS_FILE="$SCRIPT_CHECKOUT_ROOT/install/win/dotfileslink.ps1"
SH_FILE="$SCRIPT_CHECKOUT_ROOT/install/linux/dotfileslink.sh"
GITIGNORE_FILE="$SCRIPT_CHECKOUT_ROOT/.gitignore"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
SUITE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/install/feature-1743-wf-init-symlink-static"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$SUITE_DIR/detectors.sh"

case_begin "win-entry-repo-internal-dir-link" "install/win/dotfileslink.ps1"
source "$SUITE_DIR/win-link.sh"
case_end

case_begin "sh-entry-outside-claude-git-guard" "install/linux/dotfileslink.sh"
source "$SUITE_DIR/sh-link.sh"
case_end

case_begin "wf-init-link-symmetric-across-installers" "install/linux/dotfileslink.sh"
source "$SUITE_DIR/link-orth.sh"
case_end

case_begin "win-dest-anchor-rejects-claude-dir" "install/win/dotfileslink.ps1"
source "$SUITE_DIR/link-root-mutant.sh"
case_end

case_begin "gitignore-lists-wf-init" ".gitignore"
source "$SUITE_DIR/gitignore.sh"
case_end

case_begin "wf-init-link-declared-once" "install/linux/dotfileslink.sh"
source "$SUITE_DIR/link-once.sh"
case_end

case_begin "sh-settings-write-guarded-by-cc-wait" "install/linux/dotfileslink.sh"
source "$SUITE_DIR/guard-sh.sh"
case_end

case_begin "ps-settings-write-guarded-by-cc-wait" "install/win/dotfileslink.ps1"
source "$SUITE_DIR/guard-ps.sh"
case_end

case_begin "sh-guard-detectors-reject-mutants" "install/linux/dotfileslink.sh"
source "$SUITE_DIR/guard-mutants-sh.sh"
case_end

case_begin "ps-guard-detectors-reject-mutants" "install/win/dotfileslink.ps1"
source "$SUITE_DIR/guard-mutants-ps.sh"
case_end

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
