# tests/fix-1630-overlay-cross-validation/strip-units.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# Tags: worktree, enforce, hook, config-dir, overlay, unit, scope:issue-specific
#
# STATUS: RED until C5 lands. Sourced by tests/fix-1630-overlay-cross-validation.sh.
#   STRIP-* — stripRelSuffix is not exported yet (ERROR: ... is not exported).
#   CAND-*  — identification is still join-equality against a single acd value.
#
# STRIP-* / CAND-* — stripRelSuffix units and candidate acceptance, asserted on
# the overlay module directly rather than through a hook verdict.

overlay_probe() { run_with_timeout 30 node "$OVERLAY_PROBE" "$@" 2>&1; }

run_strip_table() {
    local name op a1 a2 want
    while IFS='|' read -r name op a1 a2 want; do
        name="$(_trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        assert_eq "$name" "$(overlay_probe "$(_trim "$op")" "$(_trim "$a1")" "$(_trim "$a2")")" "$(_trim "$want")"
    done
}

run_strip_unit_cases() {
    run_strip_table <<'TABLE'
STRIP-exact        | strip | C:/a/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a
STRIP-nested-root  | strip | C:/a/b/c/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a/b/c
STRIP-backslash    | strip | C:\a\skills\issue-close-finalize\scripts\run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | c:/a
STRIP-wrong-suffix | strip | C:/a/skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-loop-step.js | null
STRIP-partial-seg  | strip | C:/a/xskills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | null
STRIP-suffix-only  | strip | skills/issue-close-finalize/scripts/run-initial.sh | skills/issue-close-finalize/scripts/run-initial.sh | null
STRIP-empty-path   | strip |  | skills/issue-close-finalize/scripts/run-initial.sh | null
STRIP-empty-rel    | strip | C:/a/skills/issue-close-finalize/scripts/run-initial.sh |  | null
TABLE

    # Candidate acceptance: a script rooted at ANY valid resolver candidate is
    # identified. RED today — identification is join-equality against a single acd.
    CAND_ACD="$(setup_fake_acd "cand")"
    CAND_REPO="$(setup_main_worktree "cand")"
    CAND_SCRIPTS="$CAND_ACD/skills/issue-close-finalize/scripts"
    CAND_CMD="$(build_initial "$CAND_ACD" "$CAND_SCRIPTS" "$CAND_REPO" "$CAND_SCRIPTS")"

    assert_eq "CAND-accept root named by the env candidate" \
        "$(AGENTS_CONFIG_DIR="$CAND_ACD" overlay_probe match "$CAND_CMD" "$CAND_REPO")" "run-initial.sh"
    assert_eq "CAND-accept root reachable when the env candidate is stale" \
        "$(AGENTS_CONFIG_DIR="$TMPDIR_BASE" overlay_probe match "$CAND_CMD" "$CAND_REPO")" "null"
    assert_eq "CAND-reject root that is no candidate at all" \
        "$(AGENTS_CONFIG_DIR="$CAND_ACD" overlay_probe match "$(build_initial "$XV_OTHER" "$XV_OTHER/skills/issue-close-finalize/scripts" "$CAND_REPO" "$XV_OTHER/skills/issue-close-finalize/scripts")" "$CAND_REPO")" "null"
}
