#!/usr/bin/env bash
# Tests: skills/survey-code/SKILL.md, skills/survey-code/SKILL.md.
# Tags: survey, research, skill, bin, macos
# Test suite for survey-code claim-verification feature (Issue #262).
# Static doc checks against skills/survey-code/SKILL.md.
# Tests will FAIL until the SKILL.md updates are implemented — that is expected.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SURVEY_CODE_SKILL="$REPO_ROOT/skills/survey-code/SKILL.md"
ERRORS=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS does not have timeout)
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
# assert_file_contains <id> <desc> <file> <substring>
# ---------------------------------------------------------------------------
assert_file_contains() {
    local id="$1"
    local desc="$2"
    local file="$3"
    local needle="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — substring not found: '${needle}' in $file"
    fi
}

# ---------------------------------------------------------------------------
# assert_file_not_contains <id> <desc> <file> <substring>
# ---------------------------------------------------------------------------
assert_file_not_contains() {
    local id="$1"
    local desc="$2"
    local file="$3"
    local needle="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        fail "${id}. ${desc} — unexpected substring present: '${needle}' in $file"
    else
        pass "${id}. ${desc}"
    fi
}

# ===========================================================================
# Section A — survey-code SKILL.md doc checks
# ===========================================================================
echo ""
echo "=== Section A — survey-code SKILL.md doc checks ==="

# SC-DOC: survey-code SKILL.md documents "Verified Claims" output section
assert_file_contains "SC-DOC" \
    "survey-code SKILL.md contains 'Verified Claims' section" \
    "$SURVEY_CODE_SKILL" \
    "Verified Claims"

# SC-NO-SENTINEL: survey-code SKILL.md does NOT emit MARK_STEP_research_complete
assert_file_not_contains "SC-NO-SENTINEL" \
    "survey-code SKILL.md does not emit WORKFLOW_MARK_STEP_research_complete" \
    "$SURVEY_CODE_SKILL" \
    "WORKFLOW_MARK_STEP_research_complete"

# SC-SKIP: survey-code SKILL.md documents WORKFLOW_RESEARCH_NOT_NEEDED skip path
assert_file_contains "SC-SKIP" \
    "survey-code SKILL.md documents WORKFLOW_RESEARCH_NOT_NEEDED skip path" \
    "$SURVEY_CODE_SKILL" \
    "WORKFLOW_RESEARCH_NOT_NEEDED"

# SC-RULES-NO-READONLY: Rules section no longer contains the absolute "Read-only" line
assert_file_not_contains "SC-RULES-NO-READONLY" \
    "survey-code SKILL.md no longer claims 'Read-only -- do not modify any files'" \
    "$SURVEY_CODE_SKILL" \
    "Read-only — do not modify any files"

# SC-RULES-WRITE-ALLOWED: Rules section explicitly references shared validity contract
assert_file_contains "SC-RULES-WRITE-ALLOWED" \
    "survey-code SKILL.md Rules explicitly permits artifact write (references shared contract)" \
    "$SURVEY_CODE_SKILL" \
    "survey-artifact-valid.md"

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + ERRORS))
echo "Results: ${PASS_COUNT}/${TOTAL} passed, ${ERRORS} failed"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "${ERRORS} test(s) failed"
    exit 1
fi
