# tests/fix-1630-overlay-cross-validation/strip-units.sh
# Tests: hooks/enforce-worktree/arg-value-guard.js
# Tags: worktree, enforce, hook, config-dir, overlay, unit, scope:issue-specific
#
# Sourced by tests/fix-1630-overlay-cross-validation.sh.
#
# STRIP-* — stripRelSuffix units, asserted on the module directly rather than
# through a hook verdict. These are the LIVE half of this suite: #1673 moved
# stripRelSuffix unchanged from the deleted finalize-worker-overlay.js into
# hooks/enforce-worktree/arg-value-guard.js, where worker-dispatch-overlay.js
# now consumes it, so every row below still measures shipped behaviour.
#
# The CAND-* rows that used to follow are gone with #1673: they asked
# matchFinalizeWorkerOverlay which root a finalize `eval` implied, and both the
# function and the `eval` capability were deleted. The equivalent question for
# the dispatcher — which anchor a worker script resolves against — is owned by
# tests/feature-1643-worker-dispatch-callers.sh and the TL3-worker-dispatch-*
# suites, not by a probe over a module that no longer exists.

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
}
