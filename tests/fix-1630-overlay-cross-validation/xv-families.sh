# tests/fix-1630-overlay-cross-validation/xv-families.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, config-dir, overlay, security, scope:issue-specific
#
# #1673 deleted finalize-worker-overlay.js along with the Bash-tool `eval` path
# it guarded, so the whole file is now BLOCK-only: the XV-* mismatch families
# were block before and stay block, and the VALUE-* rows — which used to prove
# that env-prefix values are compared by RESOLVED PATH VALUE rather than by
# string equality — now block too, because no `eval` of a finalize script is
# allowed from a main worktree at all. They are kept as retired-capability pins.
#
# The resolved-path-value semantics they measured did not disappear; they moved
# with the helpers into hooks/enforce-worktree/arg-value-guard.js and are pinned
# at unit level by strip-units.sh (STRIP-*) and metachar-args.sh (ARG-tok-*),
# which remain the non-vacuous half of this suite.
#
# Sourced by tests/fix-1630-overlay-cross-validation.sh.
#
# Fixture variables (XV_REPO / XV_ACD / XV_PLANS / XV_OTHER / XV_SIBLING /
# XV_SCRIPTS / XV_STATE / XV_OUTCOME) are assigned as GLOBALS on purpose:
# strip-units.sh and mutation.sh reuse them.

