#!/bin/bash
# Tests: hooks/workflow-state/inheritance.js, hooks/workflow-state/inheritance/lineage.js, hooks/workflow-state/inheritance/context-match.js, hooks/session-start.js
# Tags: workflow-state, session-inherit, lineage, regression-1305, scope:issue-specific, pwsh-not-required, TL2
# #1305 — a NEW session must not inherit state from an ABANDONED prior session that merely shared
# cwd + branch: the session-downstream must be a provable fork/resume/compact continuation of the
# session-upstream (transcript `forkedFrom` rows or the copied announce line); cwd+branch is only a guard.
# TL2 rationale: resolveInheritanceUpstream is pure over (payload, ctx, on-disk state + transcripts).
# TL3 gap: only a real `claude -p` SessionStart proves the real `source`/`transcript_path` payload and
# real `forkedFrom` rows; covered by the source=startup case in tests/hooks/TL3-hook-session-start/main.sh.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASE_DIR="$(dirname "$0")/feature-1305-inheritance-lineage"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) -------------------
# Neutral CWD, throwaway repos, and a DUAL PIN of WORKFLOW_STATE_DIR +
# WORKFLOW_PLANS_DIR so nothing here can reach the developer's real
# ~/.claude/workflow-state or ~/.workflow-plans.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
TBASE="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$TBASE"
export WORKFLOW_STATE_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# The outer Claude Code session exports these; a hook that inherits them would
# resolve the LIVE session and mutate its real state file.
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# shellcheck source=./feature-1305-inheritance-lineage/_lib.sh
. "$CASE_DIR/_lib.sh"
# shellcheck source=./feature-1305-inheritance-lineage/gates.sh
. "$CASE_DIR/gates.sh"
# shellcheck source=./feature-1305-inheritance-lineage/lineage-context.sh
. "$CASE_DIR/lineage-context.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
