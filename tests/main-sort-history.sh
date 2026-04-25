#!/usr/bin/env bash
# Tests for bin/sort-history.py
# Naming: main direct work → tests/main-<name>.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SORT_CMD="uv run python $REPO_DIR/bin/sort-history.py"

PASS=0
FAIL=0
TMPDIR_BASE=""

setup() {
    TMPDIR_BASE=$(mktemp -d)
    # Create a temporary git repo for hash resolution tests
    TEST_REPO="$TMPDIR_BASE/test-repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -q
    git -C "$TEST_REPO" config user.email "test@example.com"
    git -C "$TEST_REPO" config user.name "Test"
    # Create commits with known dates (ascending order)
    GIT_AUTHOR_DATE="2020-01-01T00:00:00+00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00+00:00" \
        git -C "$TEST_REPO" commit --allow-empty -m "commit-old" -q
    HASH_OLD=$(git -C "$TEST_REPO" rev-parse --short=7 HEAD)

    GIT_AUTHOR_DATE="2022-06-15T00:00:00+00:00" GIT_COMMITTER_DATE="2022-06-15T00:00:00+00:00" \
        git -C "$TEST_REPO" commit --allow-empty -m "commit-mid" -q
    HASH_MID=$(git -C "$TEST_REPO" rev-parse --short=7 HEAD)

    GIT_AUTHOR_DATE="2024-03-01T00:00:00+00:00" GIT_COMMITTER_DATE="2024-03-01T00:00:00+00:00" \
        git -C "$TEST_REPO" commit --allow-empty -m "commit-new" -q
    HASH_NEW=$(git -C "$TEST_REPO" rev-parse --short=7 HEAD)

    GIT_AUTHOR_DATE="2024-12-25T00:00:00+00:00" GIT_COMMITTER_DATE="2024-12-25T00:00:00+00:00" \
        git -C "$TEST_REPO" commit --allow-empty -m "commit-newest" -q
    HASH_NEWEST=$(git -C "$TEST_REPO" rev-parse --short=7 HEAD)
}

cleanup() {
    [ -n "$TMPDIR_BASE" ] && rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    local ef="$TMPDIR_BASE/_expected.tmp" af="$TMPDIR_BASE/_actual.tmp"
    printf '%s\n' "$expected" > "$ef"
    printf '%s\n' "$actual" > "$af"
    if diff -q "$ef" "$af" >/dev/null 2>&1; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        diff -u "$ef" "$af" | head -20 | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
}

run_sort() {
    local input_file="$1"
    shift
    PYTHONIOENCODING=utf-8 $SORT_CMD "$input_file" "$@" 2>/dev/null
}

# --- Normal cases ---

test_already_ascending() {
    echo "Test: already ascending — no change"
    local f="$TMPDIR_BASE/ascending.md"
    cat > "$f" <<EOF
# History

## Changes

### Old feature ($HASH_OLD)
Background: old

### Mid feature ($HASH_MID)
Background: mid

### New feature ($HASH_NEW)
Background: new
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local expected
    expected=$(cat "$f")
    assert_eq "content unchanged" "$expected" "$result"
}

