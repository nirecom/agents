#!/bin/bash
# Tests: bin/workflow/adopt-session-state, bin/workflow/lib/workflow-init/phases/adopt-prior-state.js
# Tags: workflow-state, session-inherit, adopt, regression-1305, scope:issue-specific, pwsh-not-required, TL2
# ===========================================================================
# #1305 SD-4 — the EXPLICIT adoption path.
#
# WHY (CPR-WPH): once automatic cwd+branch inheritance is removed, a genuine
# crash-resume has no way back to its own work. The replacement is explicit and
# has exactly ONE execution point (CPR-SSOT): the `adopt-session-state` CLI.
# `/workflow-init`'s new `adopt-prior-state` phase is merely a *route to* that
# CLI for interactive sessions — it must never grow a second copy of the
# adoption logic, and non-interactive sessions must reach the same CLI by hand.
#
# fail-before-fix: neither bin/workflow/adopt-session-state nor
# bin/workflow/lib/workflow-init/phases/adopt-prior-state.js exists yet, so
# every case below fails until SD-4 lands. That is the intended red phase.
#
# TL2 rationale: the CLI and the driver phase are both plain node processes over
# real fixture files, so a real spawn exercises them end to end.
# # TL3 gap: only a real interactive Claude Code session can prove that the
# emitted ACTION=ask_user directive actually reaches AskUserQuestion and that a
# real `$CI` host suppresses it. AD-9/AD-10 pin the env contract by exporting
# and unsetting CI / CLAUDE_NON_INTERACTIVE explicitly, so the assertion never
# depends on the CI setting of whatever machine runs the suite.
# ===========================================================================
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(dirname "$0")/feature-1305-adopt-session-state"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) -------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
TBASE="$TMPDIR_BASE/transcripts"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$TBASE"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Never resolve the live session: each case passes its own heir sid explicitly.
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# AD-9/AD-10 own these; neutralise whatever the host runner set.
unset CI 2>/dev/null || true
unset CLAUDE_NON_INTERACTIVE 2>/dev/null || true

# shellcheck source=./feature-1305-adopt-session-state/_lib.sh
. "$CASE_DIR/_lib.sh"
# shellcheck source=./feature-1305-adopt-session-state/cli.sh
. "$CASE_DIR/cli.sh"
# shellcheck source=./feature-1305-adopt-session-state/phase.sh
. "$CASE_DIR/phase.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
