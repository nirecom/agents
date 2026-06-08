#!/bin/bash
# tests/feature-commit-push-worker-gate3-static.sh
# Tests: agents/commit-push-worker.md, skills/commit-push/SKILL.md
# Tags: static, agent, skill, commit-push, gate3, unstaged-tracked
#
# Static contract test for Gate 3 (commit-push-worker pre-flight Step 1.5).
# Expected red until #269 lands Step 1.5 in agents/commit-push-worker.md and
# updates skills/commit-push/SKILL.md Step 1.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MD="${AGENTS_DIR}/agents/commit-push-worker.md"
CP_SKILL_MD="${AGENTS_DIR}/skills/commit-push/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

# Test 1: worker contains literal 'bin/check-unstaged-tracked.sh'
test_1_worker_has_cli_literal() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "1: $WORKER_MD missing"
        return
    fi
    if grep -qF 'bin/check-unstaged-tracked.sh' "$WORKER_MD"; then
        pass "1: agents/commit-push-worker.md contains bin/check-unstaged-tracked.sh"
    else
        fail "1: agents/commit-push-worker.md missing bin/check-unstaged-tracked.sh literal"
    fi
}

# Test 2: CLI literal appears BEFORE first 'git commit -m' literal
test_2_ordering_cli_before_commit() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "2: $WORKER_MD missing"
        return
    fi
    local cli_line commit_line
    cli_line="$(grep -nF 'bin/check-unstaged-tracked.sh' "$WORKER_MD" | head -n 1 | cut -d: -f1)"
    commit_line="$(grep -nF 'git commit -m' "$WORKER_MD" | head -n 1 | cut -d: -f1)"
    if [ -z "$cli_line" ]; then
        fail "2: CLI literal not found"
        return
    fi
    if [ -z "$commit_line" ]; then
        fail "2: 'git commit -m' literal not found"
        return
    fi
    if [ "$cli_line" -lt "$commit_line" ]; then
        pass "2: CLI literal (line $cli_line) appears before 'git commit -m' (line $commit_line)"
    else
        fail "2: CLI must appear before 'git commit -m'" "cli=$cli_line commit=$commit_line"
    fi
}

# Test 3: worker contains both new status enum values
test_3_status_enum_values() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "3: $WORKER_MD missing"
        return
    fi
    local has_inc has_chk
    has_inc=0; has_chk=0
    grep -qF 'staging_incomplete' "$WORKER_MD" && has_inc=1
    grep -qF 'staging_check_failed' "$WORKER_MD" && has_chk=1
    if [ "$has_inc" -eq 1 ] && [ "$has_chk" -eq 1 ]; then
        pass "3: worker has staging_incomplete AND staging_check_failed in status enum"
    else
        fail "3: missing status values" "staging_incomplete=$has_inc staging_check_failed=$has_chk"
    fi
}

# Test 4: worker contains the rules sentence about Step 1.5 skip
test_4_rules_skip_sentence() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "4: $WORKER_MD missing"
        return
    fi
    if grep -qF 'Staging verification (Step 1.5) is skipped only when' "$WORKER_MD"; then
        pass "4: worker contains 'Staging verification (Step 1.5) is skipped only when'"
    else
        fail "4: worker missing Step 1.5 skip sentence"
    fi
}

# Test 5: skills/commit-push/SKILL.md Step 1 area mentions the CLI literal
test_5_cp_skill_step1_mentions_cli() {
    if [ ! -f "$CP_SKILL_MD" ]; then
        fail "5: $CP_SKILL_MD missing"
        return
    fi
    if grep -qF 'bin/check-unstaged-tracked.sh' "$CP_SKILL_MD"; then
        pass "5: skills/commit-push/SKILL.md mentions bin/check-unstaged-tracked.sh"
    else
        fail "5: skills/commit-push/SKILL.md missing bin/check-unstaged-tracked.sh"
    fi
}

# Test 6: skills/commit-push/SKILL.md step 2-6 block handles staging_incomplete and staging_check_failed
test_6_cp_skill_handles_staging_statuses() {
    if [ ! -f "$CP_SKILL_MD" ]; then
        fail "6: $CP_SKILL_MD missing"
        return
    fi
    local has_inc has_chk
    has_inc=0; has_chk=0
    grep -qF 'staging_incomplete' "$CP_SKILL_MD" && has_inc=1
    grep -qF 'staging_check_failed' "$CP_SKILL_MD" && has_chk=1
    if [ "$has_inc" -eq 1 ] && [ "$has_chk" -eq 1 ]; then
        pass "6: skills/commit-push/SKILL.md handles staging_incomplete AND staging_check_failed"
    else
        fail "6: SKILL.md missing staging status handlers" \
            "staging_incomplete=$has_inc staging_check_failed=$has_chk"
    fi
}

run_all() {
    test_1_worker_has_cli_literal
    test_2_ordering_cli_before_commit
    test_3_status_enum_values
    test_4_rules_skip_sentence
    test_5_cp_skill_step1_mentions_cli
    test_6_cp_skill_handles_staging_statuses
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
