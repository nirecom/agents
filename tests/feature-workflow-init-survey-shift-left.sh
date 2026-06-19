#!/usr/bin/env bash
# Tests: agents/survey-code.md, agents/survey-history.md, skills/_shared/survey-artifact-valid.md, skills/clarify-intent/SKILL.md, skills/survey-code/SKILL.md, skills/survey-history/SKILL.md, skills/workflow-init/SKILL.md
# Tags: workflow, init, routing, clarify-intent, planning, scope:issue-specific
# Test suite for "shift survey-code/survey-history left into workflow-init" (Issue #327).
#
# PRE-IMPLEMENTATION: This test file is written BEFORE source code changes land.
# It is EXPECTED to FAIL until the SKILL.md / agent updates are implemented.
# All checks are static document grep checks — no process spawning, no network.
#
# Files under test:
#   - skills/workflow-init/SKILL.md       (gains context.md writing + parallel surveys)
#   - skills/survey-code/SKILL.md         (input precedence: intent.md preferred, context.md fallback)
#   - skills/survey-history/SKILL.md      (input precedence + keyword-only DEGRADED MODE)
#   - skills/clarify-intent/SKILL.md      (consumes survey artifacts; emits NOT_NEEDED sentinel)
#   - agents/survey-history.md            (agent file aligned with new SKILL inputs)
#   - agents/survey-code.md               (new agent file)
#
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
WI_SKILL="$REPO_ROOT/skills/workflow-init/SKILL.md"
SC_SKILL="$REPO_ROOT/skills/survey-code/SKILL.md"
SH_SKILL="$REPO_ROOT/skills/survey-history/SKILL.md"
CI_SKILL="$REPO_ROOT/skills/clarify-intent/SKILL.md"
SH_AGENT="$REPO_ROOT/agents/survey-history.md"
SC_AGENT="$REPO_ROOT/agents/survey-code.md"

