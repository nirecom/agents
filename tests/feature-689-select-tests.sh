#!/bin/bash
# tests/feature-689-select-tests.sh
# Tests: bin/select-tests.sh
# Tags: test-selection, tests, bin, git, pr
#
# Issue #689 — PR-scoped test selection.
# bin/select-tests.sh reads a git diff (between merge-base and HEAD) and
# emits the set of tests/*.sh files whose stems match changed source paths.
#
# Tests for features not yet implemented are expected to SKIP (exit 77)
# at the file level until bin/select-tests.sh lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECT_SH="${AGENTS_DIR}/bin/select-tests.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

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

# Source-absent gate: skip the whole file via exit 77 if bin/select-tests.sh
# does not exist yet. The structural test file is committed now, but the
# behavioral assertions only become meaningful after the source lands.
if [ ! -f "$SELECT_SH" ]; then
    echo "SKIP: bin/select-tests.sh not yet implemented — skipping all cases"
    exit 77
fi

TMPDIR_BASE="$(mktemp -d 2>/dev/null || echo "/tmp/f689-$$")"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a temp git repo with a base commit + a HEAD commit that touches
# given file paths. Echoes the repo path.
make_repo() {
    local repo="$1"; shift
    mkdir -p "$repo/tests/_archive" "$repo/bin" "$repo/skills/run-tests" "$repo/docs"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    # Seed: create empty test files so stem-matching has targets.
    : > "$repo/tests/run-tests.sh"
    : > "$repo/tests/feature-689-select-tests.sh"
    : > "$repo/tests/run-tests-archived.sh"
    mv "$repo/tests/run-tests-archived.sh" "$repo/tests/_archive/run-tests-archived.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    # Tag base as merge-base reference
    git -C "$repo" branch -f base HEAD
    # Apply HEAD-side modifications
    for f in "$@"; do
        mkdir -p "$repo/$(dirname "$f")"
        echo "change" >> "$repo/$f"
    done
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "head" --allow-empty
}

# C1: skills/run-tests/SKILL.md changed → stem match returns tests/*run-tests*.sh
test_C1_stem_match_skill_md() {
    local repo="$TMPDIR_BASE/c1"
    make_repo "$repo" "skills/run-tests/SKILL.md"
    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -qE "tests/.*run-tests"; then
        pass "C1_stem_match_skill_md: SKILL.md change selects a tests/*run-tests* file"
    else
        fail "C1_stem_match_skill_md: expected a tests/*run-tests* file in output
--- output ---
$out"
    fi
}

# C2: bin/select-tests.sh itself changed → selects tests/feature-689-select-tests.sh
test_C2_self_select() {
    local repo="$TMPDIR_BASE/c2"
    make_repo "$repo" "bin/select-tests.sh"
    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -q "tests/feature-689-select-tests.sh"; then
        pass "C2_self_select: bin/select-tests.sh change selects tests/feature-689-select-tests.sh"
    else
        fail "C2_self_select: expected tests/feature-689-select-tests.sh in output
--- output ---
$out"
    fi
}

# C3: empty diff → empty stdout, exit 0
test_C3_empty_diff() {
    local repo="$TMPDIR_BASE/c3"
    make_repo "$repo"
    local out code
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" HEAD HEAD 2>/dev/null)"
    code=$?
    if [ "$code" = "0" ] && [ -z "$out" ]; then
        pass "C3_empty_diff: empty diff → empty stdout, exit 0"
    else
        fail "C3_empty_diff: code=$code, out='$out'"
    fi
}

# C4: no args → exit 1
test_C4_no_args() {
    local code
    run_with_timeout 120 bash "$SELECT_SH" >/dev/null 2>&1
    code=$?
    if [ "$code" = "1" ]; then
        pass "C4_no_args: no args → exit 1"
    else
        fail "C4_no_args: expected exit 1, got $code"
    fi
}

# C5: tests/_archive/ entries NEVER returned, even when stem matches.
test_C5_archive_excluded() {
    local repo="$TMPDIR_BASE/c5"
    # Stage a repo where the ONLY stem match would be in _archive.
    mkdir -p "$repo/tests/_archive" "$repo/bin"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    : > "$repo/tests/_archive/run-tests-archived.sh"
    : > "$repo/bin/unrelated.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    git -C "$repo" branch -f base HEAD
    echo "change" >> "$repo/bin/run-tests-archived.sh"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "head"

    local out
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    if echo "$out" | grep -q "_archive/"; then
        fail "C5_archive_excluded: _archive entry leaked into output
--- output ---
$out"
    else
        pass "C5_archive_excluded: tests/_archive/* never returned"
    fi
}

# C6: docs-only change (docs/history.md) → empty stems → empty stdout
test_C6_docs_only_empty() {
    local repo="$TMPDIR_BASE/c6"
    make_repo "$repo" "docs/history.md"
    local out code
    out="$(cd "$repo" && run_with_timeout 120 bash "$SELECT_SH" base HEAD 2>/dev/null)"
    code=$?
    if [ "$code" = "0" ] && [ -z "$out" ]; then
        pass "C6_docs_only_empty: docs-only change → empty stdout, exit 0"
    else
        fail "C6_docs_only_empty: code=$code, out='$out'"
    fi
}

test_C1_stem_match_skill_md
test_C2_self_select
test_C3_empty_diff
test_C4_no_args
test_C5_archive_excluded
test_C6_docs_only_empty

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
