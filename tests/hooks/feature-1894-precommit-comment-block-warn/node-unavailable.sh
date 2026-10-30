#!/usr/bin/env bash
# tests/hooks/feature-1894-precommit-comment-block-warn/node-unavailable.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, node, degraded, skipped, fail-open, announce, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 4 — a missing Node runtime: CLI skip at rc 0 (N4), one-line hook announcement (N1/N2),
# and since #2507 (Node hook body) an adapter block with a named reason (N3). Sourced by the dispatcher.
_path_without_node() {
    # Real absence, not a shim: a fake node would leave `command -v node` succeeding.
    local out="" d
    local IFS=:
    for d in $PATH; do
        [ -z "$d" ] && continue
        [ -x "$d/node" ] && continue
        [ -x "$d/node.exe" ] && continue
        out="${out:+$out:}$d"
    done
    printf '%s' "$out"
}

NO_NODE_PATH="$(_path_without_node)"
NODE_HIDEABLE=0
if command -v node >/dev/null 2>&1; then
    if env "PATH=$NO_NODE_PATH" sh -c 'command -v node' >/dev/null 2>&1; then
        NODE_HIDEABLE=0
    else
        NODE_HIDEABLE=1
    fi
else
    # Node is already absent from this machine's PATH: the degraded state is the
    # ambient one, so the cases below run as-is.
    NODE_HIDEABLE=1
    NO_NODE_PATH="$PATH"
fi

# ============================================================================
# N1 — the hook announces a SKIPPED scan and lets the commit through
#
# Driven by the `skipped` stub rather than by hiding node, so the hook's
# rc-0-with-a-SKIPPED-header handling is pinned on every machine, including the
# ones where node cannot be hidden from PATH.
# ============================================================================
n1_skipped_is_announced_and_not_blocking() {
    local repo; repo="$(make_repo n1 skipped "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "N1/not-blocking" "0" "$RC"
    assert_absent "N1/no-blocked-notice" "$BLOCK_NOTICE" "$OUT$ERR"
    # Not an internal error: the scanner said "skipped", not "broken".
    assert_absent "N1/not-reported-as-rc-error" "$FAILOPEN_NOTICE" "$OUT$ERR"
    # ...and the announcement itself, on stderr, naming both the check and the
    # fact that it did not run.
    assert_contains "N1/announced-on-stderr" "comment-block" "$ERR"
    assert_contains "N1/announcement-says-skipped" "SKIPPED" "$ERR"
}

# ============================================================================
# N1b — the announcement is one line, not the scanner's whole output
#
# The failure this guards against is the lazy fix for N1: echoing the captured
# stdout on every skip. That prints a header block before every commit on a
# machine without node, which is how people learn to stop reading hook output.
# ============================================================================
n1b_announcement_is_one_line() {
    local repo; repo="$(make_repo n1b skipped "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    local lines
    # The hook's `pre-commit-section: <name>` progress markers are not announcements.
    lines="$(printf '%s\n' "$ERR" | grep -v '^pre-commit-section: ' | grep -c 'comment-block' || true)"
    assert_eq "N1b/single-announcement-line" "1" "$lines"
    assert_absent "N1b/no-scanner-header-on-stdout" "$SKIPPED_HEADER" "$OUT"
}

# ============================================================================
# N2 — a real commit lands while the scan is skipped
# ============================================================================
n2_commit_lands_when_skipped() {
    local repo; repo="$(make_repo n2 skipped "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir n2hooks "$repo")"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample"
    after="$(git -C "$repo" rev-parse HEAD)"
    assert_eq "N2/commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "N2/HEAD-advanced"
    else
        fail "N2/HEAD-advanced" "a skipped scan blocked the commit"
    fi
}

# ============================================================================
# N3 — the hook with node genuinely off PATH (#2507: the hook body is Node, so the
# adapter blocks rather than skipping every check unseen; the reason must be named).
# ============================================================================
n3_hook_blocks_without_node() {
    if [ "$NODE_HIDEABLE" != "1" ]; then
        skip "N3: node cannot be removed from PATH in this environment — real degraded-runtime path unverified"
        return
    fi
    local repo; repo="$(make_repo n3 real "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo" "PATH=$NO_NODE_PATH"
    assert_eq "N3/commit-blocked" "1" "$RC"
    assert_absent "N3/no-comment-block-verdict" "$BLOCK_NOTICE" "$OUT$ERR"
    assert_absent "N3/not-an-internal-error" "${FAILOPEN_NOTICE}3" "$OUT$ERR"
    assert_contains "N3/reason-names-node-on-stderr" "node not found on PATH" "$ERR"
    # The raw interpreter diagnostic must not be what the committer sees.
    assert_absent "N3/no-raw-enoent" "ENOENT" "$OUT$ERR"
    assert_absent "N3/no-command-not-found" "command not found" "$OUT$ERR"
}

# ============================================================================
# N4 — the CLI's own verdict under the same condition
#
# Asserted directly rather than through the hook, so a hook that swallowed the
# CLI's rc could not make this pass.
# ============================================================================
n4_cli_skips_at_rc_zero_without_node() {
    if [ "$NODE_HIDEABLE" != "1" ]; then
        skip "N4: node cannot be removed from PATH in this environment — CLI degraded verdict unverified"
        return
    fi
    if [ ! -f "$LOCAL_SCANNER" ]; then
        fail "N4: $LOCAL_SCANNER not found"
        return
    fi
    local repo; repo="$(make_repo n4 none "$NON_GITHUB")"
    stage_sample "$repo"
    local out rc=0
    out="$( (cd "$repo" \
        && run_with_timeout 60 env "${CB_ENV_RESET[@]}" \
            "PATH=$NO_NODE_PATH" "AGENTS_MAIN_ROOT=$repo" \
            bash "$LOCAL_SCANNER" --staged) 2>&1 )" || rc=$?
    assert_eq "N4/rc-is-0-not-3" "0" "$rc"
    assert_contains "N4/skipped-header" "SKIPPED" "$out"
    assert_contains "N4/reason-names-the-runtime" "node" "$out"
    # A skip is not a verdict: no finding line may be emitted for a scan that
    # never happened, or a degraded runtime becomes a source of false blocks.
    assert_absent "N4/no-finding-line" "BLOCK: " "$out"
}

n1_skipped_is_announced_and_not_blocking
n1b_announcement_is_one_line
n2_commit_lands_when_skipped
n3_hook_blocks_without_node
n4_cli_skips_at_rc_zero_without_node
