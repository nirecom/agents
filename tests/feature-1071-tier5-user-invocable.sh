#!/bin/bash
# tests/feature-1071-tier5-user-invocable.sh
# Tests: skills/issue-close-migrated/SKILL.md, skills/survey-code/SKILL.md, skills/survey-history/SKILL.md, skills/issue-reconcile/SKILL.md
# Tags: static, skill, user-invocable, frontmatter, scope:issue-specific
#
# Tier 5 static contract test for issue #1071 (skill/agent fork+worker audit).
# Asserts that non-user-facing skills declare 'user-invocable: false', and that
# legitimately user-invocable skills still declare 'user-invocable: true'
# (no false-positive regressions from the audit sweep).
# Expected RED until #1071 adds user-invocable: false to the four target skills.
#
# L3 gap (what this test does NOT catch):
# - whether the Claude Code skill list actually hides non-user-invocable skills
#   at runtime (requires real claude -p session to confirm UI behavior)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="${AGENTS_DIR}/skills"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

frontmatter() {
    awk 'NR==1 && $0=="---"{infm=1; next} infm && $0=="---"{exit} infm{print}' "$1"
}

assert_user_invocable_false() {
    local skill="$1"
    local file="${SKILLS_DIR}/${skill}/SKILL.md"
    if [ ! -f "$file" ]; then
        fail "skills/$skill: SKILL.md missing"
        return
    fi
    if frontmatter "$file" | grep -qE '^user-invocable:[[:space:]]*false[[:space:]]*$'; then
        pass "skills/$skill: user-invocable: false"
    else
        local current
        current=$(frontmatter "$file" | grep 'user-invocable:' | head -1 || echo "(not set)")
        fail "skills/$skill: expected user-invocable: false" "current: $current"
    fi
}

assert_user_invocable_true() {
    local skill="$1"
    local file="${SKILLS_DIR}/${skill}/SKILL.md"
    if [ ! -f "$file" ]; then
        fail "skills/$skill: SKILL.md missing (regression guard — file should not be deleted)"
        return
    fi
    if frontmatter "$file" | grep -qE '^user-invocable:[[:space:]]*true[[:space:]]*$'; then
        pass "skills/$skill: user-invocable: true retained (no regression)"
    else
        local current
        current=$(frontmatter "$file" | grep 'user-invocable:' | head -1 || echo "(not set)")
        fail "skills/$skill: regression — user-invocable: true was removed or changed" "current: $current"
    fi
}

# ── Tests 1–4: skills that MUST be user-invocable: false ─────────────────────
assert_user_invocable_false "issue-close-migrated"
assert_user_invocable_false "survey-code"
assert_user_invocable_false "survey-history"
assert_user_invocable_false "issue-reconcile"

# ── Tests 5–11: regression guard — user-invocable skills must retain true ─────
# These skills were already explicitly user-invocable: true before #1071
assert_user_invocable_true "issue-create"
assert_user_invocable_true "session-close"
assert_user_invocable_true "sweep-branches"
assert_user_invocable_true "sweep-worktrees"
assert_user_invocable_true "sweep-plans"
assert_user_invocable_true "sweep"
assert_user_invocable_true "migrate-repo"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
