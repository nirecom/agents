#!/usr/bin/env bash
# Tests: bin/github-issues/wip-state.sh, skills/issue-close-finalize/SKILL.md, skills/issue-close-finalize/SKILL.md.
# Tags: issue-close, finalize, workflow, github, issues
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

# K1: ICF-J documented with its own inline entry (replaces old '## Step K' header).
assert_contains "$SKILL_MD" "^ICF-J:" \
    "K1: SKILL.md contains 'ICF-J:' inline entry"

# K2: ICF-J entry references WIP clearing.
assert_contains "$SKILL_MD" "ICF-J.*[Ww][Ii][Pp]|ICF-J.*wip-state" \
    "K2: ICF-J entry references WIP / wip-state"

# K3: Step K invokes wip-state.sh clear <N>.
assert_contains "$SKILL_MD" "wip-state\.sh.*clear" \
    "K3: Step K invokes wip-state.sh clear <N>"

# K4: Step K explicitly invokes via $AGENTS_CONFIG_DIR path (matches workflow rules).
assert_contains "$SKILL_MD" "AGENTS_CONFIG_DIR.*wip-state\.sh|wip-state\.sh.*AGENTS_CONFIG_DIR" \
    "K4: Step K invokes wip-state.sh via \$AGENTS_CONFIG_DIR"

# K5: ICF-J appears AFTER ICF-I (ordering — both as inline 'ICF-N:' entries).
if [ ! -f "$SKILL_MD" ]; then
    fail "K5: ordering check (file not found)"
else
    I_LN=$(grep -n "^ICF-I:" "$SKILL_MD" | head -1 | cut -d: -f1)
    J_LN=$(grep -n "^ICF-J:" "$SKILL_MD" | head -1 | cut -d: -f1)
    if [ -n "$I_LN" ] && [ -n "$J_LN" ] && [ "$J_LN" -gt "$I_LN" ]; then
        pass "K5: ICF-J appears after ICF-I (i_ln=$I_LN j_ln=$J_LN)"
    else
        fail "K5: ICF-J must follow ICF-I (i_ln=$I_LN j_ln=$J_LN)"
    fi
fi

# K6: warn-and-continue policy documented (gh failures are non-fatal).
assert_contains "$SKILL_MD" "warn.and.continue|warn-and-continue|non.fatal|recoverable|idempotent" \
    "K6: Step K documents warn-and-continue / idempotent / recoverable policy"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
