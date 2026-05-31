#!/usr/bin/env bash
# Tests: agents/survey-history.md, agents/survey-history.md., skills/survey-history/SKILL.md
# Tags: survey-history
# Test suite for survey-history feature (Issue #262).
# Static doc checks against skills/survey-history/SKILL.md and agents/survey-history.md.
# Tests will FAIL until the source files are created — that is expected.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SH_SKILL="$REPO_ROOT/skills/survey-history/SKILL.md"
SH_AGENT="$REPO_ROOT/agents/survey-history.md"
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

assert_file_exists() {
    local id="$1"
    local desc="$2"
    local file="$3"
    if [ -f "$file" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — file missing: $file"
    fi
}

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

assert_file_contains_regex_i() {
    local id="$1"
    local desc="$2"
    local file="$3"
    local pattern="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qEi -- "$pattern" "$file"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — pattern not found: '${pattern}' in $file"
    fi
}

assert_file_not_contains() {
    local id="$1"
    local desc="$2"
    local file="$3"
    local needle="$4"
    if [ ! -f "$file" ]; then
        # If file is missing it cannot contain anything — treat as pass per intent
        # (the file-existence check is enforced by a separate test).
        pass "${id}. ${desc} (file absent, vacuously true)"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        fail "${id}. ${desc} — unexpected substring present: '${needle}' in $file"
    else
        pass "${id}. ${desc}"
    fi
}

# ===========================================================================
# Section A — SH-HAPPY: skill exists and documents happy path
# ===========================================================================
echo ""
echo "=== Section A — SH-HAPPY: survey-history skill happy path ==="

assert_file_exists "SH-HAPPY-1" \
    "skills/survey-history/SKILL.md exists" \
    "$SH_SKILL"

assert_file_contains "SH-HAPPY-2" \
    "skills/survey-history/SKILL.md contains '## Verified Claims'" \
    "$SH_SKILL" \
    "## Verified Claims"

assert_file_contains "SH-HAPPY-3" \
    "skills/survey-history/SKILL.md contains '## Premise impact assessment'" \
    "$SH_SKILL" \
    "## Premise impact assessment"

# ===========================================================================
# Section B — SH-NOCI: graceful skip when closes_issues absent
# ===========================================================================
echo ""
echo "=== Section B — SH-NOCI: closes_issues absent path ==="

assert_file_contains "SH-NOCI-1" \
    "survey-history SKILL.md documents WORKFLOW_RESEARCH_NOT_NEEDED skip path" \
    "$SH_SKILL" \
    "WORKFLOW_RESEARCH_NOT_NEEDED"

assert_file_exists "SH-NOCI-2" \
    "agents/survey-history.md subagent definition exists" \
    "$SH_AGENT"

# ===========================================================================
# Section C — SH-GH-FAIL: gh CLI failure handling
# ===========================================================================
echo ""
echo "=== Section C — SH-GH-FAIL: gh failure handling ==="

assert_file_contains_regex_i "SH-GH-FAIL" \
    "survey-history SKILL.md mentions gh failure/error/fallback handling" \
    "$SH_SKILL" \
    "(fail|error|fallback)"

# ===========================================================================
# Section D — SH-NO-SENTINEL: must not emit MARK_STEP or PREMISE sentinels
# ===========================================================================
echo ""
echo "=== Section D — SH-NO-SENTINEL: no MARK_STEP/PREMISE emits ==="

assert_file_not_contains "SH-NO-SENTINEL-1a" \
    "skills/survey-history/SKILL.md does not contain '<<WORKFLOW_MARK_STEP'" \
    "$SH_SKILL" \
    "<<WORKFLOW_MARK_STEP"

assert_file_not_contains "SH-NO-SENTINEL-1b" \
    "skills/survey-history/SKILL.md does not contain '<<WORKFLOW_PREMISE'" \
    "$SH_SKILL" \
    "<<WORKFLOW_PREMISE"

assert_file_not_contains "SH-NO-SENTINEL-2a" \
    "agents/survey-history.md does not contain '<<WORKFLOW_MARK_STEP'" \
    "$SH_AGENT" \
    "<<WORKFLOW_MARK_STEP"

assert_file_not_contains "SH-NO-SENTINEL-2b" \
    "agents/survey-history.md does not contain '<<WORKFLOW_PREMISE'" \
    "$SH_AGENT" \
    "<<WORKFLOW_PREMISE"

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
