#!/bin/bash
# tests/skills/feature-1071-tier1-context-fork.sh
# Tests: skills/sweep-branches/SKILL.md, skills/sweep-worktrees/SKILL.md, skills/sweep-plans/SKILL.md
# Tags: static, skill, fork, sweep, context-fork, scope:issue-specific
# Tier 1 static contract (#1071): sweep-branches/sweep-worktrees declare `context: fork`;
# sweep-plans does not (its approval gate needs the parent conversation). All three
# keep `user-invocable` and their skill body.
# L3 gap: runtime fork dispatch needs a real claude -p session; checked at the
# WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh skill-orchestration).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB_MD="${SCRIPT_CHECKOUT_ROOT}/skills/sweep-branches/SKILL.md"
SW_MD="${SCRIPT_CHECKOUT_ROOT}/skills/sweep-worktrees/SKILL.md"
SP_MD="${SCRIPT_CHECKOUT_ROOT}/skills/sweep-plans/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

# Extract the YAML frontmatter (between the first two '---' lines)
frontmatter() {
    awk 'NR==1 && $0=="---"{infm=1; next} infm && $0=="---"{exit} infm{print}' "$1"
}

assert_context_fork() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label: $(basename "$(dirname "$file")")/SKILL.md missing"
        return
    fi
    if frontmatter "$file" | grep -qE '^context:[[:space:]]*fork[[:space:]]*$'; then
        pass "$label: frontmatter declares 'context: fork'"
    else
        fail "$label: frontmatter missing 'context: fork'"
    fi
}

# The inverse: sweep-plans must NOT fork (AskUserQuestion gate).
assert_no_context_fork() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label: $(basename "$(dirname "$file")")/SKILL.md missing"
        return
    fi
    if frontmatter "$file" | grep -qE '^context:[[:space:]]*fork[[:space:]]*$'; then
        fail "$label: frontmatter still declares 'context: fork'"
    else
        pass "$label: frontmatter declares no 'context: fork'"
    fi
}

assert_user_invocable_present() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label: file missing — skip"
        return
    fi
    if frontmatter "$file" | grep -qE '^user-invocable:'; then
        pass "$label: 'user-invocable' still present in frontmatter (not accidentally removed)"
    else
        fail "$label: 'user-invocable' was removed from frontmatter (regression)"
    fi
}

assert_body_not_stripped() {
    local file="$1" label="$2" marker="$3"
    if [ ! -f "$file" ]; then
        fail "$label: file missing — skip"
        return
    fi
    if grep -qF "$marker" "$file"; then
        pass "$label: skill body retained (found marker)"
    else
        fail "$label: skill body content appears stripped (missing: '$marker')"
    fi
}

# ── Tests 1–3: context: fork on branches/worktrees; none on sweep-plans ───────
assert_context_fork "$SB_MD" "1: sweep-branches context:fork"
assert_context_fork "$SW_MD" "2: sweep-worktrees context:fork"
assert_no_context_fork "$SP_MD" "3: sweep-plans no context:fork (approval gate needs the parent conversation)"

# ── Tests 4–6: user-invocable still present (regression guard) ────────────────
assert_user_invocable_present "$SB_MD" "4: sweep-branches user-invocable retained"
assert_user_invocable_present "$SW_MD" "5: sweep-worktrees user-invocable retained"
assert_user_invocable_present "$SP_MD" "6: sweep-plans user-invocable retained"

# ── Tests 7–9: body content not accidentally stripped ─────────────────────────
assert_body_not_stripped "$SB_MD" "7: sweep-branches body intact" "## Procedure"
assert_body_not_stripped "$SW_MD" "8: sweep-worktrees body intact" "## Procedure"
assert_body_not_stripped "$SP_MD" "9: sweep-plans body intact" "bin/sweep-plans.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