test_descending_to_ascending() {
    echo "Test: descending order → ascending"
    local f="$TMPDIR_BASE/descending.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new

### Mid feature ($HASH_MID)
Background: mid

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # Should be: old, mid, new
    echo "$result" | grep -q "Old feature" || { echo "  FAIL: missing Old"; FAIL=$((FAIL+1)); return; }
    local line_old line_mid line_new
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_mid=$(echo "$result" | grep -n "Mid feature" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_mid" ] && [ "$line_mid" -lt "$line_new" ]; then
        echo "  PASS: order is old < mid < new"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: order wrong (old=$line_old, mid=$line_mid, new=$line_new)"
        FAIL=$((FAIL + 1))
    fi
}

test_anchor_block_dateless_attached() {
    echo "Test: dateless entries stay attached to preceding anchor"
    local f="$TMPDIR_BASE/anchor-block.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new

### Dateless followup
Background: no hash

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # Expected: Old, New, Dateless followup
    local line_old line_new line_dateless
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    line_dateless=$(echo "$result" | grep -n "Dateless followup" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_new" ] && [ "$line_new" -lt "$line_dateless" ]; then
        echo "  PASS: dateless follows its anchor (new)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, new=$line_new, dateless=$line_dateless)"
        FAIL=$((FAIL + 1))
    fi
}

test_floating_block_at_end() {
    echo "Test: leading dateless entries (floating block) placed at end"
    local f="$TMPDIR_BASE/floating.md"
    cat > "$f" <<EOF
# History

## Changes

### Uncommitted work (uncommitted)
Background: no hash

### Another uncommitted
Background: also no hash

### Old feature ($HASH_OLD)
Background: old

### New feature ($HASH_NEW)
Background: new
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_old line_new line_uncommitted line_another
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    line_uncommitted=$(echo "$result" | grep -n "Uncommitted work" | head -1 | cut -d: -f1)
    line_another=$(echo "$result" | grep -n "Another uncommitted" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_new" ] && [ "$line_new" -lt "$line_uncommitted" ] && [ "$line_uncommitted" -lt "$line_another" ]; then
        echo "  PASS: floating block at end, internal order preserved"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, new=$line_new, uncommitted=$line_uncommitted, another=$line_another)"
        FAIL=$((FAIL + 1))
    fi
}

test_multiple_sections_independent() {
    echo "Test: each ## section sorted independently"
    local f="$TMPDIR_BASE/multi-section.md"
    cat > "$f" <<EOF
# History

## Change History

### New change ($HASH_NEW)
Background: new

### Old change ($HASH_OLD)
Background: old

## Incident History

### #1: First incident ($HASH_MID)
Cause: mid

### #2: Second incident ($HASH_OLD)
Cause: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # Change History: old before new
    local ch_old ch_new
    ch_old=$(echo "$result" | grep -n "Old change" | head -1 | cut -d: -f1)
    ch_new=$(echo "$result" | grep -n "New change" | head -1 | cut -d: -f1)
    assert_eq "changes sorted ascending" "1" "$([ "$ch_old" -lt "$ch_new" ] && echo 1 || echo 0)"
    # Incident History: #2(old) before #1(mid)
    local inc1 inc2
    inc1=$(echo "$result" | grep -n "First incident" | head -1 | cut -d: -f1)
    inc2=$(echo "$result" | grep -n "Second incident" | head -1 | cut -d: -f1)
    assert_eq "incidents sorted ascending" "1" "$([ "$inc2" -lt "$inc1" ] && echo 1 || echo 0)"
}

test_pending_entries() {
    echo "Test: (pending) and ((pending)) entries treated as dateless"
    local f="$TMPDIR_BASE/pending.md"
    cat > "$f" <<EOF
# History

## Changes

### Pending feature ((pending))
Background: pending

### Old feature ($HASH_OLD)
Background: old

### Mid feature ($HASH_MID)
Background: mid
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_old line_mid line_pending
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_mid=$(echo "$result" | grep -n "Mid feature" | head -1 | cut -d: -f1)
    line_pending=$(echo "$result" | grep -n "Pending feature" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_mid" ] && [ "$line_mid" -lt "$line_pending" ]; then
        echo "  PASS: pending at end (floating block)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, mid=$line_mid, pending=$line_pending)"
        FAIL=$((FAIL + 1))
    fi
}

test_hash_plus_pending() {
    echo "Test: entries with hash + pending resolve date from hash"
    local f="$TMPDIR_BASE/hash-pending.md"
    cat > "$f" <<EOF
# History

## Changes

### Newest feature ($HASH_NEWEST)
Background: newest

### Mixed entry ($HASH_OLD, (pending))
Background: has hash and pending

### Mid feature ($HASH_MID)
Background: mid
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # Mixed entry has HASH_OLD → should sort first (2020)
    local line_mixed line_mid line_newest
    line_mixed=$(echo "$result" | grep -n "Mixed entry" | head -1 | cut -d: -f1)
    line_mid=$(echo "$result" | grep -n "Mid feature" | head -1 | cut -d: -f1)
    line_newest=$(echo "$result" | grep -n "Newest feature" | head -1 | cut -d: -f1)
    if [ "$line_mixed" -lt "$line_mid" ] && [ "$line_mid" -lt "$line_newest" ]; then
        echo "  PASS: hash+pending resolved by hash date"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (mixed=$line_mixed, mid=$line_mid, newest=$line_newest)"
        FAIL=$((FAIL + 1))
    fi
}

test_empty_paren() {
    echo "Test: empty parens () treated as dateless"
    local f="$TMPDIR_BASE/empty-paren.md"
    cat > "$f" <<EOF
# History

## Changes

### Empty paren entry ()
Background: no hash

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_old line_empty
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_empty=$(echo "$result" | grep -n "Empty paren entry" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_empty" ]; then
        echo "  PASS: empty paren at end (floating)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, empty=$line_empty)"
        FAIL=$((FAIL + 1))
    fi
}

test_single_entry() {
    echo "Test: single entry — no change"
    local f="$TMPDIR_BASE/single.md"
    cat > "$f" <<EOF
# History

## Changes

### Only entry ($HASH_OLD)
Background: only one
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local expected
    expected=$(cat "$f")
    assert_eq "single entry unchanged" "$expected" "$result"
}

test_no_entries() {
    echo "Test: no ### entries — no change"
    local f="$TMPDIR_BASE/no-entries.md"
    cat > "$f" <<EOF
# History

## Changes

No entries yet.
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local expected
    expected=$(cat "$f")
    assert_eq "no entries unchanged" "$expected" "$result"
}

test_dry_run_shows_diff() {
    echo "Test: --dry-run shows diff output"
    local f="$TMPDIR_BASE/dryrun.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO" --dry-run)
    if echo "$result" | grep -q "^---"; then
        echo "  PASS: dry-run shows diff header"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: no diff header in output"
        FAIL=$((FAIL + 1))
    fi
}

test_multiline_body_preserved() {
    echo "Test: multi-line body preserved with entry"
    local f="$TMPDIR_BASE/multiline.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new feature
Changes:
  - Added foo
  - Fixed bar

### Old feature ($HASH_OLD)
Background: old feature
Changes: something old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # Check that "Added foo" follows "New feature" (not "Old feature")
    local line_new line_foo
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    line_foo=$(echo "$result" | grep -n "Added foo" | head -1 | cut -d: -f1)
    local diff=$((line_foo - line_new))
    if [ "$diff" -gt 0 ] && [ "$diff" -lt 6 ]; then
        echo "  PASS: multi-line body stays with entry"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: body detached (new=$line_new, foo=$line_foo)"
        FAIL=$((FAIL + 1))
    fi
}

test_block_with_multiple_dateless() {
    echo "Test: anchor with multiple dateless followers"
    local f="$TMPDIR_BASE/multi-dateless.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new

### Followup A
Background: a

### Followup B
Background: b

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_old line_new line_a line_b
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    line_a=$(echo "$result" | grep -n "Followup A" | head -1 | cut -d: -f1)
    line_b=$(echo "$result" | grep -n "Followup B" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_new" ] && [ "$line_new" -lt "$line_a" ] && [ "$line_a" -lt "$line_b" ]; then
        echo "  PASS: block [new, A, B] moved together after old"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, new=$line_new, a=$line_a, b=$line_b)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Idempotency ---

test_idempotency() {
    echo "Test: sorting twice produces same result"
    local f="$TMPDIR_BASE/idempotent.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new

### Dateless
Background: no hash

### Old feature ($HASH_OLD)
Background: old
EOF
    local result1 result2
    result1=$(run_sort "$f" --repo "$TEST_REPO")
    local f2="$TMPDIR_BASE/idempotent2.md"
    echo "$result1" > "$f2"
    result2=$(run_sort "$f2" --repo "$TEST_REPO")
    assert_eq "idempotent" "$result1" "$result2"
}

# --- Edge cases ---

test_no_repo() {
    echo "Test: no git repo — entries unchanged (no date resolution)"
    local f="$TMPDIR_BASE/no-repo.md"
    cat > "$f" <<EOF
# History

## Changes

### Feature B ($HASH_NEW)
Background: b

### Feature A ($HASH_OLD)
Background: a
EOF
    local result
    result=$(run_sort "$f" --repo "/nonexistent/path")
    local expected
    expected=$(cat "$f")
    assert_eq "no repo, no change" "$expected" "$result"
}

test_unresolvable_hash() {
    echo "Test: unresolvable hash treated as dateless"
    local f="$TMPDIR_BASE/bad-hash.md"
    cat > "$f" <<EOF
# History

## Changes

### Bad hash feature (deadbeef)
Background: hash doesn't exist

### Old feature ($HASH_OLD)
Background: old

### New feature ($HASH_NEW)
Background: new
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # deadbeef is unresolvable → floating block at end
    local line_old line_new line_bad
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    line_bad=$(echo "$result" | grep -n "Bad hash feature" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_new" ] && [ "$line_new" -lt "$line_bad" ]; then
        echo "  PASS: unresolvable hash at end"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, new=$line_new, bad=$line_bad)"
        FAIL=$((FAIL + 1))
    fi
}

test_file_not_found() {
    echo "Test: file not found → exit code 1 + stderr"
    local result exit_code stderr_out
    stderr_out=$($SORT_CMD "$TMPDIR_BASE/nonexistent.md" 2>&1 1>/dev/null) || exit_code=$?
    if [ "${exit_code:-0}" -eq 1 ] && echo "$stderr_out" | grep -qi "not found"; then
        echo "  PASS: exit 1 with error message"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=${exit_code:-0}, stderr=$stderr_out"
        FAIL=$((FAIL + 1))
    fi
}

test_empty_file() {
    echo "Test: empty file → empty output"
    local f="$TMPDIR_BASE/empty.md"
    : > "$f"
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    if [ -z "$result" ]; then
        echo "  PASS: empty output"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: got non-empty output: '$result'"
        FAIL=$((FAIL + 1))
    fi
}

test_all_dateless() {
    echo "Test: all entries dateless — order preserved (single floating block)"
    local f="$TMPDIR_BASE/all-dateless.md"
    cat > "$f" <<EOF
# History

## Changes

### Feature A (uncommitted)
Background: a

### Feature B
Background: b

### Feature C ((pending))
Background: c
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_a line_b line_c
    line_a=$(echo "$result" | grep -n "Feature A" | head -1 | cut -d: -f1)
    line_b=$(echo "$result" | grep -n "Feature B" | head -1 | cut -d: -f1)
    line_c=$(echo "$result" | grep -n "Feature C" | head -1 | cut -d: -f1)
    if [ "$line_a" -lt "$line_b" ] && [ "$line_b" -lt "$line_c" ]; then
        echo "  PASS: original order preserved"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (a=$line_a, b=$line_b, c=$line_c)"
        FAIL=$((FAIL + 1))
    fi
}

test_crlf_input() {
    echo "Test: CRLF input normalized to LF"
    local f="$TMPDIR_BASE/crlf.md"
    printf "# History\r\n\r\n## Changes\r\n\r\n### New ($HASH_NEW)\r\nBackground: new\r\n\r\n### Old ($HASH_OLD)\r\nBackground: old\r\n" > "$f"
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # Verify no CR in output
    if echo "$result" | grep -qP '\r'; then
        echo "  FAIL: output contains CR"
        FAIL=$((FAIL + 1))
        return
    fi
    # Verify sorted ascending
    local line_old line_new
    line_old=$(echo "$result" | grep -n "### Old" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "### New" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_new" ]; then
        echo "  PASS: CRLF normalized, sorted ascending"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, new=$line_new)"
        FAIL=$((FAIL + 1))
    fi
}

test_body_with_blank_lines() {
    echo "Test: entry body with blank lines stays intact"
    local f="$TMPDIR_BASE/blank-body.md"
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new feature
Changes:
  - Added foo

  - Fixed bar (after blank line)

Alternatives considered:
  (a) Option A
  (b) Option B

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    # "after blank line" should still follow "New feature", not split into separate entry
    local line_new line_blank_body line_old
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    line_blank_body=$(echo "$result" | grep -n "after blank line" | head -1 | cut -d: -f1)
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_new" ] && [ "$line_new" -lt "$line_blank_body" ]; then
        echo "  PASS: blank-line body preserved with entry"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, new=$line_new, blank_body=$line_blank_body)"
        FAIL=$((FAIL + 1))
    fi
}

test_same_hash_stable_sort() {
    echo "Test: entries with same hash preserve original order (stable sort)"
    local f="$TMPDIR_BASE/same-hash.md"
    cat > "$f" <<EOF
# History

## Changes

### Newest feature ($HASH_NEWEST)
Background: newest

### Entry A ($HASH_MID)
Background: a

### Entry B ($HASH_MID)
Background: b

### Entry C ($HASH_MID)
Background: c

### Old feature ($HASH_OLD)
Background: old
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_old line_a line_b line_c line_newest
    line_old=$(echo "$result" | grep -n "Old feature" | head -1 | cut -d: -f1)
    line_a=$(echo "$result" | grep -n "Entry A" | head -1 | cut -d: -f1)
    line_b=$(echo "$result" | grep -n "Entry B" | head -1 | cut -d: -f1)
    line_c=$(echo "$result" | grep -n "Entry C" | head -1 | cut -d: -f1)
    line_newest=$(echo "$result" | grep -n "Newest feature" | head -1 | cut -d: -f1)
    if [ "$line_old" -lt "$line_a" ] && [ "$line_a" -lt "$line_b" ] && [ "$line_b" -lt "$line_c" ] && [ "$line_c" -lt "$line_newest" ]; then
        echo "  PASS: same-hash entries in original order"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (old=$line_old, a=$line_a, b=$line_b, c=$line_c, newest=$line_newest)"
        FAIL=$((FAIL + 1))
    fi
}

test_hash_range() {
    echo "Test: hash range (hash1-hash2) resolves first hash"
    local f="$TMPDIR_BASE/range.md"
    # Use en-dash like the real file
    cat > "$f" <<EOF
# History

## Changes

### New feature ($HASH_NEW)
Background: new

### Range feature (${HASH_OLD}–${HASH_MID})
Background: range
EOF
    local result
    result=$(run_sort "$f" --repo "$TEST_REPO")
    local line_range line_new
    line_range=$(echo "$result" | grep -n "Range feature" | head -1 | cut -d: -f1)
    line_new=$(echo "$result" | grep -n "New feature" | head -1 | cut -d: -f1)
    if [ "$line_range" -lt "$line_new" ]; then
        echo "  PASS: range resolved to earliest (old before new)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: (range=$line_range, new=$line_new)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Run all tests ---

main() {
    setup

    echo "=== Normal cases ==="
    test_already_ascending
    test_descending_to_ascending
    test_anchor_block_dateless_attached
    test_floating_block_at_end
    test_multiple_sections_independent
    test_pending_entries
    test_hash_plus_pending
    test_empty_paren
    test_single_entry
    test_no_entries
    test_dry_run_shows_diff
    test_multiline_body_preserved
    test_block_with_multiple_dateless

    echo ""
    echo "=== Idempotency ==="
    test_idempotency

    echo ""
    echo "=== Error cases ==="
    test_file_not_found

    echo ""
    echo "=== Edge cases ==="
    test_empty_file
    test_all_dateless
    test_crlf_input
    test_body_with_blank_lines
    test_same_hash_stable_sort
    test_no_repo
    test_unresolvable_hash
    test_hash_range

    echo ""
    echo "=== Results ==="
    echo "  PASS: $PASS"
    echo "  FAIL: $FAIL"
    [ "$FAIL" -eq 0 ]
}

main
