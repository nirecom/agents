# tests/feature-1180-commit-lang-check/group-u-postfix.sh
# Group U (continued) — line-number accuracy + raw-scan cases (post-fix):
# CL-U9, CL-U10. Sourced by the dispatcher after lib.sh.

# ============================================================================
# Group U (continued) — line-number accuracy + raw-scan cases (post-fix)
# ============================================================================
#
# The next three cases (CL-U9, CL-U10) assert POST-FIX / CORRECT behavior for
# scanEnglishRun. They are EXPECTED TO FAIL against the current source because
# hooks/lib/lint-commit-lang.js still calls stripCodeFences() before scanning,
# which collapses fenced spans and shifts line numbers.
# Post-fix: scanEnglishRun will scan raw content lines (no stripCodeFences call).

# CL-U9 (post-fix): japanese policy — lineNumber accuracy past a triple-backtick line.
# File layout (5 lines):
#   1: const a = 1;
#   2: const fence1 = "```";
#   3: const fence2 = "```";
#   4: const b = 2;
#   5: // iterate over the whole list
#
# Line 2 and line 3 each contain a literal ``` in a string. stripCodeFences()
# matches the ``` pair spanning line 2→3 and collapses them, making the English
# run shift to line 3 (lineNumber 3) instead of its real position lineNumber 5.
# Post-fix (raw scan): lineNumber must equal 5.
#
# EXPECTED RED against current source (stripCodeFences shifts lineNumber to 3).
if require_sut "CL-U9" "$LINT_LIB"; then
    _u9_repo="$(make_git_repo u9)"
    printf 'const a = 1;\nconst fence1 = "```";\nconst fence2 = "```";\nconst b = 2;\n// iterate over the whole list\n' \
        > "$_u9_repo/test.js"
    git -C "$_u9_repo" add test.js
    _u9_out="$(run_check_node "$_u9_repo" "japanese")"
    # Post-fix expectation: violation at lineNumber 5
    _u9_lineno="$(echo "$_u9_out" | node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                if (!r.violations || r.violations.length===0) { process.exit(2); }
                // Accept the first violation that is on line 5
                const hit = r.violations.find(v => v.lineNumber === 5);
                process.exit(hit ? 0 : 1);
            } catch(e) { process.exit(1); }
        })
    ' 2>/dev/null; echo $?)"
    if [ "$_u9_lineno" = "0" ]; then
        pass 'CL-U9: japanese policy — English run after triple-backtick lines reported at lineNumber 5 (post-fix)'
    else
        fail "CL-U9: expected lineNumber=5 for English run past triple-backtick lines; got: $_u9_out (RED pending source fix: stripCodeFences shifts line number)"
    fi
fi

# CL-U10 (post-fix): japanese policy — English run INSIDE a ```-delimited span is flagged.
# File layout (5 lines):
#   1: const a = 1;
#   2: ```
#   3: // iterate over the entire current list
#   4: ```
#   5: const b = 2;
#
# Current behavior: stripCodeFences() removes everything from the ``` on line 2
# through the ``` on line 4, so the English run on line 3 is stripped and NOT flagged.
# Post-fix (raw scan): line 3 is scanned and violation is reported at lineNumber 3.
#
# EXPECTED RED against current source (English run inside fences is silently dropped).
if require_sut "CL-U10" "$LINT_LIB"; then
    _u10_repo="$(make_git_repo u10)"
    printf 'const a = 1;\n```\n// iterate over the entire current list\n```\nconst b = 2;\n' \
        > "$_u10_repo/test.js"
    git -C "$_u10_repo" add test.js
    _u10_out="$(run_check_node "$_u10_repo" "japanese")"
    # Post-fix expectation: violation at lineNumber 3 (English run inside ``` span)
    _u10_ok="$(echo "$_u10_out" | node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                if (!r.violations || r.violations.length===0) { process.exit(2); }
                const hit = r.violations.find(v => v.lineNumber === 3);
                process.exit(hit ? 0 : 1);
            } catch(e) { process.exit(1); }
        })
    ' 2>/dev/null; echo $?)"
    if [ "$_u10_ok" = "0" ]; then
        pass 'CL-U10: japanese policy — English run inside triple-backtick span flagged at lineNumber 3 (post-fix)'
    else
        fail "CL-U10: expected violation at lineNumber=3 for English run inside triple-backtick span; got: $_u10_out (RED pending source fix: stripCodeFences silently drops fenced content)"
    fi
fi

# CL-U11: MAX_LINE truncation — violation .line field is capped at 80 chars.
# lint-commit-lang.js record() does: line.trim().slice(0, MAX_LINE) where MAX_LINE=80.
# A staged line longer than 80 chars must be truncated in the reported .line field.
# This is GREEN against current source (the cap applies regardless of other pending fixes).
if require_sut "CL-U11" "$LINT_LIB"; then
    _u11_repo="$(make_git_repo u11)"
    # 85-char line: CJK char + 84 ASCII chars (triggers CJK violation under english policy)
    _u11_line="$(printf '日'; printf 'x%.0s' {1..84})"
    printf '%s\n' "$_u11_line" > "$_u11_repo/long.js"
    git -C "$_u11_repo" add long.js
    _u11_out="$(run_check_node "$_u11_repo" "english")"
    _u11_linelen="$(echo "$_u11_out" | node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                const v=r.violations&&r.violations[0];
                console.log(v&&v.line?v.line.length:0);
            } catch(e) { console.log(0); }
        })' 2>/dev/null)"
    if [ "$_u11_linelen" -eq 80 ]; then
        pass "CL-U11: MAX_LINE=80 cap — reported .line is exactly 80 chars when raw line exceeds 80"
    else
        fail "CL-U11: expected .line length=80 (MAX_LINE cap), got=$_u11_linelen; output=$_u11_out"
    fi
fi

# CL-U12: secret-after-cap — a fake token placed after position 80 is NOT leaked.
# record() does line.trim().slice(0, MAX_LINE); content beyond char 80 is dropped.
# This verifies the cap protects content co-located on the same violating line.
if require_sut "CL-U12" "$LINT_LIB"; then
    _u12_repo="$(make_git_repo u12)"
    _u12_secret="DO_NOT_LEAK_ME_TOKEN"
    # Line: CJK char + 79 Xs (80 chars total) + secret token → secret starts at position 80
    _u12_line="$(printf '日'; printf 'x%.0s' {1..79}; printf '%s' "$_u12_secret")"
    printf '%s\n' "$_u12_line" > "$_u12_repo/secret.js"
    git -C "$_u12_repo" add secret.js
    _u12_out="$(run_check_node "$_u12_repo" "english")"
    if echo "$_u12_out" | grep -qF "$_u12_secret"; then
        fail "CL-U12: secret token after position 80 leaked in violation output: $_u12_out"
    else
        pass "CL-U12: MAX_LINE cap — fake token after position 80 is NOT present in violation .line"
    fi
fi