ERRORS=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS does not have `timeout`)
# ---------------------------------------------------------------------------
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
assert_file_exists() {
    local id="$1" desc="$2" file="$3"
    if [ -f "$file" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — file missing: $file"
    fi
}

assert_file_contains() {
    local id="$1" desc="$2" file="$3" needle="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — not found: '${needle}'"
    fi
}

assert_file_not_contains() {
    local id="$1" desc="$2" file="$3" needle="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        fail "${id}. ${desc} — unexpected presence of: '${needle}'"
    else
        pass "${id}. ${desc}"
    fi
}

assert_regex() {
    local id="$1" desc="$2" file="$3" pattern="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qE -- "$pattern" "$file"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — regex not found: '${pattern}'"
    fi
}

# ===========================================================================
# Group A — workflow-init/SKILL.md changes
# ===========================================================================
echo "--- Group A: workflow-init/SKILL.md ---"
assert_file_contains "A1" "WI mentions context.md artifact"                 "$WI_SKILL" "context.md"
assert_file_contains "A2" "WI defines ## Session metadata section"          "$WI_SKILL" "## Session metadata"
assert_file_contains "A3" "WI defines ## Keywords section"                  "$WI_SKILL" "## Keywords"
assert_file_contains "A4" "WI handles sentinel stripping"                   "$WI_SKILL" "sentinel"
assert_file_contains "A5a" "WI launches Agent subagent"                     "$WI_SKILL" "Agent"
assert_file_contains "A5b" "WI references survey-code subagent"             "$WI_SKILL" "survey-code"
assert_file_contains "A6" "WI emits WORKFLOW_SURVEY_AGENT_FAILED sentinel"  "$WI_SKILL" "WORKFLOW_SURVEY_AGENT_FAILED"
assert_file_contains "A7" "WI subagent guard against make-outline-plan"     "$WI_SKILL" "Do NOT invoke make-outline-plan"
assert_file_contains "A8a" "WI retains Path A"                              "$WI_SKILL" "Path A"
assert_file_contains "A8b" "WI retains Path B"                              "$WI_SKILL" "Path B"
assert_file_contains "A8c" "WI retains Path C"                              "$WI_SKILL" "Path C"

# ===========================================================================
# Group B — survey-code/SKILL.md input precedence
# ===========================================================================
echo "--- Group B: survey-code/SKILL.md ---"
assert_file_contains "B1" "SC accepts context.md as fallback input"         "$SC_SKILL" "context.md"
assert_file_contains "B2" "SC still treats intent.md as primary input"      "$SC_SKILL" "intent.md"
assert_regex          "B3" "SC flags intent.md as preferred"                "$SC_SKILL" "intent\\.md.*preferred|preferred.*intent\\.md"
# B4: any of three acceptable phrasings
if [ ! -f "$SC_SKILL" ]; then
    fail "B4. SC documents empty-claim fallback — file missing: $SC_SKILL"
elif run_with_timeout grep -qF -- "empty claim list" "$SC_SKILL" \
  || run_with_timeout grep -qF -- "empty claim" "$SC_SKILL" \
  || run_with_timeout grep -qF -- "proceed with an empty claim" "$SC_SKILL"; then
    pass "B4. SC documents empty-claim fallback"
else
    fail "B4. SC documents empty-claim fallback — none of {'empty claim list','empty claim','proceed with an empty claim'} found"
fi
assert_file_contains "B5" "SC subagent guard against make-outline-plan"     "$SC_SKILL" "Do NOT invoke make-outline-plan"

# ===========================================================================
# Group C — survey-history/SKILL.md keyword-only mode + input precedence
# ===========================================================================
echo "--- Group C: survey-history/SKILL.md & agents/survey-history.md ---"
assert_file_contains "C1" "SH accepts context.md as fallback input"         "$SH_SKILL" "context.md"
assert_regex          "C2" "SH defines keyword-only mode"                   "$SH_SKILL" "[Kk]eyword-only"
assert_file_contains "C3" "SH output includes DEGRADED MODE header"         "$SH_SKILL" "DEGRADED MODE"
assert_file_contains "C4" "SH keyword-only verdicts are indeterminate"      "$SH_SKILL" "indeterminate"
assert_file_contains "C5" "SH caps git log scope with --since="             "$SH_SKILL" "--since="
assert_file_contains "C6" "SH uses '1 year ago' as scope value"             "$SH_SKILL" "1 year ago"
assert_file_contains "C7" "SH mentions gh pr list"                          "$SH_SKILL" "gh pr list"
assert_file_contains "C8" "SH subagent guard against make-outline-plan"     "$SH_SKILL" "Do NOT invoke make-outline-plan"
assert_file_contains "C9" "SH agent file references context.md"             "$SH_AGENT" "context.md"
assert_file_contains "C10" "SH agent file carries make-outline-plan guard"  "$SH_AGENT" "Do NOT invoke make-outline-plan"

# ===========================================================================
# Group D — clarify-intent/SKILL.md fallback
# ===========================================================================
echo "--- Group D: clarify-intent/SKILL.md ---"
assert_file_contains "D1" "CI references survey-code artifact check"        "$CI_SKILL" "survey-code"
assert_file_contains "D2" "CI emits WORKFLOW_RESEARCH_NOT_NEEDED sentinel"  "$CI_SKILL" "WORKFLOW_RESEARCH_NOT_NEEDED"
assert_file_contains "D3" "CI includes specific sentinel reason text"       "$CI_SKILL" "surveys already complete via workflow-init"
# D4: any of two acceptable phrasings
if [ ! -f "$CI_SKILL" ]; then
    fail "D4. CI uses artifact existence check language — file missing: $CI_SKILL"
elif run_with_timeout grep -qF -- "test -f" "$CI_SKILL" \
  || run_with_timeout grep -qF -- "artifact" "$CI_SKILL"; then
    pass "D4. CI uses artifact existence check language"
else
    fail "D4. CI uses artifact existence check language — none of {'test -f','artifact'} found"
fi
assert_file_not_contains "D5" "CI old step 6 'Research (/survey-code' removed"        "$CI_SKILL" "Research (/survey-code"
assert_file_not_contains "D6" "CI old completion-step 'Invoke survey-code...' removed" "$CI_SKILL" "Invoke \`survey-code\` or \`deep-research\`"

# ===========================================================================
# Group E — agents/survey-code.md (new file)
# ===========================================================================
echo "--- Group E: agents/survey-code.md ---"
assert_file_exists   "E1" "SC agent file exists"                            "$SC_AGENT"
# E2: at least one of the two acceptable input mentions
if [ ! -f "$SC_AGENT" ]; then
    fail "E2. SC agent describes valid inputs — file missing: $SC_AGENT"
elif run_with_timeout grep -qF -- "context.md" "$SC_AGENT" \
  || run_with_timeout grep -qF -- "intent.md" "$SC_AGENT"; then
    pass "E2. SC agent describes valid inputs"
else
    fail "E2. SC agent describes valid inputs — neither 'context.md' nor 'intent.md' found"
fi
assert_file_contains "E3" "SC agent delegates to survey-code/SKILL.md"      "$SC_AGENT" "survey-code/SKILL.md"

# ===========================================================================
# Group F — Bug B/C/D fixes (issue #497): SSOT shared validity contract
# ===========================================================================
echo "--- Group F: shared validity contract + one-line pointer references ---"

SHARED_VALID="$REPO_ROOT/skills/_shared/survey-artifact-valid.md"

# F1-F3: shared contract is the SSOT
assert_file_exists       "F1" "Shared validity contract exists"                       "$SHARED_VALID"
assert_file_contains     "F2" "Shared contract defines Verified Claims requirement"   "$SHARED_VALID" "## Verified Claims"
assert_file_contains     "F3" "Shared contract gives reference Bash check"            "$SHARED_VALID" "artifact_valid"

# F4-F5: Bug B — survey-code SKILL.md Rules section
assert_file_not_contains "F4" "SC SKILL.md no longer contains absolute Read-only line" \
    "$SC_SKILL" "Read-only — do not modify any files"
assert_file_contains     "F5" "SC SKILL.md references shared validity contract" \
    "$SC_SKILL" "skills/_shared/survey-artifact-valid.md"

# F6-F10: Bug C — workflow-init Step WI-12
assert_file_contains     "F6" "WI Step WI-12 references shared validity contract" \
    "$WI_SKILL" "skills/_shared/survey-artifact-valid.md"
assert_file_not_contains "F7" "WI Step WI-12 no longer uses existence-only wording" \
    "$WI_SKILL" "verify each artifact exists at its absolute path"
assert_file_not_contains "F8" "WI Step WI-12 does NOT inline artifact_valid() function body" \
    "$WI_SKILL" 'grep -qF "## Verified Claims"'
assert_file_contains     "F9"  "WI retains WORKFLOW_SURVEY_AGENT_FAILED for survey-code" \
    "$WI_SKILL" "WORKFLOW_SURVEY_AGENT_FAILED: survey-code"
assert_file_contains     "F10" "WI retains WORKFLOW_SURVEY_AGENT_FAILED for survey-history" \
    "$WI_SKILL" "WORKFLOW_SURVEY_AGENT_FAILED: survey-history"

# F11-F15: Bug D — clarify-intent
if [ -f "$CI_SKILL" ]; then
    count=$(grep -cF "skills/_shared/survey-artifact-valid.md" "$CI_SKILL" || true)
    if [ "${count:-0}" -ge 2 ]; then
        pass "F11. CI references shared contract in both Step 6 and Completion 3 (count=$count)"
    else
        fail "F11. CI references shared contract in both Step 6 and Completion 3 — found ${count:-0}, expected >=2"
    fi
else
    fail "F11. CI references shared contract in both Step 6 and Completion 3 — file missing: $CI_SKILL"
fi
assert_file_not_contains "F12" "CI no longer uses 'Both present -> surveys' existence-only phrase" \
    "$CI_SKILL" "Both present"
assert_file_not_contains "F13" "CI Completion 3 no longer says 'Either missing -> invoke the missing survey'" \
    "$CI_SKILL" "Either missing → invoke the missing survey"
assert_file_contains     "F14" "CI now expresses validity check (mentions 'valid')" \
    "$CI_SKILL" "valid"
assert_file_not_contains "F15" "CI does NOT inline artifact_valid() function body" \
    "$CI_SKILL" 'grep -qF "## Verified Claims"'

# ===========================================================================
# Group G — Bug A: agent files state write rationale
# ===========================================================================
echo "--- Group G: agent file Write rationale (Bug A) ---"

assert_file_contains "G1" "SC agent declares artifact write REQUIRED"          "$SC_AGENT" "REQUIRED"
assert_file_contains "G2" "SH agent declares artifact write REQUIRED"          "$SH_AGENT" "REQUIRED"
assert_file_contains "G3" "SC agent rationale mentions outside git repository" "$SC_AGENT" "outside any git repository"
assert_file_contains "G4" "SH agent rationale mentions outside git repository" "$SH_AGENT" "outside any git repository"

# ===========================================================================
# Summary
# ===========================================================================
TOTAL=$((PASS_COUNT + ERRORS))
echo ""
echo "==========================================================="
if [ "$ERRORS" -eq 0 ]; then
    echo "All ${TOTAL} tests passed"
else
    echo "${ERRORS} test(s) failed out of ${TOTAL}"
fi
echo "==========================================================="

exit "$ERRORS"
