#!/usr/bin/env bash
# Contract tests for clarify-intent skill (Stage 1: interactive user interview)
# Target files (expected to FAIL until implementation is complete):
#   $HOME/.claude/skills/clarify-intent/SKILL.md
# Exit 0 always — this is a contract test, not a CI gate yet.

# Timeout guard: if running without the sentinel, re-exec under timeout
if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

SKILL_MD="$HOME/.claude/skills/clarify-intent/SKILL.md"
# Note: $HOME/.claude/skills/ is the *skill code* location and is unaffected
# by the workflow-plans-dir migration. Only planning artifact output paths
# (formerly ~/.claude/plans/) move to ~/.workflow-plans/.

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

# assert_contains FILE PATTERN DESCRIPTION
# Greps FILE for PATTERN (extended regex). Prints PASS/FAIL.
assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        pass "$desc"
        return 0
    else
        fail "$desc (pattern not found: $pattern)"
        return 1
    fi
}

# assert_absent FILE PATTERN DESCRIPTION
# Asserts FILE does NOT contain PATTERN. Prints PASS/FAIL.
assert_absent() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        fail "$desc (pattern unexpectedly found: $pattern)"
        return 1
    else
        pass "$desc"
        return 0
    fi
}

echo "=== clarify-intent contract tests ==="
echo ""

# ---------------------------------------------------------------------------
# Normal cases
# ---------------------------------------------------------------------------
echo "--- Normal ---"

# N1: frontmatter contains name: clarify-intent
assert_contains "$SKILL_MD" "name:[[:space:]]*clarify-intent" \
    "N1: frontmatter contains 'name: clarify-intent'"

# N2: interactive or AskUserQuestion appears (interactive context requirement)
assert_contains "$SKILL_MD" "interactive|AskUserQuestion" \
    "N2: 'interactive' or 'AskUserQuestion' appears (interactive context requirement)"

# N3: output path ~/.workflow-plans/ or $HOME/.workflow-plans/ mentioned
assert_contains "$SKILL_MD" '~/.workflow-plans/|\$HOME/.workflow-plans/' \
    "N3: output path ~/.workflow-plans/ or \$HOME/.workflow-plans/ mentioned"

# N4: <session-id>-intent.md output filename mentioned
assert_contains "$SKILL_MD" "session.id.*intent\.md|intent\.md" \
    "N4: session-id intent.md output filename mentioned"

# N5: recommended answer instruction mentioned
assert_contains "$SKILL_MD" '推奨|recommended|\(推奨\)' \
    "N5: recommended answer instruction mentioned (推奨 or recommended)"

# N6: 5-round cap mentioned
assert_contains "$SKILL_MD" "5.*round|round.*5|上限.*5|5.*上限" \
    "N6: 5-round cap mentioned"

# N7: skip sentinel (WORKFLOW_CLARIFY_INTENT_NOT_NEEDED) referenced
# plan-skip.md was removed; skip conditions are now inline in the skill.
assert_contains "$SKILL_MD" "WORKFLOW_CLARIFY_INTENT_NOT_NEEDED" \
    "N7: skip sentinel WORKFLOW_CLARIFY_INTENT_NOT_NEEDED referenced"

# N8: grill-me / Matt Pocock attribution mentioned
assert_contains "$SKILL_MD" "grill.me|Matt Pocock|mattpocock" \
    "N8: grill-me / Matt Pocock attribution mentioned"

# N9: intent.md mentioned in output context
assert_contains "$SKILL_MD" "intent\.md" \
    "N9: intent.md mentioned in output context"

echo ""
# ---------------------------------------------------------------------------
# WIP-state hookpoint (issue #362)
# W tests use LOCAL_SKILL_MD (worktree-relative) because $SKILL_MD points to
# $HOME/.claude/ (deployed/main) which won't have the changes until the PR merges.
# The feature-workflow-init-routing.sh convention is followed here.
# ---------------------------------------------------------------------------
echo "--- WIP-state (issue #362) ---"

LOCAL_SKILL_MD="$(cd "$(dirname "$0")/.." && pwd)/skills/clarify-intent/SKILL.md"

# W1: Completion section contains `wip-state.sh set <N>` instruction (Path A/B single-N).
assert_contains "$LOCAL_SKILL_MD" "wip-state\.sh.*set" \
    "W1: Completion section references wip-state.sh set <N> (single-N closes_issues)"

# W2: The wip-state.sh set call appears after the `intent:clarified` add-label
# instruction (i.e. ordering: label first, then WIP set). Check linearly: the
# line number of the first 'wip-state.sh' mention must be greater than the
# first 'intent:clarified' mention.
if [ ! -f "$LOCAL_SKILL_MD" ]; then
    fail "W2: ordering check (file not found)"
else
    LBL_LN=$(grep -n "intent:clarified" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    WIP_LN=$(grep -n "wip-state\.sh" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$LBL_LN" ] && [ -n "$WIP_LN" ] && [ "$WIP_LN" -gt "$LBL_LN" ]; then
        pass "W2: wip-state.sh set follows the intent:clarified add-label step"
    else
        fail "W2: wip-state.sh set must come after intent:clarified add-label (lbl_ln=$LBL_LN wip_ln=$WIP_LN)"
    fi
fi

# W3: Path C (empty / new issue) also invokes wip-state set <N>.
# The Path C section must mention wip-state set for the freshly created N.
if [ ! -f "$LOCAL_SKILL_MD" ]; then
    fail "W3: Path C wip-state coverage (file not found)"
else
    # Two-step check: there must be a "Path C" anchor and a wip-state set
    # mention; the simplest contract is that the file mentions both "Path C"
    # and "wip-state.sh set" (in either order).
    if grep -q "Path C" "$LOCAL_SKILL_MD" && grep -q "wip-state\.sh.*set" "$LOCAL_SKILL_MD"; then
        pass "W3: Path C (no issue) section + wip-state set both present"
    else
        fail "W3: Path C bullet or wip-state set call missing"
    fi
fi

# W4: Failure-handling text mentions wip-state-specific failure modes.
assert_contains "$LOCAL_SKILL_MD" "wip-state.*setup|wip-state set failed" \
    "W4: Completion section documents wip-state failure handling (setup hint / set-failed warn)"

echo ""
# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------
echo "--- Error ---"

# E1: hard-fail on non-interactive
assert_contains "$SKILL_MD" "hard.fail|hard_fail|診断|diagnostic" \
    "E1: hard-fail on non-interactive mentioned"

# E2: 'do not silently proceed' or '暗黙' prohibition mentioned
assert_contains "$SKILL_MD" "[Dd]o not silently proceed|暗黙" \
    "E2: 'do not silently proceed' or '暗黙' prohibition mentioned"

echo ""
# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
echo "--- Edge ---"

# Ed1: session-id appears in output path context (parameterized output)
assert_contains "$SKILL_MD" "session.id|session_id" \
    "Ed1: session-id appears in output path context (parameterized output)"

# Ed2: round limit is specifically 5 — check both "5" and "round" present in file
if [ ! -f "$SKILL_MD" ]; then
    fail "Ed2: round limit is specifically 5 (file not found: $SKILL_MD)"
elif grep -qE "5" "$SKILL_MD" && grep -qE "round" "$SKILL_MD"; then
    pass "Ed2: round limit is specifically 5 (both '5' and 'round' present in file)"
else
    fail "Ed2: round limit is specifically 5 (need both '5' and 'round' in file)"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
