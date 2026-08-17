# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, git, pre-commit, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-enforce-worktree-bundle-a.sh (Bug 1 + Bug 2 + regression,
# EXCLUDE security, idempotency). Its extraction/security cases for compound
# commands and staged filenames live in target-extraction.sh.

# Two guard properties that both decide on the resolved WRITE TARGET rather than
# on the CWD, which is why they share a fragment:
#   Bug 1 — ENFORCE_WORKTREE_EXCLUDE must be honoured in PreToolUse, so a file
#           pre-commit would let through is not blocked one layer earlier.
#   Bug 2 — Edit/Write/MultiEdit and Bash file targets get a session-scope check,
#           so a write into a repo outside the session is not blocked merely
#           because CWD happens to sit in a main checkout.

# Multi-target tools are all-or-nothing: one non-excluded or in-session target
# in a MultiEdit or a redirect list blocks the whole call.

# Fragment-local helpers carry an `es_` prefix: fragments share one shell.

es_edits_json() {
    local base="$1" a="$2" b="$3"
    node -e "
      const p = process.argv[1];
      console.log(JSON.stringify([
        { file_path: p + '/' + process.argv[2], old_string: 'a', new_string: 'b' },
        { file_path: p + '/' + process.argv[3], old_string: 'a', new_string: 'b' },
      ]));
    " -- "$base" "$a" "$b" 2>/dev/null
}

echo "=== Bug 2: session-scope check on write targets ==="

es_in="$(setup_main_checkout "B2-edit-in-sess")"
es_non="$(setup_main_checkout "B2-edit-non-sess")"
es_out="$(run_edit_guard "$(to_node_path "$es_non")/README.md" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Edit on non-session repo file allows" \
    "Bug 2: Edit on non-session repo file should allow"

es_in="$(setup_main_checkout "B2-edit-non-repo-sess")"
es_plain="$TMPDIR_BASE/plain-file.txt"
echo "x" > "$es_plain"
es_out="$(run_edit_guard "$(to_node_path "$es_plain")" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Edit on non-repo path allows" \
    "Bug 2: Edit on non-repo path should allow"

es_in="$(setup_main_checkout "B2-me-in-sess")"
es_non="$(setup_main_checkout "B2-me-non-sess")"
es_out="$(run_multiedit_guard \
    "$(es_edits_json "$(to_node_path "$es_non")" "a.md" "b.md")" \
    "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: MultiEdit all-non-session edits allow" \
    "Bug 2: MultiEdit all-non-session edits should allow"

# The Codex case: without the session-scope check, findRepoRootForBash returns
# the CWD repo (an in-session main checkout) and this write is blocked.
es_in="$(setup_main_checkout "B2-rdr-in-sess")"
es_non="$(setup_main_checkout "B2-rdr-non-sess")"
es_out="$(run_bash_guard "echo x > $(to_node_path "$es_non")/README.md" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Bash redirect to non-session file allows" \
    "Bug 2: Bash redirect to non-session file should allow"

es_in="$(setup_main_checkout "B2-tee-in-sess")"
es_non="$(setup_main_checkout "B2-tee-non-sess")"
es_out="$(run_bash_guard "cmd | tee $(to_node_path "$es_non")/README.md" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Bash tee to non-session file allows" \
    "Bug 2: Bash tee to non-session file should allow"

es_in="$(setup_main_checkout "B2-pwsh-in-sess")"
es_non="$(setup_main_checkout "B2-pwsh-non-sess")"
es_out="$(run_bash_guard "Set-Content -Path $(to_node_path "$es_non")/README.md -Value x" \
    "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Bash Set-Content on non-session file allows" \
    "Bug 2: Bash Set-Content on non-session file should allow"

es_in="$(setup_main_checkout "B2-rdr-non-repo-sess")"
es_out="$(run_bash_guard "echo x > $(to_node_path "$TMPDIR_BASE/plain.txt")" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Bash redirect to non-repo path allows" \
    "Bug 2: Bash redirect to non-repo path should allow"

