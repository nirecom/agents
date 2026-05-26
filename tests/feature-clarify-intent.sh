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

# W1: Completion section references wip-state.sh set for all closes_issues (per-N loop).
assert_contains "$LOCAL_SKILL_MD" "WIP set for all entries|for each issue N in \`closes_issues\`|wip-state\.sh.*set" \
    "W1: Completion section references wip-state.sh set for all closes_issues (per-N loop)"

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

# W4: Failure-handling text mentions per-N wip-state failure modes.
assert_contains "$LOCAL_SKILL_MD" "wip-state set failed for #|wip-state.*setup" \
    "W4: Completion section documents per-N wip-state failure handling (failed for #<N> / setup hint)"

# W11: Completion WIP loop documents best-effort per-N error policy.
assert_contains "$LOCAL_SKILL_MD" "best-effort per-N|continue with the remaining entries" \
    "W11: Completion WIP loop documents best-effort per-N policy"

echo ""
# ---------------------------------------------------------------------------
# Guard wiring (issue #449)
# G tests use LOCAL_SKILL_MD (worktree-relative) — not yet deployed.
# ---------------------------------------------------------------------------
echo "--- Guard wiring (issue #449) ---"

# G1: dual invocation eliminated — only 1 'invoke' verb line for make-outline-plan
# Regex anchored on invocation verb to avoid false-positives from comments/links.
if [ -f "$LOCAL_SKILL_MD" ]; then
    COUNT=$(grep -cE '^[[:space:]]*(- )?[Tt]hen invoke (the )?`/?make-outline-plan`' "$LOCAL_SKILL_MD" || true)
    if [ "$COUNT" -eq 1 ]; then
        pass "G1: exactly 1 'invoke make-outline-plan' directive (dual invocation eliminated)"
    else
        fail "G1: expected 1 invoke directive, got $COUNT (dual invocation present or missing)"
    fi
else
    fail "G1: LOCAL_SKILL_MD not found"
fi

