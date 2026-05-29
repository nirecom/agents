#!/bin/bash
# tests/fix-worktree-end-git-pull.sh
#
# Regression tests for the SKILL.md change that adds:
#   `git -C <main> pull --ff-only`
# as a second command in Step 6h of skills/worktree-end/SKILL.md,
# immediately after `git -C <main> fetch --prune origin`.
#
# Test cases:
#   1. The literal string `git -C <main> pull --ff-only` is present.
#   2. The pull --ff-only line appears AFTER the fetch --prune origin line.
#   3. The pull --ff-only line falls within the Step 6 / Step 7 section.
#   4. No bare `git -C <main> pull` without --ff-only was introduced.
#
# The target file defaults to skills/worktree-end/SKILL.md (relative to the
# repo root, resolved from this script's location), but can be overridden via
# the TARGET_FILE env var for pre-edit fixture verification.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Allow override for fixture-based pre-edit verification.
TARGET_FILE="${TARGET_FILE:-${AGENTS_DIR}/skills/worktree-end/SKILL.md}"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 — Normal — present
# The literal string must appear somewhere in the file.
# ─────────────────────────────────────────────────────────────────────────────

test_pull_ff_only_present() {
    if grep -qF 'git -C <main> pull --ff-only' "$TARGET_FILE"; then
        pass "pull --ff-only: literal string present in SKILL.md"
    else
        fail "pull --ff-only: literal string NOT found in SKILL.md"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 — Normal — order
# The pull --ff-only line must appear AFTER the fetch --prune origin line.
# ─────────────────────────────────────────────────────────────────────────────

test_pull_after_fetch() {
    local fetch_line pull_line
    fetch_line="$(grep -n 'git -C <main> fetch --prune origin' "$TARGET_FILE" | head -1 | cut -d: -f1)"
    pull_line="$(grep -n 'git -C <main> pull --ff-only' "$TARGET_FILE" | head -1 | cut -d: -f1)"

    if [ -z "$fetch_line" ]; then
        fail "order: fetch --prune origin line not found (cannot check order)"
        return
    fi
    if [ -z "$pull_line" ]; then
        fail "order: pull --ff-only line not found (cannot check order)"
        return
    fi

    if [ "$pull_line" -gt "$fetch_line" ]; then
        pass "order: pull --ff-only (line $pull_line) appears after fetch --prune origin (line $fetch_line)"
    else
        fail "order: pull --ff-only (line $pull_line) must come AFTER fetch --prune origin (line $fetch_line)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 — Normal — section
# The pull --ff-only line must fall within Step 6 (before ## Rules, since Step 7
# no longer exists after #608).
# ─────────────────────────────────────────────────────────────────────────────

test_pull_in_step6_section() {
    local step6_line rules_line pull_line
    step6_line="$(grep -n '^6\.\s\+\*\*Cleanup\*\*' "$TARGET_FILE" | head -1 | cut -d: -f1)"
    rules_line="$(grep -n '^## Rules' "$TARGET_FILE" | head -1 | cut -d: -f1)"
    pull_line="$(grep -n 'git -C <main> pull --ff-only' "$TARGET_FILE" | head -1 | cut -d: -f1)"

    if [ -z "$step6_line" ]; then
        fail "section: Step 6 header not found"
        return
    fi
    if [ -z "$rules_line" ]; then
        fail "section: ## Rules header not found"
        return
    fi
    if [ -z "$pull_line" ]; then
        fail "section: pull --ff-only line not found"
        return
    fi

    if [ "$pull_line" -gt "$step6_line" ] && [ "$pull_line" -lt "$rules_line" ]; then
        pass "section: pull --ff-only (line $pull_line) falls within Step 6 (line $step6_line)..## Rules (line $rules_line)"
    else
        fail "section: pull --ff-only (line $pull_line) is NOT between Step 6 (line $step6_line) and ## Rules (line $rules_line)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4 — Regression — no bare pull
# The file must NOT contain `git -C <main> pull` followed by anything other
# than ` --ff-only` (no bare git pull, no other flags).
# ─────────────────────────────────────────────────────────────────────────────

test_no_bare_pull() {
    # Match `git -C <main> pull` NOT followed by ` --ff-only`
    # Using grep -P for negative lookahead; fall back to two-step if unavailable.
    if grep -qP 'git -C <main> pull(?! --ff-only)' "$TARGET_FILE" 2>/dev/null; then
        fail "regression: bare 'git -C <main> pull' without --ff-only found"
    elif grep -qP 'git -C <main> pull(?! --ff-only)' "$TARGET_FILE" 2>&1 | grep -q 'invalid'; then
        # Perl regex not available; fall back to two-step approach.
        local all_pulls ff_only_pulls
        all_pulls="$(grep -c 'git -C <main> pull' "$TARGET_FILE" 2>/dev/null || echo 0)"
        ff_only_pulls="$(grep -c 'git -C <main> pull --ff-only' "$TARGET_FILE" 2>/dev/null || echo 0)"
        if [ "$all_pulls" -eq "$ff_only_pulls" ]; then
            pass "regression: all 'git -C <main> pull' occurrences include --ff-only ($all_pulls/$ff_only_pulls)"
        else
            fail "regression: $all_pulls 'git -C <main> pull' occurrences but only $ff_only_pulls with --ff-only"
        fi
    else
        pass "regression: no bare 'git -C <main> pull' without --ff-only"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

echo "Target file: $TARGET_FILE"
echo ""

test_pull_ff_only_present
test_pull_after_fetch
test_pull_in_step6_section
test_no_bare_pull

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
