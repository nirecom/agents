# Group A gh command tests: heredoc body, redirect, inline-body stripping.

test_gh_group_a_with_heredoc_classified_read() {
    local cmd1='gh pr create --body "$(cat <<'"'"'EOF'"'"'
body text
EOF
)"'
    assert_classify "gh pr create + heredoc body" "$cmd1" "read"

    # gh issue create is a GitHub write, not a LOCAL worktree write. classify()'s
    # contract is local-write detection, so it returns "read" (post-#1296 retire of
    # the kind:"gh" WRITE_PATTERNS group). gh write enforcement is owned by isGhWriteIR
    # at the enforce-worktree gh gate — not by classify.
    local cmd2='gh issue create --title T --body "$(cat <<EOF
content
EOF
)"'
    assert_classify "gh issue create + heredoc body" "$cmd2" "read"

    assert_classify "gh pr edit plain body" 'gh pr edit 1 --body "x"' "read"
}

test_gh_group_a_with_redirect_still_write() {
    assert_classify "gh pr create + redirect to file" \
        'gh pr create --body "x" > out.txt' "write"
}

test_gh_group_a_heredoc_body_with_write_pattern_is_read() {
    local cmd1
    cmd1=$(printf 'gh pr create --body "$(cat <<EOF\ngit push origin main\nEOF\n)"')
    assert_classify "gh pr create heredoc body with git push is read" "$cmd1" "read"

    # gh issue create is a GitHub write, not a local write → read (#1296). The body
    # (even one containing rm -rf) is GitHub-side data, never executed locally.
    local cmd2
    cmd2=$(printf 'gh issue create --title "T" --body "$(cat <<EOF\nrm -rf /tmp/x\nEOF\n)"')
    assert_classify "gh issue create heredoc body with rm -rf is read" "$cmd2" "read"

    local cmd3
    cmd3=$(printf 'gh pr edit 1 --body "$(cat <<EOF\nnpm install\nEOF\n)"')
    assert_classify "gh pr edit heredoc body with npm install is read" "$cmd3" "read"

    local cmd4
    cmd4=$(printf 'gh repo edit --description "$(cat <<EOF\n> file.txt\nEOF\n)"')
    assert_classify "gh repo edit heredoc body with redirect char is read" "$cmd4" "read"

    local cmd5
    cmd5=$(printf 'gh pr create --body "$(cat <<-EOF\n\tgit commit -m x\n\tEOF\n)"')
    assert_classify "gh pr create <<-EOF heredoc body with git commit is read" "$cmd5" "read"

    local cmd6
    cmd6=$(printf 'gh pr create --body "$(cat <<EOF\ngit push origin\nEOF\n)" > out.txt')
    assert_classify "gh pr create heredoc body with write pattern plus external redirect is write" "$cmd6" "write"

    local cmd7
    cmd7=$(printf 'echo "$(cat <<EOF\ngit push\nEOF\n)"')
    assert_classify "non-group-a heredoc body with git push is write" "$cmd7" "write"

    local cmd8
    cmd8=$(printf 'gh pr create --body "$(cat <<EOF\ntee -a foo\nEOF\n)"')
    assert_classify "gh pr create heredoc body with tee -a is read" "$cmd8" "read"

    # Case 9: #369 original repro — gh issue create is a GitHub write, not a local
    # write → read (#1296). The body's "git push" line is GitHub-side data, not a
    # local command; gh write enforcement is owned by isGhWriteIR at the gh gate.
    local cmd9
    cmd9=$(printf 'gh issue create --title "T" --body "$(cat <<EOF\nThis is the background.\ngit push origin main\nMore text.\nEOF\n)"')
    assert_classify "gh issue create heredoc body #369 original repro" "$cmd9" "read"

    # Case 10: lazy-match regression — body contains "this is not EOF" as inner line
    local cmd10
    cmd10=$(printf 'gh pr create --body "$(cat <<EOF\nthis is not EOF\ngit push\nEOF\n)"')
    assert_classify "gh pr create heredoc body lazy-match regression with inner EOF-like line" "$cmd10" "read"

    # Case 11: `bash <<EOF` (interpreter heredoc, not cat) — must remain write
    local cmd11
    cmd11=$(printf 'gh pr create --body "$(bash <<EOF\nrm -rf /tmp/x\nEOF\n)"')
    assert_classify "gh pr create with interpreter heredoc (bash <<EOF rm -rf) is write" "$cmd11" "write"

    # Case 12: unquoted heredoc body with command substitution — must remain write
    local cmd12
    cmd12=$(printf 'gh pr create --body "$(cat <<EOF\n$(rm -rf /tmp/x)\nEOF\n)"')
    assert_classify "gh pr create unquoted heredoc body with command substitution is write" "$cmd12" "write"

    # Case 13: quoted heredoc body with literal $() — safe to strip → read
    local cmd13
    cmd13=$(printf "gh pr create --body \"\$(cat <<'EOF'\n\$(rm -rf /tmp/x)\nEOF\n)\"")
    assert_classify "gh pr create quoted heredoc body with literal dollar-paren is read" "$cmd13" "read"

    # Case 14: `cat <<EOF > out.txt` — rest-of-line redirect on opener must remain visible → write
    local cmd14
    cmd14=$(printf 'gh pr create --body "x"; cat <<EOF > out.txt\nbody\nEOF')
    assert_classify "cat heredoc with rest-of-line redirect after opener is write" "$cmd14" "write"

    # Case 15: unquoted heredoc body with backticks — must remain write
    local cmd15
    cmd15=$(printf 'gh pr create --body "$(cat <<EOF\n`rm -rf /tmp/x`\nEOF\n)"')
    assert_classify "gh pr create unquoted heredoc body with backticks is write" "$cmd15" "write"
}

