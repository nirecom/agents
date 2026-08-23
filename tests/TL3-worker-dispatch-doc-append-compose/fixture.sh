# Part of tests/TL3-worker-dispatch-doc-append-compose.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/doc-append.js, bin/compose-doc-append-entry
# Tags: worker-dispatch, doc-append, compose, gh-cli, real-environment, TL3, scope:common
# The fixture is a real git repo whose `origin` points at the probe repo, so the
# grandchild's own `gh repo view` — not a --repo flag this worker never passes —
# is what resolves the target. WORKTREE_NOTES.md carries History Notes bullets
# so compose reaches its authenticated reads instead of exiting early with
# nothing to write.
build_fixture() {
    MAIN_RAW="$TMPD/mainrepo"
    mkdir -p "$MAIN_RAW"
    git -C "$MAIN_RAW" init -q -b main || return 1
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config commit.gpgsign false
    git -C "$MAIN_RAW" config core.hooksPath /dev/null
    git -C "$MAIN_RAW" remote add origin "$PROBE_URL" || return 1

    printf 'init\n' > "$MAIN_RAW/README.md"
    printf '# Changelog\n\n' > "$MAIN_RAW/CHANGELOG.md"
    cat > "$MAIN_RAW/WORKTREE_NOTES.md" <<'NOTESEOF'
## History Notes
- Scoped the doc-append worker's child environment to the two GitHub tokens.

## Changelog Notes
NOTESEOF
    git -C "$MAIN_RAW" add -A
    git -C "$MAIN_RAW" commit -q --no-verify -m initial || return 1

    MAIN="$(nodepath "$MAIN_RAW")"
    MERGE_SHA="$(git -C "$MAIN_RAW" rev-parse HEAD)"
    return 0
}

# run_worker <tag> <payload-json> [ENV=VAL ...] — the real dispatcher CLI. The
# token, when an arm supplies one, exists ONLY in this parent's environment:
# whether it reaches the grandchild gh is the whole question.
run_worker() {
    local tag="$1" payload="$2"; shift 2
    local p="$PLANS_RAW/$tag.json"
    printf '%s\n' "$payload" > "$p"
    # Export the caller's pairs, never splice them into argv: `env GH_TOKEN=ghp_…`
    # publishes a real token in the command line of both the timeout wrapper and
    # env, readable from the process table for the child's whole life.
    # `unset` replaces the `-u GH_TOKEN -u GITHUB_TOKEN` env used to get — `-u`
    # would strip the exported value too, leaving the child with no token at all.
    # One subshell for all three: an export that escaped to the parent would make
    # arm_no_token's no-credential assertion silently unfalsifiable.
    WORKER_OUT="$(
        unset GH_TOKEN GITHUB_TOKEN
        for kv in "$@"; do export "$kv"; done
        run_with_timeout 300 env \
            -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            "GH_CONFIG_DIR=$EMPTY_GH_CONFIG" \
            "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
            node "$(nodepath "$AGENTS_DIR/bin/worker-dispatch.js")" \
            doc-append "$MAIN" "$(nodepath "$p")" 2>&1
    )"
    WORKER_RC=$?
    return 0
}

compose_payload() {
    cat <<PAYEOF
{"mode":"compose","cwd":"$MAIN",
 "notes_path":"$MAIN/WORKTREE_NOTES.md","branch":"feature/tl3-compose-probe",
 "pr_number":"1","merge_commit":"$MERGE_SHA",
 "pr_title":"Scope the doc-append child environment",
 "closes_issues_count":0,"artifact_dir":"$PLANS"}
PAYEOF
}

changelog_payload() {
    cat <<PAYEOF
{"mode":"changelog","cwd":"$MAIN","category":"FEATURE",
 "subject":"tl3 compose probe changelog entry",
 "background":"The empty child env scope must not break the sanctioned append.",
 "changes":"Appended a CHANGELOG entry through the real uv run doc-append.py.",
 "date":"2026-01-02","artifact_dir":"$PLANS"}
PAYEOF
}

worker_field() {
    printf '%s\n' "$WORKER_OUT" | sed -n "s/^$1: //p" | head -1 | tr -d '"'
}
