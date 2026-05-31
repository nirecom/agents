#!/usr/bin/env bash
# Tests: agents/detail-planner.md, agents/outline-planner.md, agents/survey-code.md, agents/survey-history.md, skills/_shared/survey-artifact-valid.md, skills/clarify-intent/SKILL.md, skills/survey-code/SKILL.md, skills/workflow-init/SKILL.md
# Tags: workflow, init, routing, clarify-intent, planning
# Test suite for issue #497 — survey artifact write failure & post-check verifies existence only.
# Static doc checks for the shared validity contract and consumer references.
# Tests will FAIL until the source changes are implemented — that is expected.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SHARED_VALID="$REPO_ROOT/skills/_shared/survey-artifact-valid.md"
WI_SKILL="$REPO_ROOT/skills/workflow-init/SKILL.md"
CI_SKILL="$REPO_ROOT/skills/clarify-intent/SKILL.md"
SC_SKILL="$REPO_ROOT/skills/survey-code/SKILL.md"
SC_AGENT="$REPO_ROOT/agents/survey-code.md"
SH_AGENT="$REPO_ROOT/agents/survey-history.md"
DP_AGENT="$REPO_ROOT/agents/detail-planner.md"
OP_AGENT="$REPO_ROOT/agents/outline-planner.md"
ERRORS=0
PASS_COUNT=0

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"; else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }

assert_file_exists() {
    local id="$1" desc="$2" file="$3"
    [ -f "$file" ] && pass "${id}. ${desc}" || fail "${id}. ${desc} — file missing: $file"
}
assert_file_contains() {
    local id="$1" desc="$2" file="$3" needle="$4"
    [ -f "$file" ] || { fail "${id}. ${desc} — file missing: $file"; return; }
    run_with_timeout grep -qF -- "$needle" "$file" && pass "${id}. ${desc}" || fail "${id}. ${desc} — not found: '${needle}'"
}
assert_file_not_contains() {
    local id="$1" desc="$2" file="$3" needle="$4"
    [ -f "$file" ] || { fail "${id}. ${desc} — file missing: $file"; return; }
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        fail "${id}. ${desc} — unexpected: '${needle}'"
    else
        pass "${id}. ${desc}"
    fi
}
assert_tools_has_write() {
    local id="$1" desc="$2" file="$3"
    [ -f "$file" ] || { fail "${id}. ${desc} — file missing: $file"; return; }
    local line
    line=$(grep -m1 '^tools:' "$file" || true)
    if [ -z "$line" ]; then
        fail "${id}. ${desc} — no tools: line in front-matter"
        return
    fi
    if printf '%s' "$line" | grep -qF "Write," || printf '%s' "$line" | grep -qF ", Write"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — Write not in tools: front-matter"
    fi
}

# ===========================================================================
# Section 1 — Shared validity contract (`skills/_shared/survey-artifact-valid.md`)
# ===========================================================================
echo "=== Section 1: skills/_shared/survey-artifact-valid.md ==="

assert_file_exists   "SV-1"  "Shared validity contract file exists"                   "$SHARED_VALID"
assert_file_contains "SV-2"  "Contract defines Verified Claims as required content"   "$SHARED_VALID" "## Verified Claims"
assert_file_contains "SV-3"  "Contract provides reference Bash check function"        "$SHARED_VALID" "artifact_valid"
assert_file_contains "SV-4"  "Contract uses grep -qF for substring check"            "$SHARED_VALID" "grep -qF"
assert_file_contains "SV-5"  "Contract documents WORKFLOW_SURVEY_AGENT_FAILED"       "$SHARED_VALID" "WORKFLOW_SURVEY_AGENT_FAILED"
assert_file_contains "SV-6"  "Contract names workflow-init Step 6.5 as consumer"     "$SHARED_VALID" "workflow-init"
assert_file_contains "SV-7"  "Contract names clarify-intent as consumer"             "$SHARED_VALID" "clarify-intent"
assert_file_contains "SV-8"  "Contract states substring match is intentional"        "$SHARED_VALID" "intentional"

# ===========================================================================
# Section 2 — Consumer references (one-line pointers, no duplication)
# ===========================================================================
echo "=== Section 2: Consumer one-line pointer references ==="

# workflow-init Step 6.5 must reference the contract
assert_file_contains     "CR-1" "WI Step 6.5 references shared validity contract" \
    "$WI_SKILL" "skills/_shared/survey-artifact-valid.md"
