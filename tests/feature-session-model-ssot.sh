#!/usr/bin/env bash
# Pre-implementation tests for issue #444 — N-issues-per-session SSOT.
# Tests S1-S8 are pre-implementation assertions — FAIL until source changes land.
set -euo pipefail

# Timeout guard
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GITHUB_ISSUES_MD="$AGENTS_DIR/rules/github-issues.md"
WORKFLOW_INIT_MD="$AGENTS_DIR/skills/workflow-init/SKILL.md"
CLARIFY_INTENT_MD="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
COMMIT_PUSH_MD="$AGENTS_DIR/skills/commit-push/SKILL.md"
ISSUE_CLOSE_STAGE_MD="$AGENTS_DIR/skills/issue-close-stage/SKILL.md"
ISSUE_CLOSE_FINALIZE_MD="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"
ISSUE_CREATE_MD="$HOME/.claude/skills/issue-create/SKILL.md"
OPS_MD="$AGENTS_DIR/docs/ops.md"
AGENTS_CLAUDE_MD="$AGENTS_DIR/CLAUDE.md"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# assert_contains FILE PATTERN DESCRIPTION  (extended regex)
assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then fail "$desc (file not found: $file)"; return 1; fi
    if grep -qE "$pattern" "$file"; then pass "$desc"; else fail "$desc (pattern not found: $pattern in $file)"; fi
}

# assert_absent FILE PATTERN DESCRIPTION  (extended regex)
assert_absent() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then fail "$desc (file not found: $file)"; return 1; fi
    if grep -qE "$pattern" "$file"; then fail "$desc (unexpected pattern '$pattern' present)"; else pass "$desc"; fi
}

echo "=== Issue #444: Session model SSOT tests ==="
echo ""

# ---------------------------------------------------------------------------
# S1: rules/github-issues.md owns the SSOT section.
# ---------------------------------------------------------------------------
echo "--- S1: SSOT section heading ---"
assert_contains "$GITHUB_ISSUES_MD" "^## Session model: N issues per session" \
    "S1: rules/github-issues.md contains '## Session model: N issues per session'"

# ---------------------------------------------------------------------------
# S2: 'primary' and 'related' terms defined.
# ---------------------------------------------------------------------------
echo ""
echo "--- S2: primary / related terms ---"
assert_contains "$GITHUB_ISSUES_MD" "primary" \
    "S2a: rules/github-issues.md defines 'primary' term"
assert_contains "$GITHUB_ISSUES_MD" "related" \
    "S2b: rules/github-issues.md defines 'related' term"

# ---------------------------------------------------------------------------
# S3: relation formula.
# ---------------------------------------------------------------------------
echo ""
echo "--- S3: 1 session = N issues formula ---"
assert_contains "$GITHUB_ISSUES_MD" "1 session = N issues" \
    "S3: rules/github-issues.md contains '1 session = N issues' formula"

# ---------------------------------------------------------------------------
# S4: Downstream files reference the SSOT.
# ---------------------------------------------------------------------------
echo ""
echo "--- S4: downstream SSOT references ---"

check_ssot_ref() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label (file not found: $file)"
        return 1
    fi
    if grep -qE "Session model|rules/github-issues\.md" "$file"; then
        pass "$label"
    else
        fail "$label (neither 'Session model' nor 'rules/github-issues.md' found in $file)"
    fi
}

check_ssot_ref "$ISSUE_CLOSE_STAGE_MD"    "S4a: skills/issue-close-stage/SKILL.md references SSOT"
check_ssot_ref "$ISSUE_CLOSE_FINALIZE_MD" "S4b: skills/issue-close-finalize/SKILL.md references SSOT"

if [ ! -f "$ISSUE_CREATE_MD" ]; then
    echo "NOTE: issue-create SKILL.md not deployed at $ISSUE_CREATE_MD — skipping S4c."
else
    check_ssot_ref "$ISSUE_CREATE_MD" "S4c: \$HOME/.claude/skills/issue-create/SKILL.md references SSOT"
fi

check_ssot_ref "$OPS_MD" "S4d: docs/ops.md references SSOT"

# ---------------------------------------------------------------------------
# S5: Old erroneous phrase removed from CLAUDE.md.
# ---------------------------------------------------------------------------
echo ""
echo "--- S5: CLAUDE.md erroneous phrase removed ---"
assert_absent "$AGENTS_CLAUDE_MD" "commits the docs/history\.md entry on the feature branch" \
    "S5: 'commits the docs/history.md entry on the feature branch' phrase removed from CLAUDE.md"

# ---------------------------------------------------------------------------
# S6: SSOT section must not contain operational verbs (Concern 3 regression).
# ---------------------------------------------------------------------------
echo ""
echo "--- S6: SSOT section operational-word absence ---"
if [ ! -f "$GITHUB_ISSUES_MD" ]; then
    fail "S6: SSOT operational-word absence (file not found: $GITHUB_ISSUES_MD)"
else
    # Extract section from '## Session model' to next '^## '.
    SECTION=$(awk '
        /^## Session model/ { in_sec = 1; print; next }
        in_sec && /^## / { exit }
        in_sec { print }
    ' "$GITHUB_ISSUES_MD")

    if [ -z "$SECTION" ]; then
        fail "S6: '## Session model' section not extractable from $GITHUB_ISSUES_MD"
    else
        check_term_absent() {
            local term="$1" label="$2"
            if printf '%s' "$SECTION" | grep -qF "$term"; then
                fail "$label (unexpected operational term '$term' inside SSOT section)"
            else
                pass "$label"
            fi
        }
        check_term_absent "gh issue edit"            "S6a: SSOT section excludes 'gh issue edit'"
        check_term_absent "wip-state.sh set"         "S6b: SSOT section excludes 'wip-state.sh set'"
        check_term_absent "--add-label"              "S6c: SSOT section excludes '--add-label'"
        check_term_absent "<!-- issue-close-pr-of"   "S6d: SSOT section excludes '<!-- issue-close-pr-of'"
        check_term_absent "commit-push"              "S6e: SSOT section excludes 'commit-push'"
        check_term_absent "issue-close-stage"        "S6f: SSOT section excludes 'issue-close-stage'"
        check_term_absent "issue-close-finalize"     "S6g: SSOT section excludes 'issue-close-finalize'"
    fi
fi

# ---------------------------------------------------------------------------
# S7: workflow-init Path A fail-closed label assignment (Concern 1).
# ---------------------------------------------------------------------------
echo ""
echo "--- S7: workflow-init Path A fail-closed ---"
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "S7: workflow-init Path A fail-closed (file not found)"
elif grep -qF "intent:clarified" "$WORKFLOW_INIT_MD" \
   && grep -qF "ABORT" "$WORKFLOW_INIT_MD"; then
    pass "S7: workflow-init SKILL.md contains both 'intent:clarified' and 'ABORT' (fail-closed Path A)"
else
    fail "S7: workflow-init SKILL.md must contain both 'intent:clarified' and 'ABORT' for fail-closed Path A"
fi

# ---------------------------------------------------------------------------
# S8: workflow-init primary confirmation prompt present.
# ---------------------------------------------------------------------------
echo ""
echo "--- S8: workflow-init primary confirmation window ---"
assert_contains "$WORKFLOW_INIT_MD" "Which is the primary" \
    "S8: workflow-init SKILL.md contains 'Which is the primary' confirmation prompt"

# ============================================================
echo ""
echo "=== Summary ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$ERRORS test(s) failed."
fi
exit "$ERRORS"
