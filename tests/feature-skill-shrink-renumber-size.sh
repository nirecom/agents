#!/bin/bash
# Tests: skills/workflow-init/SKILL.md, skills/make-detail-plan/SKILL.md, skills/worktree-end/SKILL.md, skills/issue-close-finalize/SKILL.md, skills/make-detail-plan/scripts/research-reprompt.sh, skills/make-detail-plan/scripts/cap-escalation-message.sh, skills/make-detail-plan/scripts/skip-conditions.sh, skills/make-detail-plan/scripts/surface-delivery-plan.sh, skills/workflow-init/scripts/aggregate-wip-check.sh, skills/workflow-init/scripts/closed-detection.sh
# Tags: skill-shrink, size-limit, scripts-extraction, issue-613
# Verifies SKILL.md files are within 100-line limit and extracted scripts exist.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check_size() {
    local label="$1"
    local rel="$2"
    local path="$AGENTS_DIR/$rel"
    if [ ! -f "$path" ]; then
        fail "$label: file missing ($rel)"
        return
    fi
    local count
    count=$(wc -l < "$path")
    if [ "$count" -le 100 ]; then
        pass "$label: $rel <= 100 lines (got $count)"
    else
        fail "$label: $rel must be <= 100 lines (got $count)"
    fi
}

check_exists() {
    local label="$1"
    local rel="$2"
    if [ -f "$AGENTS_DIR/$rel" ]; then
        pass "$label: $rel exists"
    else
        fail "$label: $rel missing"
    fi
}

check_size "S1" "skills/workflow-init/SKILL.md"
check_size "S2" "skills/make-detail-plan/SKILL.md"
check_size "S3" "skills/worktree-end/SKILL.md"
check_size "S4" "skills/issue-close-finalize/SKILL.md"

check_exists "S5" "skills/make-detail-plan/scripts/research-reprompt.sh"
check_exists "S6" "skills/make-detail-plan/scripts/cap-escalation-message.sh"
check_exists "S7" "skills/make-detail-plan/scripts/skip-conditions.sh"
check_exists "S8" "skills/make-detail-plan/scripts/surface-delivery-plan.sh"
check_exists "S9" "skills/workflow-init/scripts/aggregate-wip-check.sh"
check_exists "S10" "skills/workflow-init/scripts/closed-detection.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
