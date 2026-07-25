#!/usr/bin/env bash
# Tests: rules/test.md, rules/docs.md, rules/coding.md, skills/_shared/test-design.md
# Tags: rules, content-parity, scope:common
# Part of tests/refactor-rules-progressive-disclosure.sh — sourced, not run directly.
# Test 3: section heading coverage
# Test 4: verbatim always-load sentences in rules/test.md
# Test 5: thin-pointer link validity
# Test 6: char-count sanity (sub-files >= 95% of original .bak)

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
    "$REPO_ROOT/skills/_shared/test-design.md"

# docs-convention.md group
if [ "$RENAME_DONE" = "true" ]; then
    test_heading_coverage \
        "$REPO_ROOT/rules/docs.md.bak" \
        "rules/docs.md headings" \
        "$REPO_ROOT/rules/docs.md" \
        "$REPO_ROOT/rules/docs/history.md" \
        "$REPO_ROOT/rules/docs/todo.md" \
        "$REPO_ROOT/rules/docs/changelog.md" \
        "$REPO_ROOT/rules/docs/architecture.md" \
        "$REPO_ROOT/rules/docs/readme.md" \
        "$REPO_ROOT/rules/docs/env-example.md"
else
    skip "T3: rules/docs.md headings" "run after rules/ rename implementation"
fi

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
if [ "$RENAME_DONE" = "true" ]; then
    check_links_in_file "$REPO_ROOT/rules/docs.md" "rules/docs.md links"
else
    skip "T5: rules/docs.md links" "run after rules/ rename implementation"
fi
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
    "$REPO_ROOT/rules/test.md" \
    "$REPO_ROOT/skills/_shared/test-design.md"

if [ "$RENAME_DONE" = "true" ]; then
    check_charcount \
        "$REPO_ROOT/rules/docs.md.bak" \
        "rules/docs.md char-count" \
        "$REPO_ROOT/rules/docs.md" \
        "$REPO_ROOT/rules/docs/history.md" \
        "$REPO_ROOT/rules/docs/todo.md" \
        "$REPO_ROOT/rules/docs/changelog.md" \
        "$REPO_ROOT/rules/docs/architecture.md" \
        "$REPO_ROOT/rules/docs/readme.md" \
        "$REPO_ROOT/rules/docs/env-example.md"
else
    skip "T6: rules/docs.md char-count" "run after rules/ rename implementation"
fi

check_charcount \
    "$REPO_ROOT/rules/coding.md.bak" \
    "rules/coding.md char-count" \
    "$REPO_ROOT/rules/coding.md" \
    "$REPO_ROOT/rules/coding/python.md" \
    "$REPO_ROOT/rules/coding/nodejs.md"

echo ""
