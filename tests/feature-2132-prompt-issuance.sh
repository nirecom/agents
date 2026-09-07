#!/bin/bash
# tests/feature-2132-prompt-issuance.sh
# Tests: skills, skills/_shared, hooks/bash-guard/judge.js, rules
# Tags: prompt-issuance, bash-guard, inventory, corpus, TL1, pwsh-not-required, scope:issue-specific

set -u

# #2132 (detail.md S6) — prompt assets tell Claude to run commands that the
# #2134 bash guard would make the user approve. R1 capture->stdout, R2 multi-line
# snippet->script, R3 pipe extraction->one-liner, R4 arg substitution->default.
# This suite drives a measured ledger of every conversion site.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2132-prompt-issuance"

# TL3 gap: whether Claude Code actually raises a permission prompt for a given
# command line is only observable in a live session. Closest-to-action
# mitigation: P2 asks the same judge module the PreToolUse hook consumes.

if command -v cygpath >/dev/null 2>&1; then AN="$(cygpath -m "$AGENTS_DIR")"; else AN="$AGENTS_DIR"; fi
TSV="$SUITE_DIR/inventory.tsv"
PROBE="$SUITE_DIR/judge-probe.js"

# Fixture isolation (rules/test/fixture-isolation.md): read-only corpus checks,
# but the parent session's ids must not reach the child node process.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Pin a fixture HOME with a KNOWN empty permissions.allow -- otherwise the
# judge's allow-rule matching depends on whatever settings.json the developer's
# real HOME happens to carry, and P2's "allow" verdicts stop being reproducible
# (modeled on tests/feature-2134-bash-guard.sh:70-78). Plans dir pinned in the
# same breath as the workflow dir per rules/test/fixture-isolation.md.
P2_TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/prompt-issuance-2132.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$P2_TMPROOT"' EXIT
FIXTURE_HOME="$P2_TMPROOT/home"
mkdir -p "$FIXTURE_HOME/.claude"
printf '%s\n' '{"permissions":{"allow":[],"deny":[]}}' > "$FIXTURE_HOME/.claude/settings.json"
export HOME="$FIXTURE_HOME"
export USERPROFILE="$FIXTURE_HOME"
export CLAUDE_WORKFLOW_DIR="$P2_TMPROOT/workflow"
export WORKFLOW_PLANS_DIR="$P2_TMPROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want='$want' got='$got'"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if [ -x "$AGENTS_DIR/bin/run-with-timeout.sh" ]; then "$AGENTS_DIR/bin/run-with-timeout.sh" "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Availability guards — an absent ledger or node would score every case vacuously.
if ! command -v node >/dev/null 2>&1; then
    fail "harness: node unavailable — every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
for required in "$TSV" "$PROBE" "$SUITE_DIR/check.sh"; do
    if [ ! -f "$required" ]; then
        fail "harness: $required missing — every case below would be vacuous"
        echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
    fi
done

# shellcheck source=./feature-2132-prompt-issuance/check.sh
. "$SUITE_DIR/check.sh"

run_P0; run_P1; run_P2; run_P3; run_P4; run_P5

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
