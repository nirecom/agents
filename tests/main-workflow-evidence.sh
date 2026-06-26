#!/bin/bash
# Tests: hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, bin, git
# Tests for evidence-based write_tests/docs enforcement
# in workflow-gate.js (PreToolUse) and workflow-mark.js (PostToolUse)
#
# Dispatcher: shared helpers/fixtures live in main-workflow-evidence/common.sh;
# case groups live in gate-and-mark.sh, worktree-notes.sh, evidence-resolver.sh.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/hooks/workflow-mark.js"

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/main-workflow-evidence"

# shellcheck source=./main-workflow-evidence/common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./main-workflow-evidence/gate-and-mark.sh
. "$SCRIPT_DIR/gate-and-mark.sh"
# shellcheck source=./main-workflow-evidence/worktree-notes.sh
. "$SCRIPT_DIR/worktree-notes.sh"
# shellcheck source=./main-workflow-evidence/evidence-resolver.sh
. "$SCRIPT_DIR/evidence-resolver.sh"

run_gate_and_mark_tests
run_worktree_notes_tests
run_evidence_resolver_tests

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
