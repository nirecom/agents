#!/usr/bin/env bash
# tests/feature-1396-labels-severity-model.sh
# Tests: .github/labels.yml, skills/issue-create/SKILL.md
# Tags: scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Actual GitHub API label creation via sync-labels.sh (needs real token + network)
# - Claude runtime model detection behavior (LLM prompt-level, not testable in shell)
# - sync-labels.sh --force live idempotency against GitHub API
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LABELS_YML="$REPO_ROOT/.github/labels.yml"
SKILL_MD="$REPO_ROOT/skills/issue-create/SKILL.md"

PASS=0; FAIL=0

assert_contains_label() {
    local name="$1" label_name="$2"
    if grep -qF "\"$label_name\"" "$LABELS_YML" 2>/dev/null; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — label '$label_name' not found in labels.yml"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains_color() {
    local name="$1" color="$2"
    if grep -qF "$color" "$LABELS_YML" 2>/dev/null; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — color '$color' not found in labels.yml"
        FAIL=$((FAIL + 1))
    fi
}

assert_skill_contains() {
    local name="$1" pattern="$2"
    if grep -qF -- "$pattern" "$SKILL_MD" 2>/dev/null; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — pattern not found in SKILL.md: $pattern"
        FAIL=$((FAIL + 1))
    fi
}

assert_skill_not_contains() {
    local name="$1" pattern="$2"
    if grep -qF -- "$pattern" "$SKILL_MD" 2>/dev/null; then
        echo "FAIL: $name — pattern unexpectedly present in SKILL.md: $pattern"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $name"
        PASS=$((PASS + 1))
    fi
}

echo "=== labels.yml checks ==="

assert_contains_label "T-labels-severity-high" "severity:high"
assert_contains_color "T-labels-severity-high-color" "b60205"
assert_contains_label "T-labels-severity-low" "severity:low"
# reporter-model:* labels (formerly model:*) — mapping covered by fix-1579-reporter-model-keyword-scan.sh

# ラベル件数チェック（既存6件 + 新規7件 = 13件以上）
COUNT=$(grep -c '^- name:' "$LABELS_YML" 2>/dev/null || echo "0")
if [ "$COUNT" -ge 13 ]; then
    echo "PASS: T-labels-yaml-count (count=$COUNT)"
    PASS=$((PASS + 1))
else
    echo "FAIL: T-labels-yaml-count — want >=13, got $COUNT"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== skills/issue-create/SKILL.md checks ==="

assert_skill_contains "T-skill-severity-directive" "severity:high"
assert_skill_contains "T-skill-severity-low"       "severity:low"
assert_skill_contains "T-skill-severity-normal"    "no label"
assert_skill_contains "T-skill-model-directive"    "You are powered by the model"
assert_skill_contains "T-skill-reporter-model-flag" "--reporter-model"
assert_skill_not_contains "T-skill-model-others-removed" "model:others"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
