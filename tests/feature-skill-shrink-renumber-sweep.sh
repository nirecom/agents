#!/bin/bash
# Tests: bin/verify-renumber-sweep.sh, skills/workflow-init/SKILL.md, skills/worktree-end/SKILL.md, skills/issue-close-finalize/SKILL.md, skills/make-detail-plan/SKILL.md, agents/issue-close-finalize-worker.md
# Tags: renumber, step-rename, sweep, issue-614
# Verifies renumber sweep tool exists and new step labels appear in SKILL.md files.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# R1: bin/verify-renumber-sweep.sh exists
SWEEP_SCRIPT="$AGENTS_DIR/bin/verify-renumber-sweep.sh"
if [ -f "$SWEEP_SCRIPT" ]; then
    pass "R1: bin/verify-renumber-sweep.sh exists"
else
    fail "R1: bin/verify-renumber-sweep.sh missing"
fi

# R2: bin/verify-renumber-sweep.sh exits 0 when run from repo root
if [ -f "$SWEEP_SCRIPT" ]; then
    if ( cd "$AGENTS_DIR" && bash bin/verify-renumber-sweep.sh ) >/dev/null 2>&1; then
        pass "R2: bin/verify-renumber-sweep.sh exits 0 (legacy patterns absent)"
    else
        fail "R2: bin/verify-renumber-sweep.sh exited non-zero (legacy patterns still present)"
    fi
else
    fail "R2: bin/verify-renumber-sweep.sh not runnable (missing)"
fi

# Helper for literal grep check
check_literal() {
    local label="$1"
    local literal="$2"
    local rel="$3"
    local path="$AGENTS_DIR/$rel"
    if [ ! -f "$path" ]; then
        fail "$label: $rel missing"
        return
    fi
    if grep -qF "$literal" "$path"; then
        pass "$label: '$literal' appears in $rel"
    else
        fail "$label: '$literal' not found in $rel"
    fi
}

# R3: "WI-11" in workflow-init/SKILL.md
check_literal "R3" "WI-11" "skills/workflow-init/SKILL.md"

# R4: "WE-20" in worktree-end/scripts/cleanup-cascade.sh (canonical spec for WE-14..WE-21)
check_literal "R4" "WE-20" "skills/worktree-end/scripts/cleanup-cascade.sh"

# R5: "ICF-A" in issue-close-finalize/SKILL.md
check_literal "R5" "ICF-A" "skills/issue-close-finalize/SKILL.md"

# R6: "MDP-5" in make-detail-plan/SKILL.md
check_literal "R6" "MDP-5" "skills/make-detail-plan/SKILL.md"

# R7: "written_by_step_6h" literal preserved in agents/issue-close-finalize-worker.md
check_literal "R7" "written_by_step_6h" "agents/issue-close-finalize-worker.md"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
