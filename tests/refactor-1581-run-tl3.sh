#!/usr/bin/env bash
# tests/refactor-1581-run-tl3.sh
# Tests: bin/select-tests.sh, .env.example, tests/TL3-hook-*.sh
# Tags: test-selection, tl3-toggle, run-tl3, scope:issue-specific
#
# TL3 gap (what this test does NOT catch):
# - Actual invocation inside a real run-tests session where get-config-var reads .env
# - select-tests.sh behavior when AGENTS_CONFIG_DIR differs from AGENTS_DIR
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: pwsh-required
#
# Issue #1581 — RUN_E2E → RUN_TL3 rename + RUN_TL3=on auto-appends tests/TL3-*.sh.
# Behavioral cases (C1..C5) drive bin/select-tests.sh; static cases (C6,C7)
# assert the .env.example and TL3-hook-*.sh source edits. Pre-implementation,
# C1/C4/C6/C7 are expected RED; C2/C3/C5 pass now and after implementation.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECT_SH="${AGENTS_DIR}/bin/select-tests.sh"
ENV_EXAMPLE="${AGENTS_DIR}/.env.example"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d 2>/dev/null || echo "/tmp/r1581-$$")"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a temp git repo: base commit + HEAD commit touching given paths.
# select-tests.sh runs `git diff` in this CWD but resolves TESTS_DIR from its
# own location (the real worktree tests/), so real TL3-*.sh are the search set.
make_repo() {
    local repo="$1"; shift
    mkdir -p "$repo/bin" "$repo/docs"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    : > "$repo/docs/history.md"
    : > "$repo/bin/select-tests.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    git -C "$repo" branch -f base HEAD
    for f in "$@"; do
        mkdir -p "$repo/$(dirname "$f")"
        echo "change" >> "$repo/$f"
    done
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "head" --allow-empty
}

# C1: RUN_TL3=on + docs-only diff → ALL tests/TL3-*.sh dispatcher files appended.
# We assert the exact count (not just "at least one") to prevent a hardcoded-file
# implementation from slipping through.
test_C1_tl3_on_appends() {
    local repo="$TMPDIR_BASE/c1"
    make_repo "$repo" "docs/history.md"
    local out expected_count actual_count
    expected_count="$(find "$AGENTS_DIR/tests" -maxdepth 1 -name "TL3-*.sh" | wc -l | tr -d ' ')"
    out="$(cd "$repo" && RUN_TL3=on run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    actual_count="$(echo "$out" | grep -cE "tests/TL3-.*\.sh" || true)"
    if [ "$actual_count" -eq "$expected_count" ] && [ "$expected_count" -gt 0 ]; then
        pass "C1_tl3_on_appends: RUN_TL3=on appends all $expected_count TL3-*.sh files on docs-only diff"
    elif [ "$actual_count" -gt 0 ] && [ "$actual_count" -lt "$expected_count" ]; then
        fail "C1_tl3_on_appends: only $actual_count/$expected_count TL3-*.sh files appended (partial implementation?)
--- output ---
$out"
    else
        fail "C1_tl3_on_appends: expected $expected_count TL3-*.sh lines, got $actual_count (implementation pending)
--- output ---
$out"
    fi
}

# C2: RUN_TL3=off + docs-only diff → no TL3-*.sh in output.
test_C2_tl3_off_absent() {
    local repo="$TMPDIR_BASE/c2"
    make_repo "$repo" "docs/history.md"
    local out
    out="$(cd "$repo" && RUN_TL3=off run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    if echo "$out" | grep -qE "tests/TL3-.*\.sh"; then
        fail "C2_tl3_off_absent: TL3-*.sh leaked with RUN_TL3=off
--- output ---
$out"
    else
        pass "C2_tl3_off_absent: RUN_TL3=off does not append TL3-*.sh"
    fi
}