# G2: the remaining invocation lives below ## Completion (not in Procedure)
if [ -f "$LOCAL_SKILL_MD" ]; then
    COMPLETION_LN=$(grep -n '^## Completion' "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    INVOKE_LN=$(grep -nE '^[[:space:]]*(- )?[Tt]hen invoke (the )?`/?make-outline-plan`' "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$COMPLETION_LN" ] && [ -n "$INVOKE_LN" ] && [ "$INVOKE_LN" -gt "$COMPLETION_LN" ]; then
        pass "G2: invoke directive is below ## Completion (ln $INVOKE_LN > $COMPLETION_LN)"
    else
        fail "G2: invoke directive not found below Completion (completion_ln=$COMPLETION_LN invoke_ln=${INVOKE_LN:-missing})"
    fi
else
    fail "G2: LOCAL_SKILL_MD not found"
fi

# G3: guard script reference present in SKILL.md
assert_contains "$LOCAL_SKILL_MD" "check-closes-issues-nonempty\.sh" \
    "G3: check-closes-issues-nonempty.sh referenced in SKILL.md"

# G4: SSOT pointer (parse-closes-issues.js) present in SKILL.md
assert_contains "$LOCAL_SKILL_MD" "parse-closes-issues\.js" \
    "G4: parse-closes-issues.js SSOT pointer present in SKILL.md"

# G5: terminal-only directive in Procedure Step 6
assert_contains "$LOCAL_SKILL_MD" "exits exclusively via the Completion" \
    "G5: Procedure Step 6 contains terminal-only directive"

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
# ---------------------------------------------------------------------------
# Issue #462: Class members — disposition schema and interview design
# ---------------------------------------------------------------------------
echo "--- Issue #462: Class members ---"

# Reuse LOCAL_SKILL_MD (worktree-relative path) — N10-N13 target unmerged changes.
# LOCAL_SKILL_MD is already defined earlier in this file.

# N10: ## Class members mandatory section in intent.md schema
assert_contains "$LOCAL_SKILL_MD" "Class members" \
    "N10: '## Class members' mandatory section referenced in clarify-intent SKILL.md"

# N11: single multiSelect question pattern (not 2-stage)
assert_contains "$LOCAL_SKILL_MD" "multiSelect" \
    "N11: multiSelect question pattern in clarify-intent SKILL.md"

# N12: disposition enum values — 3-value enum (issue #558 replaces 2-value legacy)
assert_contains "$LOCAL_SKILL_MD" '\bMUST\b' \
    "N12a: 'MUST' disposition enum value in SKILL.md (3-value enum)"
assert_contains "$LOCAL_SKILL_MD" '\bOPTIONAL\b' \
    "N12b: 'OPTIONAL' disposition enum value in SKILL.md (3-value enum)"

# N12c: 2-stage multiSelect pattern present (Stage 1 and Stage 2 in SKILL.md)
assert_contains "$LOCAL_SKILL_MD" "Stage 1|Stage 2" \
    "N12c: 2-stage multiSelect pattern present (Stage 1 / Stage 2 in SKILL.md)"

# N12d: candidates > 4 truncation rule suppressed for class-members question
assert_contains "$LOCAL_SKILL_MD" "does NOT apply|no.*truncation.*4|truncation.*does not apply" \
    "N12d: candidates-truncation-4 rule explicitly suppressed for class members"

# N13: no cap別枠 wording (class members question is inside the 5-round cap, not extra)
assert_absent "$LOCAL_SKILL_MD" "[Cc]ap 別枠|cap.*extra.*round|extra.*round.*cap" \
    "N13: no 'cap別枠' wording — class members question counts within 5-round cap"

echo ""
# ---------------------------------------------------------------------------
# Issue #444: N issues per session
# Tests M1-M6 are pre-implementation assertions — FAIL until source changes land.
# ---------------------------------------------------------------------------
echo "--- Issue #444: N issues per session ---"

# M1: LOCAL_SKILL_MD contains `For each issue N` (N-iteration in Completion).
assert_contains "$LOCAL_SKILL_MD" "For each issue N" \
    "M1: clarify-intent Completion contains 'For each issue N' (N-iteration)"

# M2: LOCAL_SKILL_MD contains `primary` somewhere in the file.
assert_contains "$LOCAL_SKILL_MD" "primary" \
    "M2: clarify-intent Completion section mentions 'primary'"

# M3: Doctrine line 'One issue per session' must be removed.
assert_absent "$LOCAL_SKILL_MD" "One issue per session" \
    "M3: 'One issue per session' doctrine line removed"

# M4: Blocker '**Multiple**: abort' must be removed.
assert_absent "$LOCAL_SKILL_MD" '\*\*Multiple\*\*: abort' \
    "M4: '**Multiple**: abort' blocker removed"

# M5: SSOT reference to either rules/github-issues.md or 'Session model'.
assert_contains "$LOCAL_SKILL_MD" "rules/github-issues\.md|Session model" \
    "M5: SSOT reference to rules/github-issues.md or 'Session model' present"

# M6: Mutex guard proximity check — if 'Which is the primary' appears in
# LOCAL_SKILL_MD, then within the 30 lines preceding it the literal
# '<!-- workflow-init: confirmed primary' must appear. If 'Which is the primary'
# is absent entirely, FAIL.
if [ ! -f "$LOCAL_SKILL_MD" ]; then
    fail "M6: mutex guard proximity check (file not found)"
else
    PRIMARY_LN=$(grep -nF "Which is the primary" "$LOCAL_SKILL_MD" | head -1 | cut -d: -f1)
    if [ -z "$PRIMARY_LN" ]; then
        fail "M6: 'Which is the primary' phrase missing — must be present as confirmation prompt"
    else
        START_LN=$((PRIMARY_LN - 30))
        [ "$START_LN" -lt 1 ] && START_LN=1
        END_LN=$((PRIMARY_LN - 1))
        SLICE=$(awk -v s="$START_LN" -v e="$END_LN" 'NR>=s && NR<=e' "$LOCAL_SKILL_MD")
        if printf '%s' "$SLICE" | grep -qF "<!-- workflow-init: confirmed primary"; then
            pass "M6: '<!-- workflow-init: confirmed primary' appears within 30 lines before 'Which is the primary'"
        else
            fail "M6: '<!-- workflow-init: confirmed primary' missing within 30 lines before 'Which is the primary' (primary_ln=$PRIMARY_LN)"
        fi
    fi
fi

echo ""
echo "--- Issue: clarify-intent Step 1b framing AskUserQuestion removal ---"

# P1: Step 1b must NOT contain 'Approve framing' (AskUserQuestion removed)
assert_absent "$LOCAL_SKILL_MD" "Approve framing" \
    "P1: Step 1b removes 'Approve framing' AskUserQuestion option"

# P2: Step 1b must NOT contain 'Start over' (escape eliminated)
assert_absent "$LOCAL_SKILL_MD" "Start over" \
    "P2: Step 1b removes 'Start over' escape option"

# P3: Step 1b must contain 'auto-skipped' (background question auto-skip wording)
assert_contains "$LOCAL_SKILL_MD" "auto-skipped" \
    "P3: Step 1b contains background-question auto-skip wording"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
