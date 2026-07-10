# tests/feature-1180-commit-lang-check/group-u.sh
# Group U — unit tests (call check() directly via node): CL-U1..CL-U8.
# Sourced by the dispatcher after lib.sh; relies on its shared harness.

# ============================================================================
# Group U — unit tests (call check() directly via node)
# ============================================================================

echo "=== Group U: lint-commit-lang.js unit tests ==="
echo ""

# CL-U1: CODE_LANG unset/empty → violations empty even for a CJK line
if require_sut "CL-U1" "$LINT_LIB"; then
    _u1_repo="$(make_git_repo u1)"
    printf 'const x = "日本語";\n' > "$_u1_repo/test.js"
    git -C "$_u1_repo" add test.js
    _u1_out="$(run_check_node "$_u1_repo" "")"
    if echo "$_u1_out" | json_violations_empty; then
        pass "CL-U1: CODE_LANG unset → violations empty for CJK line"
    else
        fail "CL-U1: expected empty violations with no CODE_LANG, got: $_u1_out"
    fi
fi

# CL-U2: CODE_LANG=english, staged CJK line → violations non-empty (file+line)
if require_sut "CL-U2" "$LINT_LIB"; then
    _u2_repo="$(make_git_repo u2)"
    printf 'const x = "日本語";\n' > "$_u2_repo/test.js"
    git -C "$_u2_repo" add test.js
    _u2_out="$(run_check_node "$_u2_repo" "english")"
    if echo "$_u2_out" | grep -q '"file"' && echo "$_u2_out" | grep -q '"lineNumber"'; then
        pass "CL-U2: CODE_LANG=english + CJK staged → violations non-empty with file:line"
    else
        fail "CL-U2: expected violations with file+lineNumber, got: $_u2_out"
    fi
fi

# CL-U3: CODE_LANG=english, file with `lang-check: ignore` + CJK → violations empty
if require_sut "CL-U3" "$LINT_LIB"; then
    _u3_repo="$(make_git_repo u3)"
    printf '// lang-check: ignore\nconst x = "日本語";\n' > "$_u3_repo/test.js"
    git -C "$_u3_repo" add test.js
    _u3_out="$(run_check_node "$_u3_repo" "english")"
    if echo "$_u3_out" | json_violations_empty; then
        pass "CL-U3: lang-check: ignore marker → violations empty despite CJK"
    else
        fail "CL-U3: expected empty violations with bypass marker, got: $_u3_out"
    fi
fi

# CL-U4: CODE_LANG=english, english-only file → violations empty
if require_sut "CL-U4" "$LINT_LIB"; then
    _u4_repo="$(make_git_repo u4)"
    printf 'const x = "hello world";\nfunction foo() { return 42; }\n' > "$_u4_repo/test.js"
    git -C "$_u4_repo" add test.js
    _u4_out="$(run_check_node "$_u4_repo" "english")"
    if echo "$_u4_out" | json_violations_empty; then
        pass "CL-U4: CODE_LANG=english + english-only file → violations empty"
    else
        fail "CL-U4: expected empty violations for english file, got: $_u4_out"
    fi
fi

# CL-U5: CODE_LANG=japanese, long English-only run → violations non-empty
if require_sut "CL-U5" "$LINT_LIB"; then
    _u5_repo="$(make_git_repo u5)"
    printf '// This function returns the current value of the counter\nconst x = 1;\n' > "$_u5_repo/test.js"
    git -C "$_u5_repo" add test.js
    _u5_out="$(run_check_node "$_u5_repo" "japanese")"
    if echo "$_u5_out" | grep -q '"file"' && echo "$_u5_out" | grep -q '"lineNumber"'; then
        pass "CL-U5: CODE_LANG=japanese + long English run → violations non-empty"
    else
        fail "CL-U5: expected violations for long English run under japanese policy, got: $_u5_out"
    fi
fi

# CL-U6: CODE_LANG=french (hint tier) + CJK content → violations empty, hints non-empty
if require_sut "CL-U6" "$LINT_LIB"; then
    _u6_repo="$(make_git_repo u6)"
    printf 'const msg = "日本語のメッセージ";\n' > "$_u6_repo/test.js"
    git -C "$_u6_repo" add test.js
    _u6_out="$(run_check_node "$_u6_repo" "french")"
    if echo "$_u6_out" | node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                const noViolations = r.violations && r.violations.length===0;
                const hasHints = r.hints && r.hints.length>0;
                process.exit(noViolations && hasHints ? 0 : 1);
            } catch(e) { process.exit(1); }
        })
    ' 2>/dev/null; then
        pass "CL-U6: CODE_LANG=french (hint tier) → violations empty, hints non-empty"
    else
        fail "CL-U6: expected empty violations + non-empty hints for hint-tier, got: $_u6_out"
    fi
fi

# CL-U7 (edge): CODE_LANG=english, binary file with NUL byte + CJK → violations empty
if require_sut "CL-U7" "$LINT_LIB"; then
    _u7_repo="$(make_git_repo u7)"
    # Write a file with a real NUL byte plus CJK content
    printf 'a\000b\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e' > "$_u7_repo/binary.js"
    git -C "$_u7_repo" add binary.js
    _u7_out="$(run_check_node "$_u7_repo" "english")"
    if echo "$_u7_out" | json_violations_empty; then
        pass "CL-U7: binary file with NUL+CJK → skipped, violations empty"
    else
        fail "CL-U7: expected binary exclusion (violations empty), got: $_u7_out"
    fi
fi

# CL-U8 (edge): empty staged changeset → violations empty (english policy)
if require_sut "CL-U8" "$LINT_LIB"; then
    _u8_repo="$(make_git_repo u8)"
    _u8_out="$(run_check_node "$_u8_repo" "english")"
    if echo "$_u8_out" | json_violations_empty; then
        pass "CL-U8: empty staged changeset → violations empty (english policy)"
    else
        fail "CL-U8: expected empty violations for empty staged set, got: $_u8_out"
    fi
fi