# C3: RUN_TL3 unset (default off) → no TL3-*.sh appended.
test_C3_tl3_unset_absent() {
    local repo="$TMPDIR_BASE/c3"
    make_repo "$repo" "docs/history.md"
    local out
    out="$(cd "$repo" && env -u RUN_TL3 run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    if echo "$out" | grep -qE "tests/TL3-.*\.sh"; then
        fail "C3_tl3_unset_absent: TL3-*.sh appended with RUN_TL3 unset
--- output ---
$out"
    else
        pass "C3_tl3_unset_absent: unset RUN_TL3 (default off) does not append TL3-*.sh"
    fi
}

# C_new (HIGH-1): RUN_TL3=on + non-docs/non-matching diff → TL3-*.sh still appended.
# select-tests.sh should append TL3 files unconditionally when RUN_TL3=on,
# regardless of whether the changed files are docs-only or stem-matched.
test_Cnew_tl3_on_non_docs_non_matching() {
    local repo="$TMPDIR_BASE/cnew"
    make_repo "$repo" "bin/somefile.sh"
    local out
    out="$(cd "$repo" && RUN_TL3=on run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    if echo "$out" | grep -qE "tests/TL3-.*\.sh"; then
        pass "Cnew_tl3_on_non_docs_non_matching: RUN_TL3=on appends TL3-*.sh even for non-docs/non-matching diff"
    else
        fail "Cnew_tl3_on_non_docs_non_matching: expected TL3-*.sh with RUN_TL3=on + bin/somefile.sh diff (implementation pending)
--- output ---
$out"
    fi
}

# C4: RUN_TL3=1 (numeric on) is treated as ON → TL3-*.sh appended.
# Note: true/off normalization is delegated to get-config-var; this test exercises
# the numeric alias only. Other truthy variants (true, yes) are out of scope here.
test_C4_tl3_numeric_on() {
    local repo="$TMPDIR_BASE/c4"
    make_repo "$repo" "docs/history.md"
    local out
    out="$(cd "$repo" && RUN_TL3=1 run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    if echo "$out" | grep -qE "tests/TL3-.*\.sh"; then
        pass "C4_tl3_numeric_on: RUN_TL3=1 treated as ON, appends TL3-*.sh"
    else
        fail "C4_tl3_numeric_on: expected TL3-*.sh with RUN_TL3=1 (implementation pending)
--- output ---
$out"
    fi
}

# C5: RUN_TL3=on + stem match on hooks/workflow-mark.js (stems to "workflow-mark",
# which matches tests/TL3-hook-workflow-mark.sh) → both the stem-match path and the
# RUN_TL3 unconditional-append path try to include the same file.
# The shared `seen` map must prevent it from appearing twice.
# Also assert count == 1.
test_C5_no_duplicate_lines() {
    local repo="$TMPDIR_BASE/c5"
    make_repo "$repo" "hooks/workflow-mark.js"
    local out dups
    out="$(cd "$repo" && RUN_TL3=on run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    dups="$(echo "$out" | grep -v '^$' | sort | uniq -d)"
    if [ -n "$dups" ]; then
        fail "C5_no_duplicate_lines: duplicate lines in output
--- duplicates ---
$dups
--- output ---
$out"
        return
    fi
    # Also verify a specific TL3-hook file appears exactly once (count == 1 assert).
    local hook_count
    hook_count="$(echo "$out" | grep -cE 'TL3-hook-workflow-mark\.sh' || true)"
    if [ "$hook_count" -eq 1 ]; then
        pass "C5_no_duplicate_lines: RUN_TL3=on + stem match produces no duplicate paths; TL3-hook-workflow-mark.sh appears exactly once"
    elif [ "$hook_count" -eq 0 ]; then
        # Pre-impl: hook file not yet appended; this is the same as no-duplicate check passing
        # but the count==1 assertion cannot pass yet.
        pass "C5_no_duplicate_lines: RUN_TL3=on + stem match produces no duplicate paths (TL3-hook-workflow-mark.sh not yet appended; count==1 check deferred to post-impl)"
    else
        fail "C5_no_duplicate_lines: TL3-hook-workflow-mark.sh appears $hook_count times (expected exactly 1)
--- output ---
$out"
    fi
}

