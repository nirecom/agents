#!/usr/bin/env bash
# Tests for bin/translate-history.py
# Naming: main direct work → tests/main-<name>.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRANSLATE_CMD="uv run python $REPO_DIR/bin/translate-history.py"

PASS=0
FAIL=0
TMPDIR_BASE=""

setup() {
    TMPDIR_BASE=$(mktemp -d)
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

run_extract() {
    local input_file="$1"
    shift
    local manifest_out="$TMPDIR_BASE/_extract_out.json"
    rm -f "$manifest_out"
    PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$input_file" --extract -t "$manifest_out" --public "$@" 2>/dev/null || true
    if [ -f "$manifest_out" ]; then
        cat "$manifest_out"
    else
        echo "[]"
    fi
}

run_apply() {
    local input_file="$1"
    local manifest="$2"
    shift 2
    PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$input_file" --apply -t "$manifest" --public "$@" 2>/dev/null
}

# --- Normal cases ---

test_extract_finds_japanese() {
    echo "Test: extract finds Japanese entries, excludes English"
    local f="$TMPDIR_BASE/mixed.md"
    cat > "$f" <<'EOF'
# History

## Changes

### English feature (2024-01-01, abc1234)
Background: Added new feature
Changes: something

### 日本語の機能 (2024-02-01, def5678)
Background: 新しい機能を追加
Changes: 変更内容

### Another English (2024-03-01, ghi9012)
Background: Fixed bug
EOF
    local result
    result=$(run_extract "$f")
    # Should contain the Japanese entry
    if echo "$result" | grep -q "日本語の機能"; then
        echo "  PASS: Japanese entry found"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: Japanese entry not found in output"
        FAIL=$((FAIL + 1))
        return
    fi
    # Should NOT contain English-only entries
    if echo "$result" | grep -q "English feature"; then
        echo "  FAIL: English-only entry should not be in output"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: English entries excluded"
        PASS=$((PASS + 1))
    fi
}

test_extract_empty_when_no_japanese() {
    echo "Test: extract returns empty array when no Japanese"
    local f="$TMPDIR_BASE/english-only.md"
    cat > "$f" <<'EOF'
# History

## Changes

### Feature A (2024-01-01, abc1234)
Background: Added A
Changes: something

### Feature B (2024-02-01, def5678)
Background: Fixed B
EOF
    local result
    result=$(run_extract "$f")
    assert_eq "empty JSON array" "[]" "$result"
}

test_roundtrip_apply() {
    echo "Test: extract → fill translations → apply → JP gone, EN preserved"
    local f="$TMPDIR_BASE/roundtrip.md"
    cat > "$f" <<'EOF'
# History

## Changes

### English feature (2024-01-01, abc1234)
Background: Added new feature

### 日本語の機能 (2024-02-01, def5678)
Background: 新しい機能を追加
Changes: 変更内容
EOF
    # Create a manifest with translations filled in
    local manifest="$TMPDIR_BASE/translations.json"
    cat > "$manifest" <<'EOF'
[
  {
    "title": "### 日本語の機能 (2024-02-01, def5678)",
    "original": "### 日本語の機能 (2024-02-01, def5678)\nBackground: 新しい機能を追加\nChanges: 変更内容",
    "translated": "### Japanese feature (2024-02-01, def5678)\nBackground: Added new feature\nChanges: Changes made"
  }
]
EOF
    local result
    result=$(run_apply "$f" "$manifest")
    # JP should be gone
    if echo "$result" | grep -q "日本語"; then
        echo "  FAIL: Japanese text still present"
        FAIL=$((FAIL + 1))
        return
    fi
    echo "  PASS: Japanese text removed"
    PASS=$((PASS + 1))
    # EN should be preserved
    if echo "$result" | grep -q "English feature"; then
        echo "  PASS: English entry preserved"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: English entry missing"
        FAIL=$((FAIL + 1))
    fi
}

test_apply_preserves_structure() {
    echo "Test: apply preserves non-JP entries and headers"
    local f="$TMPDIR_BASE/structure.md"
    cat > "$f" <<'EOF'
# History

## Changes

### English feature (2024-01-01)
Background: english

### 日本語 (2024-02-01)
Background: japanese

### Another English (2024-03-01)
Background: also english
EOF
    local manifest="$TMPDIR_BASE/struct-manifest.json"
    cat > "$manifest" <<'EOF'
[
  {
    "title": "### 日本語 (2024-02-01)",
    "original": "### 日本語 (2024-02-01)\nBackground: japanese",
    "translated": "### Translated (2024-02-01)\nBackground: translated"
  }
]
EOF
    local result
    result=$(run_apply "$f" "$manifest")
    # Check headers present
    if echo "$result" | grep -q "# History" && echo "$result" | grep -q "## Changes"; then
        echo "  PASS: headers preserved"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: headers missing"
        FAIL=$((FAIL + 1))
    fi
    # Check order: English, Translated, Another English
    local line1 line2 line3
    line1=$(echo "$result" | grep -n "English feature" | head -1 | cut -d: -f1)
    line2=$(echo "$result" | grep -n "Translated" | head -1 | cut -d: -f1)
    line3=$(echo "$result" | grep -n "Another English" | head -1 | cut -d: -f1)
    if [ "$line1" -lt "$line2" ] && [ "$line2" -lt "$line3" ]; then
        echo "  PASS: entry order preserved"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: order wrong (l1=$line1, l2=$line2, l3=$line3)"
        FAIL=$((FAIL + 1))
    fi
}

test_dry_run_shows_diff() {
    echo "Test: --apply --dry-run shows unified diff header"
    local f="$TMPDIR_BASE/dryrun.md"
    cat > "$f" <<'EOF'
# History

## Changes

### 日本語 (2024-01-01)
Background: japanese
EOF
    local manifest="$TMPDIR_BASE/dryrun-manifest.json"
    cat > "$manifest" <<'EOF'
[
  {
    "title": "### 日本語 (2024-01-01)",
    "original": "### 日本語 (2024-01-01)\nBackground: japanese",
    "translated": "### English (2024-01-01)\nBackground: english"
  }
]
EOF
    local result
    result=$(run_apply "$f" "$manifest" --dry-run)
    if echo "$result" | grep -q "^---"; then
        echo "  PASS: dry-run shows diff header"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: no diff header in output"
        echo "  output: $result"
        FAIL=$((FAIL + 1))
    fi
}

# --- Default path cases ---

test_default_manifest_path_save() {
    echo "Test: --extract saves to <file>.translate.json by default"
    local f="$TMPDIR_BASE/default-path.md"
    cat > "$f" <<'EOF'
# History

## Changes

### 日本語エントリ (2024-01-01)
Background: テスト
EOF
    local expected_manifest="${f%.md}.translate.json"
    rm -f "$expected_manifest"
    PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --extract --public 2>/dev/null
    if [ -f "$expected_manifest" ]; then
        echo "  PASS: manifest written to default path"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: manifest not found at $expected_manifest"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$expected_manifest"
}

test_default_manifest_path_apply() {
    echo "Test: --apply reads from <file>.translate.json by default"
    local f="$TMPDIR_BASE/default-apply.md"
    cat > "$f" <<'EOF'
# History

## Changes

### 日本語 (2024-01-01)
Background: テスト
EOF
    local manifest="${f%.md}.translate.json"
    cat > "$manifest" <<'EOF'
[
  {
    "title": "### 日本語 (2024-01-01)",
    "original": "### 日本語 (2024-01-01)\nBackground: テスト\n",
    "translated": "### English (2024-01-01)\nBackground: test\n"
  }
]
EOF
    local result
    result=$(PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --apply --public 2>/dev/null)
    rm -f "$manifest"
    if echo "$result" | grep -q "English"; then
        echo "  PASS: --apply reads default manifest path"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: --apply did not read default manifest"
        echo "  output: $result"
        FAIL=$((FAIL + 1))
    fi
}

test_missing_default_manifest_error() {
    echo "Test: --apply without -t and no default manifest → exit 1"
    local f="$TMPDIR_BASE/no-default-manifest.md"
    echo "# History" > "$f"
    local manifest="${f%.md}.translate.json"
    rm -f "$manifest"
    local exit_code=0 stderr_out
    stderr_out=$(PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --apply --public 2>&1 1>/dev/null) || exit_code=$?
    if [ "$exit_code" -eq 1 ] && echo "$stderr_out" | grep -qi "not found"; then
        echo "  PASS: exit 1 with error on missing default manifest"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=$exit_code, stderr=$stderr_out"
        FAIL=$((FAIL + 1))
    fi
}

# --- Error cases ---

test_file_not_found() {
    echo "Test: file not found → exit 1 + stderr"
    local stderr_out exit_code=0
    stderr_out=$(PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$TMPDIR_BASE/nonexistent.md" --extract --public 2>&1 1>/dev/null) || exit_code=$?
    if [ "$exit_code" -eq 1 ] && echo "$stderr_out" | grep -qi "not found"; then
        echo "  PASS: exit 1 with error message"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=$exit_code, stderr=$stderr_out"
        FAIL=$((FAIL + 1))
    fi
}

test_no_mode_flag() {
    echo "Test: no --extract or --apply → non-zero exit"
    local f="$TMPDIR_BASE/nomode.md"
    echo "# History" > "$f"
    local exit_code=0
    PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --public >/dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "  PASS: non-zero exit without mode flag"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=$exit_code (expected non-zero)"
        FAIL=$((FAIL + 1))
    fi
}


test_manifest_file_not_found() {
    echo "Test: --apply with nonexistent manifest → exit 1"
    local f="$TMPDIR_BASE/mf-notfound.md"
    echo "# History" > "$f"
    local exit_code=0 stderr_out
    stderr_out=$(PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --apply -t /nonexistent/path.json --public 2>&1 1>/dev/null) || exit_code=$?
    if [ "$exit_code" -eq 1 ] && echo "$stderr_out" | grep -qi "not found"; then
        echo "  PASS: exit 1 with error"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=$exit_code, stderr=$stderr_out"
        FAIL=$((FAIL + 1))
    fi
}

test_invalid_json_manifest() {
    echo "Test: invalid JSON manifest → non-zero exit"
    local f="$TMPDIR_BASE/invalid-json.md"
    echo "# History" > "$f"
    local manifest="$TMPDIR_BASE/broken.json"
    echo '{broken' > "$manifest"
    local exit_code=0
    PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --apply -t "$manifest" --public >/dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "  PASS: non-zero exit on invalid JSON"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=$exit_code (expected non-zero)"
        FAIL=$((FAIL + 1))
    fi
}

test_manifest_original_not_found() {
    echo "Test: manifest original doesn't match → warns, file unchanged"
    local f="$TMPDIR_BASE/nomatch.md"
    cat > "$f" <<'EOF'
# History

## Changes

### English feature (2024-01-01)
Background: english
EOF
    local manifest="$TMPDIR_BASE/nomatch-manifest.json"
    cat > "$manifest" <<'EOF'
[
  {
    "title": "### Nonexistent entry",
    "original": "### Nonexistent entry\nBackground: does not exist",
    "translated": "### Translated\nBackground: translated"
  }
]
EOF
    local result stderr_out
    result=$(PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --apply -t "$manifest" --public 2>"$TMPDIR_BASE/nomatch-stderr.txt")
    stderr_out=$(cat "$TMPDIR_BASE/nomatch-stderr.txt")
    # stderr should contain warning
    if echo "$stderr_out" | grep -qi "warning\|not found\|skipping"; then
        echo "  PASS: warning on stderr"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: no warning on stderr: $stderr_out"
        FAIL=$((FAIL + 1))
    fi
    # Output should be unchanged
    local expected
    expected=$(cat "$f")
    assert_eq "file unchanged" "$expected" "$result"
}

# --- Edge cases ---

test_mixed_jp_en_entry() {
    echo "Test: entry with both JP and EN text is detected"
    local f="$TMPDIR_BASE/mixed-entry.md"
    cat > "$f" <<'EOF'
# History

## Changes

### Feature setup (2024-01-01)
Background: Added 日本語 support
EOF
    local result
    result=$(run_extract "$f")
    if echo "$result" | grep -q "Feature setup"; then
        echo "  PASS: mixed JP/EN entry detected"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: mixed entry not detected"
        FAIL=$((FAIL + 1))
    fi
}

test_katakana_only() {
    echo "Test: entry with only Katakana is detected"
    local f="$TMPDIR_BASE/katakana.md"
    cat > "$f" <<'EOF'
# History

## Changes

### テスト (2024-01-01)
Background: テスト
EOF
    local result
    result=$(run_extract "$f")
    if echo "$result" | grep -q "テスト"; then
        echo "  PASS: Katakana-only entry detected"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: Katakana entry not detected"
        FAIL=$((FAIL + 1))
    fi
}

test_crlf_input() {
    echo "Test: CRLF input handled correctly"
    local f="$TMPDIR_BASE/crlf.md"
    printf "# History\r\n\r\n## Changes\r\n\r\n### 日本語 (2024-01-01)\r\nBackground: テスト\r\n\r\n### English (2024-02-01)\r\nBackground: test\r\n" > "$f"
    local result
    result=$(run_extract "$f")
    if echo "$result" | grep -q "日本語"; then
        echo "  PASS: CRLF input handled, Japanese detected"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: CRLF handling failed"
        FAIL=$((FAIL + 1))
    fi
    # English entry should not be included
    if echo "$result" | grep -q '"### English'; then
        echo "  FAIL: English entry should not be in extract output"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: English excluded from CRLF input"
        PASS=$((PASS + 1))
    fi
}

test_empty_file() {
    echo "Test: empty file → empty JSON array"
    local f="$TMPDIR_BASE/empty.md"
    : > "$f"
    local result
    result=$(run_extract "$f")
    assert_eq "empty file → []" "[]" "$result"
}

test_empty_translated_skipped() {
    echo "Test: empty translated field → file unchanged"
    local f="$TMPDIR_BASE/empty-translated.md"
    cat > "$f" <<'EOF'
# History

### 日本語 (2024-01-01)
Background: テスト
EOF
    local manifest="$TMPDIR_BASE/empty-tr.json"
    cat > "$manifest" <<'MEOF'
[{"title":"### 日本語","original":"### 日本語 (2024-01-01)\nBackground: テスト\n","translated":""}]
MEOF
    local result expected
    expected=$(cat "$f")
    result=$(run_apply "$f" "$manifest")
    assert_eq "empty translated leaves file unchanged" "$expected" "$result"
}

test_empty_manifest_array() {
    echo "Test: empty manifest array → file unchanged"
    local f="$TMPDIR_BASE/empty-manifest.md"
    cat > "$f" <<'EOF'
# History

### English feature (2024-01-01)
Background: english
EOF
    local manifest="$TMPDIR_BASE/empty-array.json"
    echo '[]' > "$manifest"
    local result expected
    expected=$(cat "$f")
    result=$(run_apply "$f" "$manifest")
    assert_eq "empty manifest → unchanged" "$expected" "$result"
}

# --- Repo detection ---

test_private_flag_skips() {
    echo "Test: --private → exit 0 + stderr message"
    local f="$TMPDIR_BASE/private.md"
    cat > "$f" <<'EOF'
# History

## Changes

### 日本語 (2024-01-01)
Background: テスト
EOF
    local exit_code=0 stderr_out
    stderr_out=$(PYTHONIOENCODING=utf-8 $TRANSLATE_CMD "$f" --extract --private 2>&1 1>/dev/null) || exit_code=$?
    if [ "$exit_code" -eq 0 ] && echo "$stderr_out" | grep -qi "private"; then
        echo "  PASS: --private exits 0 with message"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: exit_code=$exit_code, stderr=$stderr_out"
        FAIL=$((FAIL + 1))
    fi
}

test_public_flag_forces() {
    echo "Test: --public forces extraction"
    local f="$TMPDIR_BASE/public.md"
    cat > "$f" <<'EOF'
# History

## Changes

### 日本語エントリ (2024-01-01)
Background: テスト
EOF
    local result
    result=$(run_extract "$f")
    if echo "$result" | grep -q "日本語エントリ"; then
        echo "  PASS: --public forces extraction"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: --public did not extract"
        FAIL=$((FAIL + 1))
    fi
}

# --- Idempotency ---

test_idempotency() {
    echo "Test: applying same translations twice produces identical output"
    local f="$TMPDIR_BASE/idempotent.md"
    cat > "$f" <<'EOF'
# History

## Changes

### English feature (2024-01-01)
Background: english

### 日本語の機能 (2024-02-01)
Background: 新しい機能
EOF
    local manifest="$TMPDIR_BASE/idempotent-manifest.json"
    cat > "$manifest" <<'EOF'
[
  {
    "title": "### 日本語の機能 (2024-02-01)",
    "original": "### 日本語の機能 (2024-02-01)\nBackground: 新しい機能",
    "translated": "### Japanese feature (2024-02-01)\nBackground: New feature"
  }
]
EOF
    local result1 result2
    result1=$(run_apply "$f" "$manifest")
    # Write result1 to a temp file and apply again
    local f2="$TMPDIR_BASE/idempotent2.md"
    echo "$result1" > "$f2"
    result2=$(run_apply "$f2" "$manifest")
    assert_eq "idempotent" "$result1" "$result2"
}

test_extract_idempotency() {
    echo "Test: extract twice → identical output"
    local f="$TMPDIR_BASE/extract-idem.md"
    cat > "$f" <<'EOF'
# History

### 日本語の機能 (2024-02-01)
Background: テスト

### English (2024-03-01)
Background: test
EOF
    local result1 result2
    result1=$(run_extract "$f")
    result2=$(run_extract "$f")
    assert_eq "extract idempotent" "$result1" "$result2"
}

# --- Run all tests ---

main() {
    setup

    echo "=== Normal cases ==="
    test_extract_finds_japanese
    test_extract_empty_when_no_japanese
    test_roundtrip_apply
    test_apply_preserves_structure
    test_dry_run_shows_diff

    echo ""
    echo "=== Default path cases ==="
    test_default_manifest_path_save
    test_default_manifest_path_apply
    test_missing_default_manifest_error

    echo ""
    echo "=== Error cases ==="
    test_file_not_found
    test_no_mode_flag
    test_manifest_file_not_found
    test_invalid_json_manifest
    test_manifest_original_not_found

    echo ""
    echo "=== Edge cases ==="
    test_mixed_jp_en_entry
    test_katakana_only
    test_crlf_input
    test_empty_file
    test_empty_translated_skipped
    test_empty_manifest_array

    echo ""
    echo "=== Repo detection ==="
    test_private_flag_skips
    test_public_flag_forces

    echo ""
    echo "=== Idempotency ==="
    test_idempotency
    test_extract_idempotency

    echo ""
    echo "=== Results ==="
    echo "  PASS: $PASS"
    echo "  FAIL: $FAIL"
    [ "$FAIL" -eq 0 ]
}

main
