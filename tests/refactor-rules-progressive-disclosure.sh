#!/usr/bin/env bash
# tests/refactor-rules-progressive-disclosure.sh
#
# Tests for refactor/rules-progressive-disclosure:
#   - globs: frontmatter validity in new sub-files
#   - No remaining paths: frontmatter
#   - Section heading coverage (primary content assertion)
#   - Verbatim always-load sentences in thin pointers
#   - Thin-pointer link validity
#   - Char-count sanity (sub-files >= 95% of original)
#   - Memory index consistency
#   - Memory merge check (new file exists, old files deleted)
#
# These tests validate POST-IMPLEMENTATION state.
# Tests that reference .bak files or sub-files not yet created will SKIP or FAIL
# appropriately — that is expected behavior before implementation is complete.

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMORY_DIR="$HOME/.claude/projects/c--git-agents/memory"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1: ${2:-}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1: ${2:-}"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Helper: extract YAML frontmatter block (between first --- and second ---)
# Prints lines between the delimiters (exclusive)
# ---------------------------------------------------------------------------
extract_frontmatter() {
    local file="$1"
    awk 'NR==1 && /^---/{in_fm=1; next} in_fm && /^---/{exit} in_fm{print}' "$file"
}

# ---------------------------------------------------------------------------
# Helper: check a file has valid globs: frontmatter
# Returns 0 (success) and prints nothing if valid.
# Returns 1 and prints reason if invalid.
# ---------------------------------------------------------------------------
check_globs_frontmatter() {
    local file="$1"

    # (a) file starts with ---
    local first_line
    first_line="$(head -1 "$file" 2>/dev/null)"
    if [[ "$first_line" != "---" ]]; then
        echo "does not start with ---"
        return 1
    fi

    # (b) contains globs: key in frontmatter
    local fm
    fm="$(extract_frontmatter "$file")"
    if ! echo "$fm" | grep -q "^globs:"; then
        echo "no globs: key in frontmatter"
        return 1
    fi

    # (c) globs: value is a quoted string (not a YAML list)
    local globs_line
    globs_line="$(echo "$fm" | grep "^globs:")"
    # Must match: globs: "..." — value starts with a quote
    if ! echo "$globs_line" | grep -qE '^globs:[[:space:]]+"'; then
        echo "globs: value is not a quoted string (got: $globs_line)"
        return 1
    fi
    # Must NOT be followed by a YAML list item on the next line
    local next_line
    next_line="$(echo "$fm" | awk '/^globs:/{found=1; next} found{print; exit}')"
    if echo "$next_line" | grep -qE '^[[:space:]]*-[[:space:]]'; then
        echo "globs: appears to be a YAML list (found list item: $next_line)"
        return 1
    fi

    # (d) globs: value does not contain .. or backslash
    if echo "$globs_line" | grep -qE '\.\.|\\'; then
        echo "globs: value contains .. or backslash: $globs_line"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Helper: count chars in a file
# ---------------------------------------------------------------------------
file_charcount() {
    wc -c < "$1" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Helper: extract ## and ### headings from a markdown file (heading text only)
# ---------------------------------------------------------------------------
extract_headings() {
    local file="$1"
    grep -E '^#{2,3} ' "$file" | sed 's/^#\+[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# Test 1 — globs: frontmatter validity
# ---------------------------------------------------------------------------
echo "=== Test 1: globs: frontmatter validity ==="

GLOBS_FILES=(
    "rules/test/categories.md"
    "rules/test/naming.md"
    "rules/test/layers.md"
    "rules/docs-convention/history.md"
    "rules/docs-convention/todo.md"
    "rules/docs-convention/changelog.md"
    "rules/docs-convention/architecture.md"
    "rules/docs-convention/readme.md"
    "rules/docs-convention/env-example.md"
    "rules/coding/python.md"
    "rules/coding/nodejs.md"
    "rules/test-rules/installer.md"
    "rules/test-rules/macos-timeout.md"
    "rules/test-rules/claude-e2e.md"
    "rules/claude-config-source.md"
)

for rel in "${GLOBS_FILES[@]}"; do
    abs="$REPO_ROOT/$rel"
    if [ ! -f "$abs" ]; then
        fail "T1: $rel" "file not found"
        continue
    fi
    reason="$(check_globs_frontmatter "$abs")"
    if [ $? -eq 0 ]; then
        pass "T1: $rel — valid globs: frontmatter"
    else
        fail "T1: $rel" "$reason"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# Test 2 — No remaining paths: frontmatter under rules/
# ---------------------------------------------------------------------------
echo "=== Test 2: No paths: frontmatter under rules/ ==="

# Find files under rules/ that have paths: in their frontmatter
found_paths_fm=0
while IFS= read -r -d '' f; do
    # Extract frontmatter and check for paths: key
    fm="$(extract_frontmatter "$f")"
    if echo "$fm" | grep -qE '^paths:'; then
        fail "T2: paths: frontmatter found in $f"
        found_paths_fm=1
    fi
done < <(find "$REPO_ROOT/rules" -name "*.md" -print0 2>/dev/null)

if [ "$found_paths_fm" -eq 0 ]; then
    pass "T2: No paths: frontmatter found in any rules/ file"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 3 — Section heading coverage
# ---------------------------------------------------------------------------
echo "=== Test 3: Section heading coverage ==="

test_heading_coverage() {
    local bak_file="$1"
    local test_name="$2"
    shift 2
    local target_files=("$@")

    if [ ! -f "$bak_file" ]; then
        skip "T3: $test_name" ".bak file not yet created (run after implementation)"
        return
    fi

    local all_exist=1
    for f in "${target_files[@]}"; do
        if [ ! -f "$f" ]; then
            all_exist=0
            break
        fi
    done

    if [ "$all_exist" -eq 0 ]; then
        fail "T3: $test_name" "one or more target files not found"
        return
    fi

    local any_fail=0
    while IFS= read -r heading; do
        [ -z "$heading" ] && continue
        local count=0
        for f in "${target_files[@]}"; do
            if grep -qF "$heading" "$f" 2>/dev/null; then
                count=$((count + 1))
            fi
        done
        if [ "$count" -eq 0 ]; then
            fail "T3: $test_name" "heading '$heading' not found in any target file (content loss)"
            any_fail=1
        elif [ "$count" -gt 1 ]; then
            fail "T3: $test_name" "heading '$heading' found in $count files (duplication)"
            any_fail=1
        fi
    done < <(extract_headings "$bak_file")

    if [ "$any_fail" -eq 0 ]; then
        pass "T3: $test_name — all headings covered exactly once"
    fi
}

# test.md group
test_heading_coverage \
    "$REPO_ROOT/rules/test.md.bak" \
    "rules/test.md headings" \
    "$REPO_ROOT/rules/test.md" \
    "$REPO_ROOT/rules/test/categories.md" \
    "$REPO_ROOT/rules/test/naming.md" \
    "$REPO_ROOT/rules/test/layers.md"

# docs-convention.md group
test_heading_coverage \
    "$REPO_ROOT/rules/docs-convention.md.bak" \
    "rules/docs-convention.md headings" \
    "$REPO_ROOT/rules/docs-convention.md" \
    "$REPO_ROOT/rules/docs-convention/history.md" \
    "$REPO_ROOT/rules/docs-convention/todo.md" \
    "$REPO_ROOT/rules/docs-convention/changelog.md" \
    "$REPO_ROOT/rules/docs-convention/architecture.md" \
    "$REPO_ROOT/rules/docs-convention/readme.md" \
    "$REPO_ROOT/rules/docs-convention/env-example.md"

# coding.md group
test_heading_coverage \
    "$REPO_ROOT/rules/coding.md.bak" \
    "rules/coding.md headings" \
    "$REPO_ROOT/rules/coding.md" \
    "$REPO_ROOT/rules/coding/python.md" \
    "$REPO_ROOT/rules/coding/nodejs.md"

echo ""

# ---------------------------------------------------------------------------
# Test 4 — Verbatim always-load sentences in rules/test.md
# ---------------------------------------------------------------------------
echo "=== Test 4: Verbatim always-load sentences in rules/test.md ==="

TEST_MD="$REPO_ROOT/rules/test.md"

check_sentence() {
    local file="$1"
    local sentence="$2"
    local label="$3"
    if [ ! -f "$file" ]; then
        fail "T4: $label" "file not found: $file"
        return
    fi
    if grep -qF "$sentence" "$file"; then
        pass "T4: $label"
    else
        fail "T4: $label" "sentence not found: $sentence"
    fi
}

check_sentence "$TEST_MD" \
    "Do not write or edit test files directly in the main conversation." \
    "always-load sentence: test files in main conversation"

check_sentence "$TEST_MD" \
    'After writing test code, run `/review-tests` to verify test case completeness before committing.' \
    "always-load sentence: /review-tests"

check_sentence "$TEST_MD" \
    "Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow." \
    "always-load sentence: 120 seconds timeout"

echo ""

# ---------------------------------------------------------------------------
# Test 5 — Thin-pointer link validity
# ---------------------------------------------------------------------------
echo "=== Test 5: Thin-pointer link validity ==="

check_links_in_file() {
    local file="$1"
    local label="$2"

    if [ ! -f "$file" ]; then
        fail "T5: $label" "file not found: $file"
        return
    fi

    local file_dir
    file_dir="$(dirname "$file")"
    local any_fail=0

    # Extract markdown links: [text](path) — only relative paths (no http)
    while IFS= read -r link_path; do
        [ -z "$link_path" ] && continue
        # Skip absolute URLs
        if echo "$link_path" | grep -qE '^https?://'; then
            continue
        fi
        # Skip anchor-only links
        if echo "$link_path" | grep -qE '^#'; then
            continue
        fi
        # Strip any trailing anchor (#section)
        link_path="${link_path%%#*}"
        [ -z "$link_path" ] && continue

        local abs_target="$file_dir/$link_path"
        if [ ! -f "$abs_target" ]; then
            fail "T5: $label" "linked file not found: $link_path (from $file)"
            any_fail=1
        fi
    done < <(grep -oE '\[([^]]*)\]\(([^)]*)\)' "$file" | sed 's/.*(\(.*\))/\1/')

    if [ "$any_fail" -eq 0 ]; then
        pass "T5: $label — all links valid"
    fi
}

check_links_in_file "$REPO_ROOT/rules/test.md" "rules/test.md links"
check_links_in_file "$REPO_ROOT/rules/docs-convention.md" "rules/docs-convention.md links"
check_links_in_file "$REPO_ROOT/rules/coding.md" "rules/coding.md links"

echo ""

# ---------------------------------------------------------------------------
# Test 6 — Char-count sanity (sub-files >= 95% of original .bak)
# ---------------------------------------------------------------------------
echo "=== Test 6: Char-count sanity ==="

check_charcount() {
    local bak_file="$1"
    local test_name="$2"
    shift 2
    local sub_files=("$@")

    if [ ! -f "$bak_file" ]; then
        skip "T6: $test_name" ".bak file not yet created (run after implementation)"
        return
    fi

    local missing=0
    for f in "${sub_files[@]}"; do
        if [ ! -f "$f" ]; then
            missing=1
            break
        fi
    done
    if [ "$missing" -eq 1 ]; then
        fail "T6: $test_name" "one or more sub-files not found"
        return
    fi

    local bak_count
    bak_count="$(file_charcount "$bak_file")"

    local sub_total=0
    for f in "${sub_files[@]}"; do
        local c
        c="$(file_charcount "$f")"
        sub_total=$((sub_total + c))
    done

    # floor = ceil(bak_count * 95 / 100)
    local threshold=$(( (bak_count * 95 + 99) / 100 ))

    if [ "$sub_total" -ge "$threshold" ]; then
        pass "T6: $test_name — sub-files total $sub_total chars >= ${threshold} (95% of $bak_count)"
    else
        fail "T6: $test_name" "sub-files total $sub_total chars < $threshold (95% of $bak_count bak chars)"
    fi
}

check_charcount \
    "$REPO_ROOT/rules/test.md.bak" \
    "rules/test.md char-count" \
    "$REPO_ROOT/rules/test/categories.md" \
    "$REPO_ROOT/rules/test/naming.md" \
    "$REPO_ROOT/rules/test/layers.md"

check_charcount \
    "$REPO_ROOT/rules/docs-convention.md.bak" \
    "rules/docs-convention.md char-count" \
    "$REPO_ROOT/rules/docs-convention/history.md" \
    "$REPO_ROOT/rules/docs-convention/todo.md" \
    "$REPO_ROOT/rules/docs-convention/changelog.md" \
    "$REPO_ROOT/rules/docs-convention/architecture.md" \
    "$REPO_ROOT/rules/docs-convention/readme.md" \
    "$REPO_ROOT/rules/docs-convention/env-example.md"

check_charcount \
    "$REPO_ROOT/rules/coding.md.bak" \
    "rules/coding.md char-count" \
    "$REPO_ROOT/rules/coding/python.md" \
    "$REPO_ROOT/rules/coding/nodejs.md"

echo ""

# ---------------------------------------------------------------------------
# Test 7 — Memory index consistency
# ---------------------------------------------------------------------------
echo "=== Test 7: Memory index consistency ==="

MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"

if [ ! -f "$MEMORY_INDEX" ]; then
    fail "T7: MEMORY.md exists" "file not found: $MEMORY_INDEX"
else
    pass "T7: MEMORY.md exists"

    # Every feedback_*.md / project_*.md in the directory is referenced in MEMORY.md
    any_fail=0
    while IFS= read -r -d '' memfile; do
        fname="$(basename "$memfile")"
        if ! grep -qF "$fname" "$MEMORY_INDEX"; then
            fail "T7: memory file '$fname' referenced in MEMORY.md" "not referenced"
            any_fail=1
        fi
    done < <(find "$MEMORY_DIR" -maxdepth 1 \( -name "feedback_*.md" -o -name "project_*.md" \) -print0 2>/dev/null)

    if [ "$any_fail" -eq 0 ]; then
        pass "T7: all memory files referenced in MEMORY.md"
    fi

    # Every file referenced in MEMORY.md exists on disk
    any_fail=0
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        abs="$MEMORY_DIR/$ref"
        if [ ! -f "$abs" ]; then
            fail "T7: MEMORY.md reference '$ref' exists on disk" "file not found"
            any_fail=1
        fi
    done < <(grep -oE '\(([^)]+\.md)\)' "$MEMORY_INDEX" | sed 's/[()]//g' | grep -vE '^https?://')

    if [ "$any_fail" -eq 0 ]; then
        pass "T7: all MEMORY.md references exist on disk"
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# Test 8 — Memory merge check
# ---------------------------------------------------------------------------
echo "=== Test 8: Memory merge check ==="

NEW_FILE="$MEMORY_DIR/feedback_third_party_references.md"
DELETED_1="$MEMORY_DIR/feedback_deep_research_source_quality.md"
DELETED_2="$MEMORY_DIR/feedback_neutral_tone_for_third_parties.md"

# New merged file must exist
if [ -f "$NEW_FILE" ]; then
    pass "T8: feedback_third_party_references.md exists (merged file)"
else
    fail "T8: feedback_third_party_references.md exists (merged file)" "file not found"
fi

# Old files must not exist
if [ ! -f "$DELETED_1" ]; then
    pass "T8: feedback_deep_research_source_quality.md deleted"
else
    fail "T8: feedback_deep_research_source_quality.md deleted" "file still exists"
fi

if [ ! -f "$DELETED_2" ]; then
    pass "T8: feedback_neutral_tone_for_third_parties.md deleted"
else
    fail "T8: feedback_neutral_tone_for_third_parties.md deleted" "file still exists"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