# ============ Group A inline-body stripping (#596) ============
test_gh_group_a_inline_body_stripping() {
    # gh issue create is a GitHub write, not a LOCAL worktree write → classify returns
    # "read" (#1296). The --body content is GitHub-side data, never executed locally;
    # gh write enforcement is owned by isGhWriteIR at the enforce-worktree gh gate.
    assert_classify "gh issue create --body containing 'git commit'" \
        'gh issue create --body "git commit"' "read"
    assert_classify "gh issue create --body containing 'git push origin main'" \
        'gh issue create --body "git push origin main"' "read"
    assert_classify "gh issue create --body containing ISSUE_CLOSE_SKILL prefix" \
        'gh issue create --body "ISSUE_CLOSE_SKILL=1 git commit -m fix"' "read"

    assert_classify "bash <abs path>/issue-create-dispatch.sh ... --body 'git commit'" \
        'bash "/absolute/path/bin/github-issues/issue-create-dispatch.sh" --verdict none -- --title "T" --body "git commit"' "read"

    assert_classify "bash <C:/...>/issue-create-dispatch.sh ... --body 'git commit'" \
        'bash "C:/git/agents/bin/github-issues/issue-create-dispatch.sh" --verdict none -- --body "git commit"' "read"

    # gh issue create → GitHub write, not local write → read (#1296), regardless of body form.
    assert_classify "gh issue create --body ''" \
        'gh issue create --body ""' "read"

    assert_classify "gh issue create --body 'normal body text'" \
        'gh issue create --body "normal body text"' "read"

    assert_classify "gh issue create --body-file /path/to/file.md" \
        'gh issue create --body-file /path/to/file.md' "read"

    assert_classify "real 'git commit -m' must remain write" \
        'git commit -m "message"' "write"

    local probe_unknown_tmp
    probe_unknown_tmp=$(printf 'bash /tmp/issue-create-dispatch.sh --body "$(cat <<EOF\ngit commit\nEOF\n)"')
    assert_classify "bash /tmp/issue-create-dispatch.sh (unknown path) heredoc body stays visible → write" \
        "$probe_unknown_tmp" "write"
    local probe_unknown_rel
    probe_unknown_rel=$(printf 'bash ./fake-issue-create.sh --body "$(cat <<EOF\ngit commit\nEOF\n)"')
    assert_classify "bash ./fake-issue-create.sh (unknown path) heredoc body stays visible → write" \
        "$probe_unknown_rel" "write"
}
