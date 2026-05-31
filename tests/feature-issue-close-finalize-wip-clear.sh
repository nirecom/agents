#!/usr/bin/env bash
# Tests: bin/github-issues/wip-state.sh, skills/issue-close-finalize/SKILL.md, skills/issue-close-finalize/SKILL.md.
# Tags: issue-close-finalize-wip-clear
# Static-text contract tests for issue #362 Step K in
# skills/issue-close-finalize/SKILL.md.
#
# Step K calls `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" clear <N>`
# to set Projects v2 Status=Done, clear the session-fingerprint text field, and
# delete the local $PLANS_DIR/wip-lock-<N>.md registry artifact. Step K is the
# last step in the finalize chain (runs after Step J).
#
# RED: fails until issue-close-finalize/SKILL.md gains the Step K section.

# Timeout guard
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi
    if grep -qE "$pattern" "$file"; then
        pass "$desc"
    else
        fail "$desc (pattern not found: $pattern)"
    fi
}

echo "=== issue-close-finalize Step K (WIP clear) contract tests ==="

# K1: Step K section header exists.
assert_contains "$SKILL_MD" "^## Step K" \
    "K1: SKILL.md contains '## Step K' section header"

# K2: Step K title indicates WIP clearing intent.
assert_contains "$SKILL_MD" "Step K.*[Ww][Ii][Pp]|WIP state|clear WIP" \
    "K2: Step K title references WIP / clear WIP state"

# K3: Step K invokes wip-state.sh clear <N>.
assert_contains "$SKILL_MD" "wip-state\.sh.*clear" \
    "K3: Step K invokes wip-state.sh clear <N>"

# K4: Step K explicitly invokes via $AGENTS_CONFIG_DIR path (matches workflow rules).
assert_contains "$SKILL_MD" "AGENTS_CONFIG_DIR.*wip-state\.sh|wip-state\.sh.*AGENTS_CONFIG_DIR" \
    "K4: Step K invokes wip-state.sh via \$AGENTS_CONFIG_DIR"

# K5: Step K appears AFTER Step J (ordering).
if [ ! -f "$SKILL_MD" ]; then
    fail "K5: ordering check (file not found)"
else
    J_LN=$(grep -n "^## Step J" "$SKILL_MD" | head -1 | cut -d: -f1)
    K_LN=$(grep -n "^## Step K" "$SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$J_LN" ] && [ -n "$K_LN" ] && [ "$K_LN" -gt "$J_LN" ]; then
        pass "K5: Step K appears after Step J (j_ln=$J_LN k_ln=$K_LN)"
    else
        fail "K5: Step K must follow Step J (j_ln=$J_LN k_ln=$K_LN)"
    fi
fi

# K6: warn-and-continue policy documented (gh failures are non-fatal).
assert_contains "$SKILL_MD" "warn.and.continue|warn-and-continue|non.fatal|recoverable|idempotent" \
    "K6: Step K documents warn-and-continue / idempotent / recoverable policy"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