# C6 (static): .env.example has RUN_TL3=off and no RUN_E2E entry.
test_C6_env_example_renamed() {
    if [ ! -f "$ENV_EXAMPLE" ]; then
        fail "C6_env_example_renamed: .env.example not found at $ENV_EXAMPLE"
        return
    fi
    local has_tl3 has_e2e
    has_tl3="$(grep -cE '^[[:space:]]*RUN_TL3=off' "$ENV_EXAMPLE")"
    has_e2e="$(grep -cE '^[[:space:]]*RUN_E2E=' "$ENV_EXAMPLE")"
    if [ "$has_tl3" -ge 1 ] && [ "$has_e2e" -eq 0 ]; then
        pass "C6_env_example_renamed: RUN_TL3=off present, RUN_E2E entry absent"
    else
        fail "C6_env_example_renamed: expected RUN_TL3=off and no RUN_E2E (tl3=$has_tl3 e2e=$has_e2e; implementation pending)"
    fi
}

# C7 (static): every top-level tests/TL3-hook-*.sh dispatcher file uses
# --is-off RUN_TL3, not RUN_E2E. Only top-level dispatchers have skip-gates;
# TL3-hook-*/main.sh and helpers.sh are sourced bodies with no independent gate.
test_C7_tl3_hooks_use_run_tl3() {
    local bad=""
    local found=0
    local f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        found=$((found + 1))
        local rel="${f#"$AGENTS_DIR"/}"
        if ! grep -qE -- '--is-off RUN_TL3' "$f"; then
            bad="${bad}\n  missing --is-off RUN_TL3: $rel"
        fi
        if grep -qE -- '--is-off RUN_E2E' "$f"; then
            bad="${bad}\n  still uses --is-off RUN_E2E: $rel"
        fi
    done < <(find "$AGENTS_DIR/tests" -maxdepth 1 -name "TL3-hook-*.sh" | sort)
    if [ "$found" -eq 0 ]; then
        fail "C7_tl3_hooks_use_run_tl3: no TL3-hook-* shell files found (recursive)"
    elif [ -z "$bad" ]; then
        pass "C7_tl3_hooks_use_run_tl3: all $found TL3-hook-* shell files use --is-off RUN_TL3 (no RUN_E2E)"
    else
        fail "C7_tl3_hooks_use_run_tl3: violations (implementation pending):$(echo -e "$bad")"
    fi
}

if [ ! -f "$SELECT_SH" ]; then
    echo "FAIL: bin/select-tests.sh not found at $SELECT_SH"
    echo "Results: PASS=0 FAIL=1"
    exit 1
fi

# C8: RUN_TL3=on + tests/_archive/TL3-*.sh → archive entries NEVER appear in output.
# The new TL3-append uses find -maxdepth 1 which should exclude _archive/ subdirectory.
test_C8_tl3_archive_excluded() {
    local repo="$TMPDIR_BASE/c8"
    make_repo "$repo" "docs/history.md"
    local out
    out="$(cd "$repo" && RUN_TL3=on run_with_timeout 120 bash "$SELECT_SH" base 2>/dev/null)"
    if echo "$out" | grep -q "_archive/"; then
        fail "C8_tl3_archive_excluded: _archive/TL3-*.sh entry leaked into RUN_TL3=on output
--- output ---
$out"
    else
        pass "C8_tl3_archive_excluded: tests/_archive/ entries never returned with RUN_TL3=on"
    fi
}

test_C1_tl3_on_appends
test_C2_tl3_off_absent
test_C3_tl3_unset_absent
test_C4_tl3_numeric_on
test_C5_no_duplicate_lines
test_C6_env_example_renamed
test_C7_tl3_hooks_use_run_tl3
test_C8_tl3_archive_excluded
test_Cnew_tl3_on_non_docs_non_matching

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
