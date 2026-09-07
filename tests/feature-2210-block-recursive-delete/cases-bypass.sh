# tests/feature-2210-block-recursive-delete/cases-bypass.sh
# Tests: hooks/block-recursive-delete.js
# Tags: scope:issue-specific, recursive-delete, hook, bypass, unconditional-guard, TL2, pwsh-not-required
#
# C4: this hook joins the No/No unconditional-guard family in
# docs/architecture/claude-code/marker-bypass-contract.md — it must keep
# blocking regardless of any session-off marker or bypass env var. Env
# assignments below are prefixed on the single command they apply to (never
# `export`), so nothing leaks into a later case (MEDIUM: stale env vars).
# TL3 gap: markers/env vars are simulated, not produced by a real session.

run_bypass_cases() {
    echo ""
    echo "=== Bypass markers/env vars have zero effect (unconditional guard) ==="

    local wf_dir1 wf_dir2 wf_dir3 wf_dir4 sid out verdict

    # A real, resolvable session ID with a .workflow-off marker file present
    # for it — the actual mechanism <<WORKFLOW_ENFORCE_WORKFLOW_OFF>> creates.
    wf_dir1="$(mktemp -d)"
    sid="00000000-0000-4000-8000-000000000210"
    : > "$wf_dir1/$sid.workflow-off"
    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir1" WORKFLOW_PLANS_DIR="$wf_dir1" run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass ".workflow-off marker for the active session does not bypass the guard"
    else fail ".workflow-off marker present — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir1" 2>/dev/null

    # Same mechanism, .worktree-off marker — its OWN directory (C9: reusing an
    # already-deleted dir here previously left this case running against a
    # nonexistent path).
    wf_dir2="$(mktemp -d)"
    : > "$wf_dir2/$sid.worktree-off"
    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir2" WORKFLOW_PLANS_DIR="$wf_dir2" run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass ".worktree-off marker for the active session does not bypass the guard"
    else fail ".worktree-off marker present — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir2" 2>/dev/null

    # SYSTEM_OPS_APPROVED=1 (rules/user-escalation.md: never honored inline for
    # enforce-system-ops.js either) — this hook defines no such variable at all.
    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | SYSTEM_OPS_APPROVED=1 run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "SYSTEM_OPS_APPROVED=1 does not bypass the guard"
    else fail "SYSTEM_OPS_APPROVED=1 — expected block, got '$verdict'"; fi

    # ENFORCE_WORKTREE=off (rules/git.md's emergency force-push override) — a
    # different hook family's env spelling; this hook must not read it at all.
    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | ENFORCE_WORKTREE=off run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "ENFORCE_WORKTREE=off does not bypass the guard"
    else fail "ENFORCE_WORKTREE=off — expected block, got '$verdict'"; fi

    # A pwsh-shaped positive too, so the check is not limited to rm.js alone
    # (CPR-ORTH across the three per-segment judgments). True stacking (C9):
    # a fresh dir carrying BOTH marker files at once, not a since-deleted one.
    wf_dir3="$(mktemp -d)"
    : > "$wf_dir3/$sid.workflow-off"
    : > "$wf_dir3/$sid.worktree-off"
    out="$(printf '%s' "$(payload_cmd 'Remove-Item -Recurse dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir3" WORKFLOW_PLANS_DIR="$wf_dir3" SYSTEM_OPS_APPROVED=1 run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "stacked markers/env vars do not bypass a PowerShell-shaped delete"
    else fail "stacked markers/env vars (pwsh target) — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir3" 2>/dev/null

    # C9: a cmd.exe-shaped positive too (CPR-ORTH across all three segment
    # families) — its own fresh dir carrying BOTH marker files at once.
    wf_dir4="$(mktemp -d)"
    : > "$wf_dir4/$sid.workflow-off"
    : > "$wf_dir4/$sid.worktree-off"
    out="$(printf '%s' "$(payload_cmd 'cmd /c rmdir /s dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir4" WORKFLOW_PLANS_DIR="$wf_dir4" SYSTEM_OPS_APPROVED=1 run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "stacked markers/env vars do not bypass a cmd.exe-shaped delete (C9)"
    else fail "stacked markers/env vars (cmd.exe target) — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir4" 2>/dev/null
}
