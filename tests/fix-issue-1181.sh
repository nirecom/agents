#!/bin/bash
# Tests: skills/workflow-init/SKILL.md, skills/workflow-init/scripts/list-open-sub-issues.sh, tests/feature-issue-create-skill/section-dispatch-bulk.sh
# Tags: workflow-init, meta-routing, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real gh API calls to GitHub's sub_issues endpoint
# - AskUserQuestion UI rendering and actual user interaction in a live session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Tests for issue #1181 — workflow-init WI-8 sub-issue guard for Path META.
#
# Path META (PM4) currently runs /issue-create bulk unconditionally, even when
# the meta issue already has open sub-issues. The fix adds a WI-8 guard:
# 1. A new script list-open-sub-issues.sh probes the meta issue's sub-issues.
# 2. WI-8 in SKILL.md invokes it, re-fetches selected sub-issue JSON, resolves
#    OWNER_REPO, loops over ISSUES[@], and routes to Path META only when
#    NO_OPEN (all sub-issues closed or none exist).
# 3. When sub-issues are already open, WI-8 asks the user which to work on via
#    AskUserQuestion (handles HAS_OPEN) and aborts on ERROR.
#
# RED before /write-code runs — T2–T8 grep assertions match prose that
# /write-code will add to skills/workflow-init/SKILL.md, and T12 matches prose
# that /write-code will add to tests/feature-issue-create-skill/section-dispatch-bulk.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
SCRIPT="$AGENTS_DIR/skills/workflow-init/scripts/list-open-sub-issues.sh"
SECTION_BULK="$AGENTS_DIR/tests/feature-issue-create-skill/section-dispatch-bulk.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# ===========================================================================
# T1: list-open-sub-issues.sh exists and is executable
# ===========================================================================
if [ -x "$SCRIPT" ]; then
    pass "T1: list-open-sub-issues.sh exists and is executable"
elif [ -f "$SCRIPT" ]; then
    fail "T1: list-open-sub-issues.sh exists but is not executable"
else
    skip "T1: list-open-sub-issues.sh not yet created (will be written by write-code) — RED until implementation"
    FAIL=$((FAIL + 1))
fi

# ===========================================================================
# T2: SKILL.md references list-open-sub-issues in WI-8 section
# ===========================================================================
if grep -q "list-open-sub-issues" "$WORKFLOW_INIT_SKILL"; then
    pass "T2: SKILL.md references list-open-sub-issues"
else
    fail "T2: SKILL.md does not reference list-open-sub-issues — RED until implementation"
fi

# ===========================================================================
# T3: SKILL.md contains sub-issue selection re-fetch
#     (gh issue view for the selected sub-issue, or re-fetch / 再取得 prose)
# ===========================================================================
if grep -qiE "(gh issue view.*SELECTED|re.fetch|再取得)" "$WORKFLOW_INIT_SKILL"; then
    pass "T3: SKILL.md contains sub-issue selection re-fetch reference"
else
    fail "T3: SKILL.md missing sub-issue selection re-fetch — RED until implementation"
fi

# ===========================================================================
# T4: SKILL.md contains OWNER_REPO resolution (nameWithOwner or OWNER_REPO)
# ===========================================================================
if grep -qE "(nameWithOwner|OWNER_REPO)" "$WORKFLOW_INIT_SKILL"; then
    pass "T4: SKILL.md contains OWNER_REPO resolution"
else
    fail "T4: SKILL.md missing OWNER_REPO resolution — RED until implementation"
fi

# ===========================================================================
# T5: SKILL.md contains ISSUES[@] full loop reference
# ===========================================================================
if grep -qE 'ISSUES\[(@|\*|[0-9]+)\]' "$WORKFLOW_INIT_SKILL"; then
    pass "T5: SKILL.md contains ISSUES[@] full loop reference"
else
    fail "T5: SKILL.md missing ISSUES[@] loop reference — RED until implementation"
fi

# ===========================================================================
# T6: SKILL.md routes NO_OPEN to Path META
# ===========================================================================
if grep -q "NO_OPEN" "$WORKFLOW_INIT_SKILL"; then
    pass "T6: SKILL.md routes NO_OPEN to Path META"
else
    fail "T6: SKILL.md missing NO_OPEN routing — RED until implementation"
fi

# ===========================================================================
# T7: SKILL.md has ERROR → AskUserQuestion handling in WI-8 context
# ===========================================================================
# Check that both ERROR and AskUserQuestion appear in the WI-8 section.
# We use awk to extract only the WI-8 section (between ### Step WI-8 and
# the next ### Step or end of file), then grep for both keywords.
WI8_SECTION=$(awk '/^### Step WI-8/,/^### Step WI-[0-9]/ { if (/^### Step WI-[0-9]/ && !/^### Step WI-8/) exit; print }' "$WORKFLOW_INIT_SKILL")
if echo "$WI8_SECTION" | grep -q "ERROR" && echo "$WI8_SECTION" | grep -qi "AskUserQuestion"; then
    pass "T7: SKILL.md WI-8 section has ERROR → AskUserQuestion handling"
else
    fail "T7: SKILL.md WI-8 section missing ERROR or AskUserQuestion — RED until implementation"
fi

# ===========================================================================
# T8: SKILL.md has WORKFLOW_ABORTED_META_SUBISSUE_SELECTION sentinel
# ===========================================================================
if grep -q "WORKFLOW_ABORTED_META_SUBISSUE_SELECTION" "$WORKFLOW_INIT_SKILL"; then
    pass "T8: SKILL.md has WORKFLOW_ABORTED_META_SUBISSUE_SELECTION sentinel"
