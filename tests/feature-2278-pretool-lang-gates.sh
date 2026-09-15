#!/bin/bash
# tests/feature-2278-pretool-lang-gates.sh
# Tests: hooks/gate-plan-lang.js, hooks/gate-worktree-notes-lang.js, hooks/lib/pretool-lang-gate.js, hooks/lib/plan-artifact-lang.js, settings.json
# Tags: lang, hook, pretooluse, plans, worktree-notes, TL2, scope:issue-specific
# #2278 — PreToolUse language gates that reject a plan-artifact / WORKTREE_NOTES.md
# write BEFORE it lands on disk (PostToolUse checkers stay as backstops).
# Dispatcher: fixtures + helpers, then sources feature-2278-pretool-lang-gates/
# (SHL lib unit, PLG plan gate, WNG notes gate, SET settings registration).
# lang-check: ignore -- this suite intentionally contains CJK test fixtures for language-policy tests
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - real Claude Code PreToolUse dispatch of the two gates: whether a live session
#   delivers the event with the assumed payload shape (SET-T4/T5 narrow this — they
#   execute the registration line itself — leaving only the live dispatch uncovered)
# - whether a PreToolUse `decision:block` really prevents the write on disk in a
#   live session (here the hooks are run with a synthetic stdin payload)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PLAN_GATE="$AGENTS_DIR/hooks/gate-plan-lang.js"
NOTES_GATE="$AGENTS_DIR/hooks/gate-worktree-notes-lang.js"
PRETOOL_LIB="$AGENTS_DIR/hooks/lib/pretool-lang-gate.js"
PLAN_ARTIFACT_LIB="$AGENTS_DIR/hooks/lib/plan-artifact-lang.js"
SETTINGS_JSON="$AGENTS_DIR/settings.json"
PRETOOL_LIB_NODE="$AGENTS_DIR_NODE/hooks/lib/pretool-lang-gate.js"
WRITE_TOOLS_LIB_NODE="$AGENTS_DIR_NODE/hooks/lib/write-tools.js"
PLAN_ARTIFACT_LIB_NODE="$AGENTS_DIR_NODE/hooks/lib/plan-artifact-lang.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Portable timeout wrapper (rules/test/macos-timeout.md)
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Fixture isolation (rules/test/fixture-isolation.md): one temp root; plans dir
# and workflow dir pinned as a pair; session ids removed inside run_gate.
NODE_TMPDIR="$(run_with_timeout 10 node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
TEST_ROOT="${NODE_TMPDIR}/f2278-$$"
PLANS_DIR="${TEST_ROOT}/plans"
WORKFLOW_DIR="${TEST_ROOT}/workflow"
NEUTRAL_CWD="${TEST_ROOT}/cwd"
OUTSIDE_DIR="${TEST_ROOT}/outside"
mkdir -p "$PLANS_DIR" "$WORKFLOW_DIR" "$NEUTRAL_CWD" "$OUTSIDE_DIR"
trap 'rm -rf "$TEST_ROOT"' EXIT

export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"

# RED-phase visibility: name missing sources so a MODULE_NOT_FOUND below is attributable.
for _src in "$PLAN_GATE" "$NOTES_GATE" "$PRETOOL_LIB" "$PLAN_ARTIFACT_LIB"; do
    [ -f "$_src" ] || echo "NOTE: source missing (tests-first RED): $_src"
done

CASE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2278-pretool-lang-gates"

# shellcheck source=./feature-2278-pretool-lang-gates/helpers.sh
. "$CASE_DIR/helpers.sh"
# shellcheck source=./feature-2278-pretool-lang-gates/shell-cases.sh
. "$CASE_DIR/shell-cases.sh"
# shellcheck source=./feature-2278-pretool-lang-gates/gate-plan-lang-cases.sh
. "$CASE_DIR/gate-plan-lang-cases.sh"
# shellcheck source=./feature-2278-pretool-lang-gates/gate-worktree-notes-lang-cases.sh
. "$CASE_DIR/gate-worktree-notes-lang-cases.sh"
# shellcheck source=./feature-2278-pretool-lang-gates/settings-cases.sh
. "$CASE_DIR/settings-cases.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
