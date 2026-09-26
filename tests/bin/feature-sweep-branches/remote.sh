#!/bin/bash
# tests/feature-sweep-branches/remote.sh
# Remote-branch sweep tests: merged-remote delete, non-GitHub remote, delete failure.
# Tests: T5, T6, T9
#
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/feature-sweep-branches/remote.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T5 — remote-only branch; stub gh api -X DELETE exits 0; stub gh pr list
#      returns merged=true → remote_deleted=1 in --ci-mode JSON
# ─────────────────────────────────────────────────────────────────────────────

T5_remote_branch_deleted_when_merged() {
    local repo="$TMPDIR_BASE/t5-repo"
    local stubdir="$TMPDIR_BASE/t5-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    # Create a fake remote repo and add it as origin
    local remote="$TMPDIR_BASE/t5-remote"
    init_repo "$remote"
    (cd "$repo" && git remote add origin "$remote")

    # Push a branch to the remote to simulate a remote-only branch
    make_branch_with_date "$repo" "feature/remote-t5" "$stale_epoch"
    (cd "$repo" && git push -q origin "feature/remote-t5" && git branch -D "feature/remote-t5")

    if [ ! -x "$SWEEP" ]; then
        fail "T5 remote_branch_deleted_when_merged: $SWEEP not found / not executable"
        return
    fi

    # Stub gh: pr list returns merged state; api DELETE succeeds
    local ghstubdir="$TMPDIR_BASE/t5-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T5 stub gh: pr list → merged (returns "true" for --jq 'length > 0'); api DELETE → success
case "$*" in
    *"pr list"*|*"pr view"*)
        echo "true"
        exit 0
        ;;
    *"api"*"-X DELETE"*|*"api"*"DELETE"*)
        exit 0
        ;;
    *"repo view"*)
        echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
        exit 0
        ;;
    *)
        echo "[]"
        exit 0
        ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T5 remote_branch_deleted_when_merged: exit=$exit_code, out=$out"
        return
    fi

    local remote_del
    remote_del="$(ci_field "$out" remote_deleted)"

    if [ "${remote_del:-0}" -ge 1 ] 2>/dev/null; then
        pass "T5 remote_branch_deleted_when_merged (remote_deleted>=1)"
    else
        fail "T5 remote_branch_deleted_when_merged: remote_deleted=${remote_del:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 — no origin or git@gitlab.com origin → exit 0,
#      remote_deleted=0, local_deleted=0
# Note: T6 does NOT stub is-github-dotcom-remote; uses natural repo with
#       non-GitHub remote so the guard returns non-zero.
# ─────────────────────────────────────────────────────────────────────────────

T6_non_github_remote_exits_zero_no_deletes() {
    local repo="$TMPDIR_BASE/t6-repo"
    local stubdir="$TMPDIR_BASE/t6-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"

    # Create a stub AGENTS_CONFIG_DIR where is-github-dotcom-remote exits 1
    # (non-GitHub remote) — do NOT stub it as exits 0
    mkdir -p "$stubdir/bin"
    cat > "$stubdir/bin/is-github-dotcom-remote" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$stubdir/bin/is-github-dotcom-remote"

    # Add a gitlab-style remote to simulate non-GitHub origin
    (cd "$repo" && git remote add origin "git@gitlab.com:user/repo.git" 2>/dev/null || true)

    make_branch_with_date "$repo" "feature/gitlab-t6" "$stale_epoch"

    if [ ! -x "$SWEEP" ]; then
        fail "T6 non_github_remote_exits_zero_no_deletes: $SWEEP not found / not executable"
        return
    fi

    local out exit_code
    out="$(cd "$repo" && AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T6 non_github_remote_exits_zero_no_deletes: exit=$exit_code (expected 0), out=$out"
        return
    fi

    local remote_del local_del
    remote_del="$(ci_field "$out" remote_deleted)"
    local_del="$(ci_field "$out" local_deleted)"

    if [ "${remote_del:-0}" = "0" ] && [ "${local_del:-0}" = "0" ]; then
        pass "T6 non_github_remote_exits_zero_no_deletes (exit=0, remote_deleted=0, local_deleted=0)"
    else
        fail "T6 non_github_remote_exits_zero_no_deletes: remote_deleted=${remote_del:-?} local_deleted=${local_del:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9 — stub gh api -X DELETE exits 1 → exit 0 (non-fatal),
#      remote_delete_failed=1 in JSON
# ─────────────────────────────────────────────────────────────────────────────

T9_remote_delete_failure_non_fatal() {
    local repo="$TMPDIR_BASE/t9-repo"
    local stubdir="$TMPDIR_BASE/t9-stub"
    local stale_epoch="1577836800"  # 2020-01-01 00:00:00 UTC
    init_repo "$repo"
    make_stub_agents_dir "$stubdir"

    # Create a fake remote and push a branch
    local remote="$TMPDIR_BASE/t9-remote"
    init_repo "$remote"
    (cd "$repo" && git remote add origin "$remote")
    make_branch_with_date "$repo" "feature/remote-t9" "$stale_epoch"
    (cd "$repo" && git push -q origin "feature/remote-t9" && git branch -D "feature/remote-t9")

    if [ ! -x "$SWEEP" ]; then
        fail "T9 remote_delete_failure_non_fatal: $SWEEP not found / not executable"
        return
    fi

    # Stub gh: pr list returns merged; api DELETE fails
    local ghstubdir="$TMPDIR_BASE/t9-gh"
    mkdir -p "$ghstubdir"
    cat > "$ghstubdir/gh" <<'GHSTUB'
#!/bin/bash
# T9 stub gh: pr list → merged (returns "true" for --jq 'length > 0'); api DELETE → failure
case "$*" in
    *"pr list"*|*"pr view"*)
        echo "true"
        exit 0
        ;;
    *"api"*"-X DELETE"*|*"api"*"DELETE"*)
        echo "error: could not delete ref" >&2
        exit 1
        ;;
    *"repo view"*)
        echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
        exit 0
        ;;
    *)
        echo "[]"
        exit 0
        ;;
esac
GHSTUB
    chmod +x "$ghstubdir/gh"

    local out exit_code
    out="$(cd "$repo" && PATH="$ghstubdir:$PATH" AGENTS_CONFIG_DIR="$stubdir" \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T9 remote_delete_failure_non_fatal: exit=$exit_code (expected 0), out=$out"
        return
    fi

    local failed
    failed="$(ci_field "$out" remote_delete_failed)"

    if [ "${failed:-0}" -ge 1 ] 2>/dev/null; then
        pass "T9 remote_delete_failure_non_fatal (exit=0, remote_delete_failed>=1)"
    else
        fail "T9 remote_delete_failure_non_fatal: remote_delete_failed=${failed:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T5_remote_branch_deleted_when_merged
T6_non_github_remote_exits_zero_no_deletes
T9_remote_delete_failure_non_fatal

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