else
    fail "T8: SKILL.md missing WORKFLOW_ABORTED_META_SUBISSUE_SELECTION sentinel — RED until implementation"
fi

# ===========================================================================
# T9–T11: mock-gh tests for list-open-sub-issues.sh
# ===========================================================================
if [ ! -f "$SCRIPT" ]; then
    skip "T9-T11: list-open-sub-issues.sh not yet created (will be written by write-code)"
    # Count as failures: tests should be RED until source is written
    FAIL=$((FAIL + 3))
else
    # -------------------------------------------------------------------------
    # Mock setup shared by T9–T11
    # -------------------------------------------------------------------------
    setup_sub_mock() {
        TMP="$(mktemp -d 2>/dev/null || mktemp -d -t submock)"
        mkdir -p "$TMP/mock-bin"

        # Mock gh: handles `gh api repos/.../sub_issues` (REST) and `gh issue view`
        cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
# Dispatch on subcommand pattern
if [ "$1" = "api" ] && echo "$2" | grep -q "sub_issues"; then
    # Return sub-issues array from GH_MOCK_SUBISSUES_JSON env var (REST format)
    echo "${GH_MOCK_SUBISSUES_JSON:-[]}"
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    # Return issue state from GH_MOCK_ISSUE_STATE (default open)
    N="$3"
    STATE="${GH_MOCK_ISSUE_STATE:-open}"
    echo "{\"number\":$N,\"state\":\"$STATE\",\"title\":\"Issue $N\"}"
    exit 0
fi
# Fallback: unknown invocation
echo "mock-gh: unhandled args: $*" >&2
exit 1
MOCKGH
        chmod +x "$TMP/mock-bin/gh"
        export PATH="$TMP/mock-bin:$PATH"
    }

    teardown_sub_mock() {
        rm -rf "$TMP" 2>/dev/null
        unset GH_MOCK_SUBISSUES_JSON GH_MOCK_ISSUE_STATE
        PATH="${PATH#$TMP/mock-bin:}"
        export PATH
    }

    # =========================================================================
    # T9: open sub-issue → first line HAS_OPEN, second line matches #N:, exit 0
    # =========================================================================
    setup_sub_mock
    export GH_MOCK_SUBISSUES_JSON='[{"number":42,"title":"Open child","state":"open"}]'
    OUT=$(run_with_timeout 10 bash "$SCRIPT" myorg/myrepo 99 2>/dev/null)
    RC=$?
    LINE1=$(echo "$OUT" | head -1)
    LINE2=$(echo "$OUT" | sed -n '2p')
    if [ "$RC" -eq 0 ] && [ "$LINE1" = "HAS_OPEN" ] && echo "$LINE2" | grep -qE "^#[0-9]+: "; then
        pass "T9: open sub-issue → HAS_OPEN first line, #N: second line, exit 0"
    else
        fail "T9: expected (HAS_OPEN,#N:,rc=0); got rc=$RC line1='$LINE1' line2='$LINE2'"
    fi
    teardown_sub_mock

    # =========================================================================
    # T10: empty sub-issues array → first line NO_OPEN, exit 1
    # =========================================================================
    setup_sub_mock
    export GH_MOCK_SUBISSUES_JSON='[]'
    OUT=$(run_with_timeout 10 bash "$SCRIPT" myorg/myrepo 99 2>/dev/null)
    RC=$?
    LINE1=$(echo "$OUT" | head -1)
    if [ "$RC" -eq 1 ] && [ "$LINE1" = "NO_OPEN" ]; then
        pass "T10: empty sub-issues array → NO_OPEN first line, exit 1"
    else
        fail "T10: expected (NO_OPEN,rc=1); got rc=$RC line1='$LINE1'"
    fi
    teardown_sub_mock

    # =========================================================================
    # T11: closed-only sub-issue → first line NO_OPEN, exit 1
    #      (distinguishes no-sub-issues from all-closed)
    # =========================================================================
    setup_sub_mock
    export GH_MOCK_SUBISSUES_JSON='[{"number":55,"title":"Closed child","state":"closed"}]'
    OUT=$(run_with_timeout 10 bash "$SCRIPT" myorg/myrepo 99 2>/dev/null)
    RC=$?
    LINE1=$(echo "$OUT" | head -1)
    if [ "$RC" -eq 1 ] && [ "$LINE1" = "NO_OPEN" ]; then
        pass "T11: closed-only sub-issue → NO_OPEN first line, exit 1"
    else
        fail "T11: expected (NO_OPEN,rc=1) for closed-only; got rc=$RC line1='$LINE1'"
    fi
    teardown_sub_mock
fi

# ===========================================================================
# T12: section-dispatch-bulk.sh contains WF-META-DOC2 assertion for
#      list-open-sub-issues in WI-8
# ===========================================================================
if [ ! -f "$SECTION_BULK" ]; then
    fail "T12: section-dispatch-bulk.sh missing"
elif grep -q "WF-META-DOC2" "$SECTION_BULK" && grep -q "list-open-sub-issues" "$SECTION_BULK"; then
    pass "T12: section-dispatch-bulk.sh contains WF-META-DOC2 with list-open-sub-issues assertion"
else
    fail "T12: section-dispatch-bulk.sh missing WF-META-DOC2 or list-open-sub-issues reference — RED until implementation"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