run_xv_family_cases() {
    # ============================================================================
    # XV-* — three candidate-mismatch families. The invoked script path implies a
    # root (via the registry's relative suffix) that is NOT a resolver candidate.
    # All three must BLOCK before AND after C5 (protection-fix negative assertions).
    # ============================================================================
    XV_REPO="$(setup_main_worktree "xv")"
    XV_ACD="$(setup_fake_acd "xv")"
    XV_PLANS="$(setup_plans_dir "xv")"
    XV_SCRIPTS="$XV_ACD/skills/issue-close-finalize/scripts"
    XV_STATE="$XV_PLANS/sid-finalize-state-1234.json"
    XV_OUTCOME="$XV_PLANS/sid-issue-close-outcome.json"

    # Family 1 — sibling-prefix root: "<acd>-evil" shares a string prefix with the
    # real candidate but is a different directory.
    XV_SIBLING_RAW="$TMPDIR_BASE/fake-acd-xv-evil"
    mkdir -p "$XV_SIBLING_RAW/skills/issue-close-finalize/scripts" "$XV_SIBLING_RAW/bin" "$XV_SIBLING_RAW/hooks"
    touch "$XV_SIBLING_RAW/hooks/enforce-worktree.js" \
          "$XV_SIBLING_RAW/skills/issue-close-finalize/scripts/run-initial.sh"
    if command -v cygpath >/dev/null 2>&1; then XV_SIBLING="$(cygpath -m "$XV_SIBLING_RAW")"; else XV_SIBLING="$XV_SIBLING_RAW"; fi

    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_SIBLING" "$XV_SIBLING/skills/issue-close-finalize/scripts" "$XV_REPO" "$XV_SIBLING/skills/issue-close-finalize/scripts")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "XV-1 sibling-prefix root (<acd>-evil) is not a resolver candidate" "$rc"

    # Family 2 — path-traversal root: textually contains the real candidate but
    # resolves elsewhere.
    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_ACD/../fake-acd-xv-evil" "$XV_ACD/../fake-acd-xv-evil/skills/issue-close-finalize/scripts" "$XV_REPO" "$XV_ACD/../fake-acd-xv-evil/skills/issue-close-finalize/scripts")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "XV-2 path-traversal root (<acd>/../evil) is not a resolver candidate" "$rc"

    # Family 3 — unrelated marker-valid root: the attacker dir carries both markers
    # but is named by nothing the resolver would produce.
    XV_OTHER_RAW="$TMPDIR_BASE/unrelated-acd"
    mkdir -p "$XV_OTHER_RAW/skills/issue-close-finalize/scripts" "$XV_OTHER_RAW/bin" "$XV_OTHER_RAW/hooks"
    touch "$XV_OTHER_RAW/hooks/enforce-worktree.js" \
          "$XV_OTHER_RAW/skills/issue-close-finalize/scripts/run-loop-step.js"
    if command -v cygpath >/dev/null 2>&1; then XV_OTHER="$(cygpath -m "$XV_OTHER_RAW")"; else XV_OTHER="$XV_OTHER_RAW"; fi

    rc=0
    run_guard "$(build_bash_payload "$(build_loop_step "$XV_OTHER" "$XV_OTHER/skills/issue-close-finalize/scripts" "$XV_OTHER/skills/issue-close-finalize/scripts" "$XV_STATE" "accept")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "XV-3 unrelated marker-valid root is not a resolver candidate" "$rc"

    # Mixed-root variant: the inline env values name the real candidate while the
    # script path is rooted at the attacker dir — the three-way check must catch the
    # disagreement rather than trusting the env prefix alone.
    rc=0
    run_guard "$(build_bash_payload "$(build_finalize_terminal "$XV_ACD" "$XV_OTHER/skills/issue-close-finalize/scripts" "$XV_STATE" "1234" "$XV_OUTCOME")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "XV-4 inline env names the real root but the script path does not" "$rc"

    # ============================================================================
    # VALUE-* — these three were the ALLOW side of the value-vs-string axis: an
    # inline env value that differs only by a trailing slash or a `/./` segment
    # names the SAME directory, so it had to keep matching. #1673 retired the
    # `eval` capability outright, so the correct verdict for all three is now
    # BLOCK. Kept (rather than deleted) as retired-capability pins: the shapes a
    # legitimate caller once used must not be re-opened by accident either.
    # ============================================================================
    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_ACD/" "$XV_SCRIPTS" "$XV_REPO" "$XV_SCRIPTS")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "VALUE-1 trailing slash on the inline AGENTS_CONFIG_DIR value — eval path retired (#1673)" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_ACD/./" "$XV_SCRIPTS" "$XV_REPO" "$XV_SCRIPTS")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "VALUE-2 '/./' segment in the inline AGENTS_CONFIG_DIR value — eval path retired (#1673)" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_ACD" "$XV_SCRIPTS" "$XV_REPO/" "$XV_SCRIPTS")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "VALUE-3 trailing slash on the inline MAIN_WORKTREE_PATH value — eval path retired (#1673)" "$rc"

    # Negative side of the same axis: value semantics must not degrade into prefix
    # matching — a longer path that merely STARTS with the candidate is not equal.
    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_ACD/skills" "$XV_SCRIPTS" "$XV_REPO" "$XV_SCRIPTS")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "VALUE-4 a sub-path of the candidate is not an equal value" "$rc"


    # ============================================================================
    # C8 (Protection Pattern 1) — canary. The XV rows above assert a guard verdict;
    # a verdict alone cannot see a guard that blocks AFTER touching the filesystem.
    # The mismatch payloads below name a canary file that lives in a throwaway temp
    # dir (never in the repo); it must be byte-identical afterwards.
    # ============================================================================
    # The canary lives inside the throwaway fixture MAIN worktree ($TMPDIR_BASE/xv),
    # never in this repo: a write target outside any registered repo is simply out of
    # the hook's scope, so a canary in a neutral temp dir would make the redirect row
    # vacuously ALLOW and prove nothing.
    CANARY_DIR="$TMPDIR_BASE/xv/docs/canary"
    mkdir -p "$CANARY_DIR"
    CANARY="$CANARY_DIR/protected.txt"
    printf 'CANARY-XV-INTACT\n' > "$CANARY"
    CANARY_BEFORE="$(cat "$CANARY")"
    if command -v cygpath >/dev/null 2>&1; then CANARY_NODE="$(cygpath -m "$CANARY")"; else CANARY_NODE="$CANARY"; fi

    rc=0
    run_guard "$(build_bash_payload "$(build_initial "$XV_SIBLING" "$XV_SIBLING/skills/issue-close-finalize/scripts" "$XV_REPO" "$XV_SIBLING/skills/issue-close-finalize/scripts") > \"$CANARY_NODE\"")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "XV-canary overlay mismatch with a redirect onto a protected file stays blocked" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_loop_step "$XV_OTHER" "$XV_OTHER/skills/issue-close-finalize/scripts" "$XV_OTHER/skills/issue-close-finalize/scripts" "$XV_STATE" "accept\"; : > \"$CANARY_NODE")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "XV-canary overlay mismatch with chaining onto a protected file stays blocked" "$rc"

    if [ -f "$CANARY" ] && [ "$(cat "$CANARY")" = "$CANARY_BEFORE" ]; then
        pass "XV-canary protected file unchanged after the overlay-mismatch attacks"
    else
        fail "XV-canary protected file was modified or removed by an overlay-mismatch attack"
    fi
}
