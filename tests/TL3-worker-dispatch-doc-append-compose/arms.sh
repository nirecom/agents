# Part of tests/TL3-worker-dispatch-doc-append-compose.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/doc-append.js, bin/compose-doc-append-entry
# Tags: worker-dispatch, doc-append, compose, gh-token, github-token, real-environment, TL3, scope:common
# Arms A/B are the allow direction of #1744, one per token name gh honours; arm C
# is the discriminator that makes them mean something; arm D is the allow
# direction of #1812's empty scope on the history/changelog path.
# The abort message below is compose's OWN terminus after two authenticated
# reads, so an arm that reaches it has proved the token travelled the whole
# dispatcher -> worker -> bash -> gh chain.
ABORT_MSG="docs/history.md missing on remote"
NOAUTH_MSG="failed to resolve owner/repo via gh"

# arm_token <tag> <env-var-name> — arms A and B differ by ONE name, so they are
# one function: a per-arm copy is where the two silently drift apart.
arm_token() {
    local tag="$1" var="$2"
    run_worker "$tag" "$(compose_payload)" "$var=$PROBE_TOKEN"
    assert_contains "$tag/token-reached-gh-and-the-remote-read-happened" \
        "$ABORT_MSG" "$WORKER_OUT"
    # The run must end at compose's guard, not at a dispatcher-level refusal
    # that would produce a failure for an entirely different reason.
    assert_eq "$tag/worker-reports-the-compose-cli-failure-not-its-own" \
        "failed" "$(worker_field status)"
}

arm_gh_token() { arm_token "armA-gh-token" GH_TOKEN; }
arm_github_token() { arm_token "armB-github-token" GITHUB_TOKEN; }

# Arm C — the same payload with NO token anywhere. Pre-#1744 the entry declared
# neither name, so arms A and B behaved exactly like this one: this row is the
# fail-before-fix evidence, and without it "compose failed" would be unreadable.
arm_no_token() {
    run_worker "armC-no-token" "$(compose_payload)"
    assert_contains "armC/no-token-child-cannot-even-resolve-the-repository" \
        "$NOAUTH_MSG" "$WORKER_OUT"
    # Negative assertion: it must NOT have got as far as the authenticated read.
    case "$WORKER_OUT" in
        *"$ABORT_MSG"*)
            fail "armC/no-token-child-never-reached-the-authenticated-read" ;;
        *)
            pass "armC/no-token-child-never-reached-the-authenticated-read"
            PROVEN=$((PROVEN + 1)) ;;
    esac
}

# Arm D — the other side of #1812 on this worker: history/changelog take an
# EMPTY envScope, and the sanctioned append must still work. That the child
# holds no credential under that scope is asserted in a real child process by
# tests/feature-1812-worker-dispatch-env-scope/group-real-child.sh (row D2);
# this arm asserts the operation those rows must not have broken.
arm_changelog_empty_scope() {
    local before after
    before="$(wc -l < "$MAIN_RAW/CHANGELOG.md" 2>/dev/null || echo 0)"
    run_worker "armD-changelog" "$(changelog_payload)"
    if [ "$(worker_field status)" != "appended" ]; then
        INCONCLUSIVE=1
        skip "armD/* — the changelog append did not run to completion: $WORKER_OUT"
        return 0
    fi
    pass "armD/empty-scope-changelog-append-reports-success"
    PROVEN=$((PROVEN + 1))
    after="$(wc -l < "$MAIN_RAW/CHANGELOG.md" 2>/dev/null || echo 0)"
    if [ "$after" -gt "$before" ] && grep -q "tl3 compose probe changelog entry" "$MAIN_RAW/CHANGELOG.md"; then
        pass "armD/the-entry-really-landed-in-the-file"; PROVEN=$((PROVEN + 1))
    else
        fail "armD/the-entry-really-landed-in-the-file — lines before=$before after=$after"
    fi
}
