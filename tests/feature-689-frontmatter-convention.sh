#!/bin/bash
# tests/feature-689-frontmatter-convention.sh
# Tests: tests/*.sh frontmatter convention
# Tags: test-selection, frontmatter, issue-689
#
# Issue #689 — every test file under tests/ (excluding tests/_archive/) must
# carry single-line `# Tests:` and `# Tags:` frontmatter within its first 10
# lines, right after the shebang and filename comment.
#
# This test is expected to FAIL until Phase 2 (frontmatter backfill) lands.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$AGENTS_DIR/tests"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Files under tests/ (top-level only — excludes _archive/) with .sh extension.
list_test_files() {
    find "$TESTS_DIR" -maxdepth 1 -type f -name "*.sh" 2>/dev/null | sort
}

# Check that a file has single-line `# Tests:` AND `# Tags:` in first 10 lines.
check_frontmatter() {
    local f="$1"
    local head10
    head10="$(head -n 10 "$f" 2>/dev/null)"
    local tests_count tags_count
    tests_count="$(echo "$head10" | grep -c '^# Tests:')"
    tags_count="$(echo "$head10" | grep -c '^# Tags:')"
    if [ "$tests_count" -ge 1 ] && [ "$tags_count" -ge 1 ]; then
        return 0
    fi
    return 1
}

# C1: all tests/*.sh (excluding _archive) carry single-line `# Tests:` + `# Tags:`.
test_C1_all_files_have_frontmatter() {
    local missing=0
    local missing_files=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if ! check_frontmatter "$f"; then
            missing=$((missing + 1))
            missing_files="$missing_files
  $f"
        fi
    done < <(list_test_files)
    if [ "$missing" -eq 0 ]; then
        pass "C1_all_files_have_frontmatter: every tests/*.sh carries # Tests: and # Tags:"
    else
        fail "C1_all_files_have_frontmatter: $missing file(s) missing frontmatter:$missing_files"
    fi
}

# C2: no multi-line format. Specifically, no continuation lines (indented `- ` items)
# following a `# Tests:` or `# Tags:` header in the first 10 lines.
test_C2_no_multiline_format() {
    local bad=0
    local bad_files=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        # Detect a `# Tests:` or `# Tags:` line immediately followed by a
        # `#   - ` continuation-style line within the first 10 lines.
        if head -n 10 "$f" 2>/dev/null | awk '
            /^# (Tests|Tags):/ { prev=1; next }
            prev && /^#[[:space:]]+- / { found=1; exit }
            { prev=0 }
            END { exit found ? 0 : 1 }
        '; then
            bad=$((bad + 1))
            bad_files="$bad_files
  $f"
        fi
    done < <(list_test_files)
    if [ "$bad" -eq 0 ]; then
        pass "C2_no_multiline_format: no multi-line continuation under # Tests:/# Tags:"
    else
        fail "C2_no_multiline_format: $bad file(s) use multi-line format:$bad_files"
    fi
}

# C3: three known reference files parse cleanly.
test_C3_reference_files_parse() {
    local refs=(
        "$TESTS_DIR/feature-608-session-close.sh"
        "$TESTS_DIR/feature-405-final-report.sh"
        "$TESTS_DIR/feature-worktree-end-step55-promotion.sh"
    )
    local missing=0 bad=0
    local detail=""
    for f in "${refs[@]}"; do
        if [ ! -f "$f" ]; then
            missing=$((missing + 1))
            detail="$detail
  missing: $f"
            continue
        fi
        if ! check_frontmatter "$f"; then
            bad=$((bad + 1))
            detail="$detail
  no frontmatter: $f"
        fi
    done
    if [ "$missing" -eq 0 ] && [ "$bad" -eq 0 ]; then
        pass "C3_reference_files_parse: all 3 reference files have valid frontmatter"
    else
        fail "C3_reference_files_parse: missing=$missing bad=$bad$detail"
    fi
}

test_C1_all_files_have_frontmatter
test_C2_no_multiline_format
test_C3_reference_files_parse

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