# stdout in-session + stderr non-session: both targets are extracted, and any
# in-session target blocks the whole command.
es_in="$(setup_main_checkout "B2-mix-in-sess")"
es_non="$(setup_main_checkout "B2-mix-non-sess")"
es_in_n="$(to_node_path "$es_in")"
es_out="$(run_bash_guard \
    "cat $es_in_n/README.md > $es_in_n/out.md 2>> $(to_node_path "$es_non")/log.md" \
    "$es_in" ENFORCE_WORKTREE=on)"
assert_decision block "$es_out" \
    "Bug 2: Bash mixed redirects with in-session target blocks" \
    "Bug 2: Bash mixed redirects (in-session present) should block"

es_in="$(setup_main_checkout "B2-gitc-in-sess")"
es_non="$(setup_main_checkout "B2-gitc-non-sess")"
es_out="$(run_bash_guard "git -C $(to_node_path "$es_non") commit -m x" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$es_out" \
    "Bug 2: Bash git -C non-session commit allows" \
    "Bug 2: Bash git -C non-session commit should allow"

es_in="$(setup_main_checkout "B2-reg-in-sess")"
es_out="$(run_edit_guard "$(to_node_path "$es_in")/README.md" "$es_in" ENFORCE_WORKTREE=on)"
assert_decision block "$es_out" \
    "Regression: Edit on in-session main worktree blocks" \
    "Regression: Edit on in-session main worktree should block"

echo "=== Bug 1: ENFORCE_WORKTREE_EXCLUDE honoured in PreToolUse ==="

ES_EXCL_ENV="ENFORCE_WORKTREE_EXCLUDE=.env.local"

es_repo="$(setup_main_checkout "B1-edit-excl")"
es_out="$(run_edit_guard "$(to_node_path "$es_repo")/.env.local" "$es_repo" \
    ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision allow "$es_out" \
    "Bug 1: Edit excluded file (.env.local) allows" \
    "Bug 1: Edit excluded file should allow"

es_repo="$(setup_main_checkout "B1-edit-mis")"
es_out="$(run_edit_guard "$(to_node_path "$es_repo")/secret.md" "$es_repo" \
    ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision block "$es_out" \
    "Bug 1: Edit non-excluded file blocks" \
    "Bug 1: Edit non-excluded file should block"

es_repo="$(setup_main_checkout "B1-write-excl")"
es_out="$(run_write_guard "$(to_node_path "$es_repo")/.env.local" "$es_repo" \
    ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision allow "$es_out" \
    "Bug 1: Write excluded file allows" \
    "Bug 1: Write excluded file should allow"

es_repo="$(setup_main_checkout "B1-me-all-excl")"
es_out="$(run_multiedit_guard \
    "$(es_edits_json "$(to_node_path "$es_repo")" "a.local" "b.local")" \
    "$es_repo" ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.local")"
assert_decision allow "$es_out" \
    "Bug 1: MultiEdit all excluded files allows" \
    "Bug 1: MultiEdit all excluded files should allow"

es_repo="$(setup_main_checkout "B1-me-part-excl")"
es_out="$(run_multiedit_guard \
    "$(es_edits_json "$(to_node_path "$es_repo")" "a.local" "normal.md")" \
    "$es_repo" ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.local")"
assert_decision block "$es_out" \
    "Bug 1: MultiEdit partial-excluded (one non-excluded file) blocks" \
    "Bug 1: MultiEdit partial-excluded should block"

es_repo="$(setup_main_checkout "B1-rdr-excl")"
es_out="$(run_bash_guard "echo x > $(to_node_path "$es_repo")/.env.local" "$es_repo" \
    ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision allow "$es_out" \
    "Bug 1: Bash redirect to excluded file allows" \
    "Bug 1: Bash redirect to excluded file should allow"

es_repo="$(setup_main_checkout "B1-rdr-mis")"
es_out="$(run_bash_guard "echo x > $(to_node_path "$es_repo")/secret.md" "$es_repo" \
    ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision block "$es_out" \
    "Bug 1: Bash redirect non-excluded blocks" \
    "Bug 1: Bash redirect non-excluded should block"

es_repo="$(setup_main_checkout "B1-tee-excl")"
es_out="$(run_bash_guard "cmd | tee $(to_node_path "$es_repo")/.env.local" "$es_repo" \
    ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision allow "$es_out" \
    "Bug 1: Bash tee to excluded file allows" \
    "Bug 1: Bash tee to excluded file should allow"

