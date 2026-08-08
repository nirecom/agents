#!/bin/bash
# Tests: hooks/workflow-state/inheritance.js, hooks/workflow-state/inheritance/lineage.js, hooks/workflow-state/inheritance/context-match.js, hooks/session-start.js
# Tags: workflow-state, session-inherit, lineage, regression-1305, scope:issue-specific, pwsh-not-required, TL2
# ===========================================================================
# #1305 — a NEW session must not inherit workflow state from an ABANDONED
# prior session that merely shared the same cwd + git branch.
#
# WHY (CPR-WPH): the pre-fix donor search was `findLatestStateForContext(ctx)`,
# a pure cwd+branch scan over recent transcripts. Two sessions started in the
# same worktree are indistinguishable to it, so a fresh `startup` session
# silently adopted the steps of a session the user had walked away from — and
# then the workflow gate let a commit through on completions nobody performed.
#
# The fix replaces "same context" with "provable descent": the heir must be a
# fork/resume/compact continuation of the donor, evidenced by the transcript
# (`forkedFrom` rows, or the copied SessionStart/PostCompact announce line).
# cwd+branch is demoted from *selector* to *guard*.
#
# fail-before-fix: every case below is written against
# `resolveInheritanceDonor()`, which does not exist yet. They fail with
# MISSING_EXPORT until hooks/workflow-state/inheritance/{lineage,context-match}.js
# land. That failure mode is the point — see the per-case comments for the
# behaviour each one pins.
#
# TL2 rationale: resolveInheritanceDonor is pure over (payload, ctx, on-disk
# state + transcripts), so real files + a real node process exercise it fully.
# # TL3 gap: only a real `claude -p` SessionStart can prove that Claude Code
# actually sends `source` and `transcript_path` in the payload, and that a real
# fork writes real `forkedFrom` rows. That single seam is covered by the
# `source=startup` assertion added to tests/TL3-hook-session-start/main.sh.
# ===========================================================================
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(dirname "$0")/feature-1305-inheritance-lineage"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) -------------------
# Neutral CWD, throwaway repos, and a DUAL PIN of CLAUDE_WORKFLOW_DIR +
# WORKFLOW_PLANS_DIR so nothing here can reach the developer's real
# ~/.claude/workflow-state or ~/.workflow-plans.
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
TBASE="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$TBASE"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# The outer Claude Code session exports these; a hook that inherits them would
# resolve the LIVE session and mutate its real state file.
unset CLAUDE_SESSION_ID 2>/dev/null || true
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
