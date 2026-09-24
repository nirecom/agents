#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/no-bypass.sh
# Tests: hooks/block-comment-block-size.js, docs/architecture/claude-code/marker-bypass-contract.md
# Tags: comment-block-size, hook, pretooluse, no-bypass, workflow-off, worktree-off, omission, static-guard, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 5 — a property guaranteed by ABSENCE. Almost every other guard here
# honours the session-scoped escape hatches (WORKFLOW_OFF etc.); this one
# doesn't (outline plan: accepted tradeoff; intent.md requires both block
# paths non-bypassable). Implemented by omission — the hook never reads
# marker state — which is easy to lose: someone ADDS a bypass in good faith
# the first time it blocks them. Asserted twice (CPR-SC): behavioural (both
# markers present, verdict doesn't move) and static (source references no
# marker helpers — survives a future refactor). Static needs a positive
# control, or it degrades into "grep found nothing" once renamed.

# Sourced by the dispatcher; all helpers are defined there.

HK_SID="fixture-nobypass-0000"

# ============================================================================
# B1 — markers present, verdict unchanged
# ============================================================================
b1_markers_do_not_suspend_the_block() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "b1.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/b1.js"

    # Baseline: no markers.
    rm -f "$CLAUDE_WORKFLOW_DIR/$HK_SID".*
    hk_run "CLAUDE_SESSION_ID=$HK_SID" "CLAUDE_CODE_SESSION_ID=$HK_SID"
    assert_decision "B1/premise-blocked-without-markers" "block"

    local m
    for m in workflow-off worktree-off; do
        rm -f "$CLAUDE_WORKFLOW_DIR/$HK_SID".*
        printf '{"reason":"fixture"}\n' > "$CLAUDE_WORKFLOW_DIR/$HK_SID.$m"
        hk_run "CLAUDE_SESSION_ID=$HK_SID" "CLAUDE_CODE_SESSION_ID=$HK_SID"
        assert_decision "B1/$m-marker-does-not-suspend" "block"
    done

    # Both at once, which is what a session that has given up would actually do.
    printf '{"reason":"fixture"}\n' > "$CLAUDE_WORKFLOW_DIR/$HK_SID.workflow-off"
    printf '{"reason":"fixture"}\n' > "$CLAUDE_WORKFLOW_DIR/$HK_SID.worktree-off"
    hk_run "CLAUDE_SESSION_ID=$HK_SID" "CLAUDE_CODE_SESSION_ID=$HK_SID"
    assert_decision "B1/both-markers-do-not-suspend" "block"
    rm -f "$CLAUDE_WORKFLOW_DIR/$HK_SID".*
}

# ============================================================================
# B2 — the hook reads no marker state at all
# ============================================================================
b2_static_no_marker_reference() {
    if [ ! -f "$HOOK" ]; then
        fail "B2: $HOOK does not exist yet (issue #1894)"
        return
    fi
    local hits="" needle
    for needle in isWorkflowOff isWorktreeOff session-markers workflow-off worktree-off \
                  WORKFLOW_OFF WORKTREE_OFF markerPath resolveSessionId; do
        if grep -qF -- "$needle" "$HOOK"; then hits="$hits $needle"; fi
    done
    if [ -z "$hits" ]; then
        pass "B2: the hook references no session-marker machinery"
    else
        fail "B2: hooks/block-comment-block-size.js references:$hits" \
             "This hook is deliberately not suspendable — the guarantee is that it never asks."
    fi
}

b2b_static_control() {
    # Without this, B2 passes trivially the moment the marker helpers are
    # renamed, and the rename is exactly when the guarantee needs re-checking.
    local ref="$AGENTS_DIR/hooks/enforce-worktree.js"
    if [ ! -f "$ref" ]; then
        skip "B2b: hooks/enforce-worktree.js not found — cannot control the marker-name grep"
        return
    fi
    local found="" needle
    for needle in isWorkflowOff isWorktreeOff; do
        if grep -qF -- "$needle" "$ref"; then found="$found $needle"; fi
    done
    if [ -n "$found" ]; then
        pass "B2b/control: the marker helper names B2 greps for are still in use ($found)"
    else
        fail "B2b/control: hooks/enforce-worktree.js references none of the names B2 greps for" \
             "The marker layer was probably renamed; B2's absence assertion is now vacuous."
    fi
}

# ============================================================================
# B3 — no environment variable turns it off either
#
# A bypass does not have to be a marker file. An implementation that quietly
# grew a CLAUDE_SKIP_* or *_OFF escape would satisfy B1 and B2 while handing
# back the same one-word disable the .env-only rule was written to remove.
# ============================================================================
b3_no_ad_hoc_env_escape() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "b3.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/b3.js"
    local v
    for v in WORKFLOW_OFF=1 WORKTREE_OFF=1 ENFORCE_WORKTREE=off \
             CLAUDE_SKIP_HOOKS=1 SKIP_COMMENT_BLOCK=1 AGENTS_HOOK_DISABLE=1; do
        hk_run "$v"
        assert_decision "B3/[$v]-does-not-disable" "block"
    done
}

# ============================================================================
# B4 — the bypass contract document lists this hook as non-honoring
#
# docs/architecture/claude-code/marker-bypass-contract.md is the SSOT for which
# hooks the markers suspend. A new blocking hook that is missing from it leaves
# the next reader guessing — and the guess a reader makes about an escape hatch
# is the one that gets acted on.
# ============================================================================
b4_documented_as_non_honoring() {
    local doc="$AGENTS_DIR/docs/architecture/claude-code/marker-bypass-contract.md"
    if [ ! -f "$doc" ]; then
        skip "B4: $doc not found — bypass contract table unavailable"
        return
    fi
    if grep -qF 'block-comment-block-size.js' "$doc"; then
        pass "B4: the hook appears in the marker-bypass contract"
    else
        fail "B4: marker-bypass-contract.md does not mention block-comment-block-size.js" \
             "Issue #1894 adds the row marking it non-honoring for both markers."
    fi
}

b1_markers_do_not_suspend_the_block
b2_static_no_marker_reference
b2b_static_control
b3_no_ad_hoc_env_escape
b4_documented_as_non_honoring