# workflow-init must NOT duplicate the Bash function body
assert_file_not_contains "CR-2" "WI does NOT inline grep-qF check" \
    "$WI_SKILL" 'grep -qF "## Verified Claims"'
# workflow-init old existence-only wording must be gone
assert_file_not_contains "CR-3" "WI old existence-only text removed" \
    "$WI_SKILL" "verify each artifact exists at its absolute path"

# clarify-intent must reference the contract at least twice (Step 6 + Completion 3)
if [ -f "$CI_SKILL" ]; then
    count=$(grep -cF "skills/_shared/survey-artifact-valid.md" "$CI_SKILL" || true)
    if [ "${count:-0}" -ge 2 ]; then
        pass "CR-4. CI references shared contract in both Step 6 and Completion 3 (count=$count)"
    else
        fail "CR-4. CI references shared contract in both Step 6 and Completion 3 — found ${count:-0}, expected >=2"
    fi
else
    fail "CR-4. CI references shared contract — file missing: $CI_SKILL"
fi
# clarify-intent must NOT duplicate the Bash function body
assert_file_not_contains "CR-5" "CI does NOT inline grep-qF check" \
    "$CI_SKILL" 'grep -qF "## Verified Claims"'
# Old existence-only phrases removed from CI
assert_file_not_contains "CR-6" "CI no longer uses 'Both present' existence-only phrase" \
    "$CI_SKILL" "Both present"

# ===========================================================================
# Section 3 — Bug B: survey-code SKILL.md Rules fix
# ===========================================================================
echo "=== Section 3: skills/survey-code/SKILL.md Rules fix (Bug B) ==="

assert_file_not_contains "BUG-B-1" "SC SKILL.md no longer says 'Read-only — do not modify any files'" \
    "$SC_SKILL" "Read-only — do not modify any files"
assert_file_contains     "BUG-B-2" "SC SKILL.md references shared validity contract" \
    "$SC_SKILL" "skills/_shared/survey-artifact-valid.md"

# ===========================================================================
# Section 4 — Bug A: agent write rationale
# ===========================================================================
echo "=== Section 4: Agent file write rationale (Bug A) ==="

assert_file_contains "BUG-A-1" "SC agent declares write REQUIRED"               "$SC_AGENT" "REQUIRED"
assert_file_contains "BUG-A-2" "SC agent explains outside-git-repo rationale"   "$SC_AGENT" "outside any git repository"
assert_file_contains "BUG-A-3" "SH agent declares write REQUIRED"               "$SH_AGENT" "REQUIRED"
assert_file_contains "BUG-A-4" "SH agent explains outside-git-repo rationale"   "$SH_AGENT" "outside any git repository"

# ===========================================================================
# Section 5 — Plan-pipeline subagents grant Write tool (issue #516)
# ===========================================================================
echo "=== Section 5: Plan-pipeline subagent tools: front-matter (#516) ==="

assert_tools_has_write "TW-1" "survey-code agent grants Write tool"     "$SC_AGENT"
assert_tools_has_write "TW-2" "survey-history agent grants Write tool"  "$SH_AGENT"
assert_tools_has_write "TW-3" "detail-planner agent grants Write tool"  "$DP_AGENT"
assert_tools_has_write "TW-4" "outline-planner agent grants Write tool" "$OP_AGENT"

# ===========================================================================
# Section 6 — Planner agents document PLANS_DIR Write permission (#516)
# ===========================================================================
echo "=== Section 6: Planner agents PLANS_DIR Write rationale (#516) ==="

assert_file_contains     "PW-1" "detail-planner permits Write for PLANS_DIR artifacts"         "$DP_AGENT" "PLANS_DIR"
assert_file_contains     "PW-2" "outline-planner permits Write for PLANS_DIR artifacts"        "$OP_AGENT" "PLANS_DIR"
assert_file_not_contains "PW-3" "detail-planner old blanket Edit/Write prohibition removed"    "$DP_AGENT" "Do not write code or call Edit/Write"
assert_file_not_contains "PW-4" "outline-planner old blanket Edit/Write prohibition removed"   "$OP_AGENT" "Do not write code or call Edit/Write"

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "==========================================================="
TOTAL=$((PASS_COUNT + ERRORS))
if [ "$ERRORS" -eq 0 ]; then
    echo "All ${TOTAL} tests passed"
else
    echo "${ERRORS} test(s) failed out of ${TOTAL}"
fi
echo "==========================================================="
exit "$ERRORS"
