
# ============================================================================
# L1 unit — github-contents-validate.sh (cases 9–14)
# ============================================================================

# Build a well-formed history.md fixture.
make_valid_history() {
    local out="$1"
    {
        echo "### Initial entry (2026-05-31, abcdef1)"
        echo "Background: test fixture."
        echo "Changes: initial."
        echo ""
        echo "### Issue #1 (2026-05-31, 1234567)"
        echo "Background: closes the issue."
        echo "Changes: added X."
        echo ""
        echo ""
    } > "$out"
}

run_validate() {
    local subject="$1" path_arg="$2" file_arg="$3"
    run_with_timeout 30 bash "$VALIDATE_SH" \
        --path "$path_arg" \
        --file "$file_arg" \
        --commit-subject "$subject" 2>&1
}

test_l1_9_validate_accepts_well_formed_history() {
    require_file "$VALIDATE_SH" "test_l1_9_validate_accepts_well_formed_history" || return
    local f="$TMPDIR_BASE/hist-valid.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        pass "L1.9 well-formed history validates (exit 0)"
    else
        fail "L1.9 well-formed history: expected exit 0 got $exit_code ($out)"
    fi
}

test_l1_10_validate_rejects_empty_file() {
    require_file "$VALIDATE_SH" "test_l1_10_validate_rejects_empty_file" || return
    local f="$TMPDIR_BASE/hist-empty.md"
    : > "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.10 empty file: exit 2"
    else
        fail "L1.10 empty file: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_11_validate_rejects_over_hard_limit() {
    require_file "$VALIDATE_SH" "test_l1_11_validate_rejects_over_hard_limit" || return
    local f="$TMPDIR_BASE/hist-over.md"
    # 801 lines — over the 800-line hard limit.
    yes "filler line content" 2>/dev/null | head -n 801 > "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.11 >800 lines: exit 2 (hard limit)"
    else
        fail "L1.11 >800 lines: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_12_validate_rejects_wrong_commit_subject() {
    require_file "$VALIDATE_SH" "test_l1_12_validate_rejects_wrong_commit_subject" || return
    local f="$TMPDIR_BASE/hist-wrong-subject.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_validate "feat: add something" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.12 wrong commit subject format: exit 2"
    else
        fail "L1.12 wrong commit subject: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_13_validate_rejects_no_trailing_newline() {
    require_file "$VALIDATE_SH" "test_l1_13_validate_rejects_no_trailing_newline" || return
    local f="$TMPDIR_BASE/hist-no-newline.md"
    make_valid_history "$f"
    # Strip trailing newline(s).
    printf '%s' "$(cat "$f")" > "$f"
    local out exit_code
    out="$(run_validate "docs(history): record issue #1" "docs/history.md" "$f")"
    exit_code=$?
    if [ "$exit_code" = "2" ]; then
        pass "L1.13 no trailing newline: exit 2"
    else
        fail "L1.13 no trailing newline: expected exit 2 got $exit_code ($out)"
    fi
}

test_l1_14_validate_warns_on_non_ascii_english() {
    require_file "$VALIDATE_SH" "test_l1_14_validate_warns_on_non_ascii_english" || return
    local f="$TMPDIR_BASE/hist-non-ascii.md"
    {
        echo "### Issue #1 (2026-05-31, 1234567)"
        echo "Background: closes the issue 日本語テキスト多めに含めるテスト用文字列です。"
        echo "Changes: 追加された機能の説明文をここに記述する必要があります。"
        echo "もっと日本語を追加して10%以上にする必要があります。"
        echo "さらに日本語追加で確実に閾値を超えるようにします。"
        echo ""
    } > "$f"
    local out exit_code
    out="$(PLAN_LANG=english run_with_timeout 30 bash "$VALIDATE_SH" \
        --path "docs/history.md" \
        --file "$f" \
        --commit-subject "docs(history): record issue #1" 2>&1)"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        # Must still warn on stderr / mixed output.
        if echo "$out" | grep -qi "warn\|non-ascii\|english"; then
            pass "L1.14 PLAN_LANG=english + non-ASCII: exit 0 + warning"
        else
            fail "L1.14 PLAN_LANG=english + non-ASCII: exit 0 but no warning ($out)"
        fi
    else
        fail "L1.14 PLAN_LANG=english + non-ASCII: should not block (exit 0); got $exit_code ($out)"
    fi
}
