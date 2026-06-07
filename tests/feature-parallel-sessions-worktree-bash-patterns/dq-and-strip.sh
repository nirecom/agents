# File-op quoted-arg stripping, interpreter-c, cosmetic quote,
# #514 DQ command substitution + backticks, #515 quoted command word,
# heredoc-after-strip, posix-redir quoted-arg, unquoted redirect/tee regression,
# /dev/null inside $(...).

# ============ Quoted-arg stripping for file-op patterns ============
test_quoted_arg_no_false_positive_file_op() {
    assert_classify "doc-append --subject \"cp files\"" \
        'doc-append --subject "cp files"' "read"
    assert_classify "doc-append --subject \"mv old new\"" \
        'doc-append --subject "mv old new"' "read"
    assert_classify "doc-append --subject \"rm tmp\"" \
        'doc-append --subject "rm tmp"' "read"
    assert_classify "doc-append --subject \"touch file.txt\"" \
        'doc-append --subject "touch file.txt"' "read"
}

# Interpreter -c: write when payload contains write tokens; read when payload
# is read-only (isReadOnlyInterpreterC recursively classifies the body).
test_interpreter_c_always_write() {
    assert_classify 'bash -c "rm foo"' 'bash -c "rm foo"' "write"
    # Read-only payloads: isReadOnlyInterpreterC classifies body then overrides.
    assert_classify 'sh -c "echo hello"' 'sh -c "echo hello"' "read"
    assert_classify 'pwsh -Command "Get-Content foo"' 'pwsh -Command "Get-Content foo"' "read"
    assert_classify 'zsh -c "ls"' 'zsh -c "ls"' "read"
}

# Documented FN: command name itself wrapped in quotes — strip removes it
# entirely, leaving no token to match. Result is "read".
test_cosmetic_quote_file_op_documented_fn() {
    assert_classify '"cp" src dst (command-name quoted, #515 fixed)' \
        '"cp" src dst' "write"
}

# ============ #514 — DQ-wrapped $(...) and `...` with write tokens classify as write ============
test_dq_command_substitution_with_redirect() {
    # HIGH#1: redirect inside $() inside DQ
    assert_classify 'echo "$(echo hi > out.txt)" (#514 redirect inside $())' \
        'echo "$(echo hi > out.txt)"' "write"
    # HIGH#1: write command word inside $() inside DQ
    assert_classify 'echo "$(rm tmp)" (#514 HIGH rm inside $())' \
        'echo "$(rm tmp)"' "write"
    assert_classify 'echo "$(touch f)" (#514 HIGH touch inside $())' \
        'echo "$(touch f)"' "write"
    assert_classify 'echo "$(tee out)" (#514 HIGH tee inside $())' \
        'echo "$(tee out)"' "write"
    assert_classify 'echo "$(mv a b)" (#514 HIGH mv inside $())' \
        'echo "$(mv a b)"' "write"
    # HIGH#2: backtick substitution sibling of $()
    assert_classify 'echo "`rm tmp`" (#514 HIGH backtick rm)' \
        'echo "`rm tmp`"' "write"
    assert_classify 'echo "`echo hi > out`" (#514 HIGH backtick redirect)' \
        'echo "`echo hi > out`"' "write"
    # Read commands inside $() / backticks remain read
    assert_classify 'echo "$(git status)" (#514 regression read cmd)' \
        'echo "$(git status)"' "read"
    assert_classify 'echo "`ls -la`" (#514 regression read cmd backtick)' \
        'echo "`ls -la`"' "read"
    # Single-quoted variant: shell does NOT expand $() inside SQ, so it's literal
    # text that gets stripped by stripQuotedArgs (AT-DP1) → read.
    assert_classify "echo '\$(echo hi > out.txt)' (#514 SQ literal)" \
        "echo '\$(echo hi > out.txt)'" "read"
}

