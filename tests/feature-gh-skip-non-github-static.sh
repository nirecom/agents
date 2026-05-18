#!/bin/bash
# Static grep-based checks for the non-GitHub-remote gate wiring across 5 SKILL.md files.
#
# Pre-implementation: all checks expected to FAIL until SKILL.md gates land.
# Post-implementation: all checks should PASS.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

WORKFLOW_INIT_SKILL="$REPO_ROOT/skills/workflow-init/SKILL.md"
CLARIFY_SKILL="$REPO_ROOT/skills/clarify-intent/SKILL.md"
COMMIT_PUSH_SKILL="$REPO_ROOT/skills/commit-push/SKILL.md"
ISSUE_CLOSE_STAGE_SKILL="$REPO_ROOT/skills/issue-close-stage/SKILL.md"
ISSUE_CLOSE_FINALIZE_SKILL="$REPO_ROOT/skills/issue-close-finalize/SKILL.md"

ALL_SKILLS=(
    "$WORKFLOW_INIT_SKILL"
    "$CLARIFY_SKILL"
    "$COMMIT_PUSH_SKILL"
    "$ISSUE_CLOSE_STAGE_SKILL"
    "$ISSUE_CLOSE_FINALIZE_SKILL"
)

# ---------------------------------------------------------------------------
# Group 1: is-github-dotcom-remote helper invocation present in each SKILL.md
# ---------------------------------------------------------------------------
echo "=== Group 1: is-github-dotcom-remote invocation ==="
for f in "${ALL_SKILLS[@]}"; do
    if require_file "$f"; then
        name="$(basename "$(dirname "$f")")"
        if has_fixed "is-github-dotcom-remote" "$f"; then
            pass "is-github-dotcom-remote referenced in $name/SKILL.md"
        else
            fail "is-github-dotcom-remote missing from $f"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Group 2: NON_GITHUB=0 reset present in each SKILL.md
# ---------------------------------------------------------------------------
echo "=== Group 2: NON_GITHUB=0 reset ==="
for f in "${ALL_SKILLS[@]}"; do
    if require_file "$f"; then
        name="$(basename "$(dirname "$f")")"
        if has_fixed "NON_GITHUB=0" "$f"; then
            pass "NON_GITHUB=0 reset present in $name/SKILL.md"
        else
            fail "NON_GITHUB=0 reset missing from $f"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Group 3: skip message present in each SKILL.md
# ---------------------------------------------------------------------------
echo "=== Group 3: GITHUB_ISSUES disabled skip message ==="
for f in "${ALL_SKILLS[@]}"; do
    if require_file "$f"; then
        name="$(basename "$(dirname "$f")")"
        if has_fixed "GITHUB_ISSUES disabled" "$f"; then
            pass "GITHUB_ISSUES disabled message present in $name/SKILL.md"
        else
            fail "GITHUB_ISSUES disabled message missing from $f"
        fi
    fi
done

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All static checks passed."
    exit 0
else
    echo "$ERRORS check(s) failed."
    exit 1
fi
