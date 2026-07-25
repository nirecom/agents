#!/usr/bin/env bash
# Tests: skills/_shared/test-design.md
# Tags: memory, index, scope:common
# Part of tests/refactor-rules-progressive-disclosure.sh — sourced, not run directly.
# Test 7: memory index consistency
# Test 8: memory merge check

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
