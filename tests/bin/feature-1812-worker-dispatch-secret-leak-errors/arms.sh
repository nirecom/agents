# Part of tests/feature-1812-worker-dispatch-secret-leak-errors.sh — sourced.
# Tests: bin/worker-dispatch/workers/doc-append.js, bin/worker-dispatch/workers/commit-push/procedure.js, bin/worker-dispatch/fsguard.js
# Tags: worker-dispatch, doc-append, commit-push, credential-exposure, artifact-log, redaction, adversarial, security, TL2, scope:issue-specific
# Two REAL dispatcher runs whose child fails AFTER printing a credential-shaped
# value, and the assertions on where that value ends up. Arm A leaks the token
# the worker itself propagated (#1744); arm B leaks from a repo-planted
# pre-commit hook, the code-execution surface #1812's empty envScope exists for.

posixpath() { cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; }

# The gh stand-in for arm A: it prints the token it was handed and fails, the way
# a verbose HTTP error that echoes its own Authorization header would.
build_gh_stub() {
    STUB_BIN="$TMPD/stubbin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "gh: request failed: Authorization: token ${GH_TOKEN:-<none>}" >&2
echo "gh: (GITHUB_TOKEN=${GITHUB_TOKEN:-<none>})" >&2
exit 1
GHEOF
    chmod +x "$STUB_BIN/gh"
}

build_repos() {
    MAIN_RAW="$TMPD/mainrepo"
    mkdir -p "$MAIN_RAW"
    git -C "$MAIN_RAW" init -q -b main >/dev/null 2>&1
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config commit.gpgsign false
    git -C "$MAIN_RAW" config core.hooksPath /dev/null
    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
    git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
    WT_RAW="$TMPD/linked-wt"
    git -C "$MAIN_RAW" worktree add -q -b "$BRANCH" "$WT_RAW" >/dev/null 2>&1 || return 1
    printf '## History Notes\n- probe\n\n## Changelog Notes\n- probe\n' > "$WT_RAW/WORKTREE_NOTES.md"
    return 0
}

# The repo-planted hook for arm B: arbitrary code inside the worker's own commit
# step, printing a credential-shaped string on the way out.
build_leaky_hook() {
    HOOKS_DIR="$TMPD/hooks"
    mkdir -p "$HOOKS_DIR"
    cat > "$HOOKS_DIR/pre-commit" <<HOOKEOF
#!/usr/bin/env bash
echo "pre-commit: upload failed for token $LEAK_HOOK_TOKEN" >&2
echo "pre-commit: sock was $LEAK_HOOK_SOCK" >&2
exit 1
HOOKEOF
    chmod +x "$HOOKS_DIR/pre-commit"
}