es_repo="$(setup_main_checkout "B1-pwsh-excl")"
es_out="$(run_bash_guard "Set-Content -Path $(to_node_path "$es_repo")/.env.local -Value x" \
    "$es_repo" ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision allow "$es_out" \
    "Bug 1: Bash Set-Content on excluded file allows" \
    "Bug 1: Bash Set-Content on excluded file should allow"

# `git commit` has no target on the command line — the staged set is the target.
es_repo="$(setup_main_checkout "B1-commit-all-excl")"
echo "content" > "$es_repo/.env.local"
git -C "$es_repo" add .env.local
es_out="$(run_bash_guard "git commit -m x" "$es_repo" ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision allow "$es_out" \
    "Bug 1: git commit with all staged files excluded allows" \
    "Bug 1: git commit with all staged excluded should allow"

es_repo="$(setup_main_checkout "B1-commit-part")"
echo "x" > "$es_repo/.env.local"
echo "y" > "$es_repo/normal.md"
git -C "$es_repo" add .env.local normal.md
es_out="$(run_bash_guard "git commit -m x" "$es_repo" ENFORCE_WORKTREE=on "$ES_EXCL_ENV")"
assert_decision block "$es_out" \
    "Bug 1: git commit with partial-excluded staged blocks" \
    "Bug 1: git commit with partial-excluded staged should block"

# No file target is extractable from either command, so EXCLUDE cannot clear
# them and the decision has to fail closed rather than default to allow.
es_repo="$(setup_main_checkout "B1-unsup-fc")"
es_out="$(run_bash_guard "npm install" "$es_repo" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=node_modules/**")"
assert_decision block "$es_out" \
    "Bug 1: unsupported write fails-closed (block)" \
    "Bug 1: unsupported write should fail-closed"

es_repo="$(setup_main_checkout "B1-parsef-fc")"
# Single-quoted so $VAR stays literal in the command string.
es_out="$(run_bash_guard 'echo x > $VAR' "$es_repo" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.md")"
assert_decision block "$es_out" \
    "Bug 1: parse-failure (\$VAR) fails-closed (block)" \
    "Bug 1: parse-failure write should fail-closed"

es_repo="$(setup_main_checkout "REG-no-excl")"
es_out="$(run_edit_guard "$(to_node_path "$es_repo")/README.md" "$es_repo" ENFORCE_WORKTREE=on)"
assert_decision block "$es_out" \
    "Regression: Edit on main worktree (no EXCLUDE) blocks" \
    "Regression: Edit on main worktree (no EXCLUDE) should block"

echo "=== EXCLUDE security + idempotency ==="

# EXCLUDE is user-supplied and reaches glob matching — it must never reach a
# shell. The hook may allow or block; what it must not do is run the payload
# or emit anything but well-formed JSON.
es_repo="$(setup_main_checkout "SEC-meta")"
es_sentinel="$TMPDIR_BASE/sec-meta-sentinel-$$"
rm -rf "$es_sentinel" 2>/dev/null
es_out="$(run_edit_guard "$(to_node_path "$es_repo")/README.md" "$es_repo" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=; mkdir $es_sentinel")"
if [ -d "$es_sentinel" ] || [ -e "$es_sentinel" ]; then
    fail "SECURITY: EXCLUDE metachar executed shell"
    rm -rf "$es_sentinel" 2>/dev/null
else
    pass "SECURITY: EXCLUDE metachar not executed"
fi
if echo "$es_out" | grep -qE '^\{.*\}$'; then
    pass "SECURITY: EXCLUDE metachar produces well-formed output"
else
    fail "SECURITY: EXCLUDE metachar produced malformed output ($es_out)"
fi

es_repo="$(setup_main_checkout "IDEM")"
es_a="$(run_edit_guard "$(to_node_path "$es_repo")/README.md" "$es_repo" ENFORCE_WORKTREE=on)"
es_b="$(run_edit_guard "$(to_node_path "$es_repo")/README.md" "$es_repo" ENFORCE_WORKTREE=on)"
if [ "$es_a" = "$es_b" ]; then
    pass "Edit guard is idempotent"
else
    fail "Edit guard not idempotent (a=$es_a b=$es_b)"
fi