# ============ #515 — command position fallback for quoted command word ============
test_quoted_command_word_write() {
    # DQ at command-position
    assert_classify '"tee" out.txt (#515 cmd-word quoted)' \
        '"tee" out.txt' "write"
    assert_classify '"rm" -f foo (#515 cmd-word quoted)' \
        '"rm" -f foo' "write"
    assert_classify 'foo; "rm" bar (#515 quoted rm after semicolon)' \
        'foo; "rm" bar' "write"
    assert_classify 'foo | "tee" out (#515 quoted tee after pipe)' \
        'foo | "tee" out' "write"
    # MEDIUM#5: SQ at command-position (sibling of DQ form)
    assert_classify "'rm' file (#515 MEDIUM SQ cmd-word)" \
        "'rm' file" "write"
    assert_classify "foo; 'cp' a b (#515 MEDIUM SQ after semicolon)" \
        "foo; 'cp' a b" "write"

    # MEDIUM#4: argument-position quoted text MUST stay read (no FP after tightening)
    assert_classify 'echo "rm" (#566 MEDIUM#4 FP guard)' \
        'echo "rm"' "read"
    assert_classify 'grep "tee" file (#566 MEDIUM#4 FP guard)' \
        'grep "tee" file' "read"
    assert_classify 'printf "cp" arg (#566 MEDIUM#4 FP guard)' \
        'printf "cp" arg' "read"
    assert_classify "echo 'rm' (#566 MEDIUM#4 SQ FP guard)" \
        "echo 'rm'" "read"
    assert_classify 'doc-append --subject "tee output" (regression)' \
        'doc-append --subject "tee output"' "read"
    assert_classify 'echo "tee file" (regression)' \
        'echo "tee file"' "read"
}

# Heredoc detection must survive the quoted-arg stripping pass.
test_heredoc_still_classified_after_strip() {
    assert_classify 'cat <<EOF (post-strip)' 'cat <<EOF' "write"
    assert_classify "cat <<'EOF' (post-strip)" "cat <<'EOF'" "write"
}

# ============ posix-redir kind: quoted >/>>/tee must not false-positive (#460) ============
test_quoted_arg_no_false_positive_posix_redir() {
    assert_classify 'grep -nE "pattern > match" file.txt (#460 repro)' \
        'grep -nE "pattern > match" file.txt' "read"
    assert_classify 'doc-append --subject "x > y"' \
        'doc-append --subject "x > y"' "read"
    assert_classify 'doc-append --subject "echo a >> b"' \
        'doc-append --subject "echo a >> b"' "read"
    assert_classify 'gh issue comment quoted > in body' \
        'gh issue comment 369 --body "use > to redirect"' "read"
    assert_classify "echo 'a > b' (single-quoted redirect char)" \
        "echo 'a > b'" "read"
    assert_classify 'doc-append --subject "tee output"' \
        'doc-append --subject "tee output"' "read"
    assert_classify 'echo "tee file"' \
        'echo "tee file"' "read"
}

# Regression guard: real unquoted redirects and tee must remain "write" after fix.
test_unquoted_redirect_and_tee_still_write() {
    assert_classify "echo hi > out.txt" 'echo hi > out.txt' "write"
    assert_classify "echo hi >> out.txt" 'echo hi >> out.txt' "write"
    assert_classify "echo hi | tee out.txt" 'echo hi | tee out.txt' "write"
    assert_classify "tee out.txt" 'tee out.txt' "write"
    assert_classify "cmd 2>&1 (FD-to-FD, null-sink form not applicable)" 'cmd 2>&1' "read"
    assert_classify "cmd 2>/dev/null" 'cmd 2>/dev/null' "read"
    assert_classify "cmd 2>/dev/null | grep x" 'cmd 2>/dev/null | grep x' "read"
}

# /dev/null inside $(...) command substitution must not be classified as write (#359).
test_devnull_inside_command_substitution() {
    assert_classify 'echo $(grep x file 2>/dev/null)' \
        'echo $(grep x file 2>/dev/null)' "read"
    assert_classify 'echo $(grep x file >/dev/null)' \
        'echo $(grep x file >/dev/null)' "read"
    assert_classify 'echo $(echo x > out.txt) (real redirect inside $() stays write)' \
        'echo $(echo x > out.txt)' "write"
}
