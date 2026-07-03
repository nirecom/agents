#!/bin/bash
# Tests: hooks/lib/workflow-state.js, hooks/session-start.js, hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, settings, config, scope:common
# Integration regression tests for the Workflow State Machine.
# Covers: state inheritance, cross-repo commits, RESET_FROM, USER_VERIFIED,
# branch isolation, and structure smoke tests.
# Usage: bash tests/main-workflow-state-machine.sh
#
# Dispatcher: shared helpers/fixtures live in main-workflow-state-machine/common.sh;
# case groups live in state-inheritance.sh, cross-repo-commit.sh, reset-from.sh,
# user-verified.sh, branch-isolation.sh, structure-smoke.sh.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/hooks/workflow-mark.js"
SESSION_START="$DOTFILES_DIR/hooks/session-start.js"
WORKFLOW_STATE_LIB="$DOTFILES_DIR/hooks/lib/workflow-state.js"
SETTINGS="$DOTFILES_DIR/settings.json"

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir: Node.js and bash must share the same filesystem path
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
    WORKFLOW_STATE_LIB_NODE=$(echo "$WORKFLOW_STATE_LIB" | sed 's|^/\([a-zA-Z]\)/|\1:/|')
else
    TMPDIR_BASE=$(mktemp -d)
    WORKFLOW_STATE_LIB_NODE="$WORKFLOW_STATE_LIB"
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/main-workflow-state-machine"

# shellcheck source=./main-workflow-state-machine/common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./main-workflow-state-machine/state-inheritance.sh
. "$SCRIPT_DIR/state-inheritance.sh"
# shellcheck source=./main-workflow-state-machine/cross-repo-commit.sh
. "$SCRIPT_DIR/cross-repo-commit.sh"
# shellcheck source=./main-workflow-state-machine/reset-from.sh
. "$SCRIPT_DIR/reset-from.sh"
# shellcheck source=./main-workflow-state-machine/user-verified.sh
. "$SCRIPT_DIR/user-verified.sh"
# shellcheck source=./main-workflow-state-machine/branch-isolation.sh
. "$SCRIPT_DIR/branch-isolation.sh"
# shellcheck source=./main-workflow-state-machine/structure-smoke.sh
. "$SCRIPT_DIR/structure-smoke.sh"

run_state_inheritance_tests
run_cross_repo_commit_tests
run_reset_from_tests
run_user_verified_tests
run_branch_isolation_tests
run_structure_smoke_tests

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