# newest_artifact <glob> — the log the run just wrote, resolved by mtime so a
# previous arm's file can never be read in place of this one.
newest_artifact() {
    ls -t "$PLANS_RAW"/*"$1" 2>/dev/null | head -1
}

dispatch_worker() {
    local worker="$1" payload="$2"
    DOUT=""
    DOUT="$(run_with_timeout 240 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "PATH=$STUB_BIN:$PATH" \
        "GH_TOKEN=$FAKE_GH_TOKEN" "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        "SSH_AUTH_SOCK=$FAKE_SSH_SOCK" "ENFORCE_WORKTREE=off" \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$(nodepath "$AGENTS_DIR/bin/worker-dispatch.js")" \
        "$worker" "$(nodepath "$MAIN_RAW")" "$(nodepath "$payload")" 2>&1)" || true
}

dfield() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1 | tr -d '"'; }

# write_doc_append_payload <merge_commit> — merge_commit is `text` in the
# registry payloadSpec, so free text really does reach the CLI's own validator.
write_doc_append_payload() {
    local p="$PLANS_RAW/doc-append-payload.json"
    cat > "$p" <<PAYEOF
{"mode":"compose","notes_path":"$(nodepath "$WT_RAW/WORKTREE_NOTES.md")",
 "branch":"$BRANCH","pr_number":"1812","merge_commit":"$1",
 "pr_title":"secret leak probe","closes_issues_count":0,
 "cwd":"$(nodepath "$WT_RAW")","artifact_dir":"$PLANS"}
PAYEOF
    printf '%s' "$p"
}

# A1 — the propagated token printed by the child's OWN child (`gh`). Every gh
# call site in compose-doc-append-entry redirects stderr to /dev/null, so the
# token never reaches the worker: containment by redirect, asserted as absence.
arm_doc_append_contained() {
    local p
    p="$(write_doc_append_payload "0123456789abcdef0123456789abcdef01234567")"
    dispatch_worker doc-append "$p"

    if [ "$(dfield status)" != "failed" ]; then
        fail "A1/compose-child-really-failed" "status=$(dfield status) out=$(printf '%s' "$DOUT" | tr '\n' ' ' | cut -c1-300)"
        return
    fi
    pass "A1/compose-child-really-failed"

    A_LOG="$(newest_artifact doc-append-worker.log)"
    if [ -z "$A_LOG" ] || [ ! -f "$A_LOG" ]; then
        fail "A1/worker-persisted-an-artifact-log" "artifactPath=$(dfield artifactPath)"
        return
    fi
    pass "A1/worker-persisted-an-artifact-log"

    if grep -qF "$FAKE_GH_TOKEN" "$A_LOG" || grep -qF "$FAKE_GITHUB_TOKEN" "$A_LOG"; then
        fail "A1/gh-printed-token-does-not-reach-the-artifact-log" "$A_LOG"
    else
        pass "A1/gh-printed-token-does-not-reach-the-artifact-log"
    fi
    if printf '%s' "$DOUT" | grep -qF "$FAKE_GH_TOKEN"; then
        fail "A1/gh-printed-token-does-not-reach-the-dispatcher-summary" "summary=$(dfield summary)"
    else
        pass "A1/gh-printed-token-does-not-reach-the-dispatcher-summary"
    fi
    # Non-vacuity for the two rows above: the stub really did print the token, so
    # the absence is containment rather than a `gh` that never ran.
    if [ "$(dfield summary)" = "compose-doc-append-entry: failed to resolve owner/repo via gh" ]; then
        pass "A1/the-failure-really-came-from-the-token-printing-gh-call"
    else
        fail "A1/the-failure-really-came-from-the-token-printing-gh-call" "summary=$(dfield summary)"
    fi
}

# A2 — the same worker, same seam, one channel over: a value the compose child
# prints on its OWN stderr. Nothing between that stderr and the artifact log
# redacts anything, so A1's absence is redirect-shaped, not redaction-shaped.
arm_doc_append_leak() {
    local p
    p="$(write_doc_append_payload "$LEAK_HOOK_TOKEN")"
    dispatch_worker doc-append "$p"

    if [ "$(dfield status)" != "failed" ]; then
        fail "A2/compose-child-really-failed" "status=$(dfield status)"
        return
    fi
    pass "A2/compose-child-really-failed"

    A_LOG="$(newest_artifact doc-append-worker.log)"
    if [ -z "$A_LOG" ] || [ ! -f "$A_LOG" ]; then
        fail "A2/worker-persisted-an-artifact-log" "artifactPath=$(dfield artifactPath)"
        return
    fi
    pass "A2/worker-persisted-an-artifact-log"

    if grep -qF "$LEAK_HOOK_TOKEN" "$A_LOG"; then
        pass "A2/LEAK-REPRODUCES-child-stderr-persisted-verbatim-in-the-artifact-log"
    else
        fail "A2/LEAK-REPRODUCES-child-stderr-persisted-verbatim-in-the-artifact-log" \
            "no longer in $A_LOG — if a redaction seam was added, this row is the one to update"
    fi
    if printf '%s' "$DOUT" | grep -qF "$LEAK_HOOK_TOKEN"; then
        pass "A2/LEAK-REPRODUCES-child-stderr-reaches-the-dispatcher-summary"
    else
        fail "A2/LEAK-REPRODUCES-child-stderr-reaches-the-dispatcher-summary" "summary=$(dfield summary)"
    fi
}

arm_commit_push() {
    git -C "$MAIN_RAW" config core.hooksPath "$(posixpath "$HOOKS_DIR")"
    printf 'change\n' >> "$WT_RAW/README.md"
    git -C "$WT_RAW" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1

    local p="$PLANS_RAW/commit-push-payload.json"
    cat > "$p" <<PAYEOF
{"commit_message":"chore(1812): secret leak probe","branch":"$BRANCH",
 "worktree_path":"$(nodepath "$WT_RAW")","session_id":"wd1812-leak-session",
 "enforce_worktree":"off","artifact_dir":"$PLANS"}
PAYEOF
    dispatch_worker commit-push "$p"
    git -C "$MAIN_RAW" config core.hooksPath /dev/null

    # The status the shipped procedure returns for a failed `git commit`
    # (procedure.js step 4 reuses "staging_check_failed").
    if [ "$(dfield status)" != "staging_check_failed" ]; then
        fail "B/planted-pre-commit-hook-really-failed-the-commit" \
            "status=$(dfield status) out=$(printf '%s' "$DOUT" | tr '\n' ' ' | cut -c1-300)"
        return
    fi
    pass "B/planted-pre-commit-hook-really-failed-the-commit"

    B_LOG="$(newest_artifact commit-push-worker.log)"
    if [ -z "$B_LOG" ] || [ ! -f "$B_LOG" ]; then
        fail "B/worker-persisted-an-artifact-log" "artifactPath=$(dfield artifactPath)"
        return
    fi
    pass "B/worker-persisted-an-artifact-log"

    if grep -qF "$LEAK_HOOK_TOKEN" "$B_LOG"; then
        pass "B/LEAK-REPRODUCES-hook-printed-token-persisted-verbatim-in-the-artifact-log"
    else
        fail "B/LEAK-REPRODUCES-hook-printed-token-persisted-verbatim-in-the-artifact-log" "not found in $B_LOG"
    fi
    if grep -qF "$LEAK_HOOK_SOCK" "$B_LOG"; then
        pass "B/LEAK-REPRODUCES-hook-printed-socket-path-persisted-verbatim"
    else
        fail "B/LEAK-REPRODUCES-hook-printed-socket-path-persisted-verbatim" "not found in $B_LOG"
    fi
    if printf '%s' "$DOUT" | grep -qF "$LEAK_HOOK_TOKEN"; then
        pass "B/LEAK-REPRODUCES-hook-printed-token-reaches-the-dispatcher-summary"
    else
        fail "B/LEAK-REPRODUCES-hook-printed-token-reaches-the-dispatcher-summary" "summary=$(dfield summary)"
    fi
}
