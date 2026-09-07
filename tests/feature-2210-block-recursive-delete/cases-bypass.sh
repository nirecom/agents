# tests/feature-2210-block-recursive-delete/cases-bypass.sh
# Tests: hooks/block-recursive-delete.js
# Tags: scope:issue-specific, recursive-delete, hook, bypass, unconditional-guard, TL2, pwsh-not-required
#
# Unconditional-guard family (marker-bypass-contract.md): no session-off marker
# or env var may lift it. TL3 gap: markers are simulated, not session-produced.

run_bypass_cases() {
    echo ""
    echo "=== Bypass markers/env vars have zero effect (unconditional guard) ==="

    local wf_dir1 wf_dir2 wf_dir3 wf_dir4 sid out verdict

    # Env vars stay prefixed per command, never exported, so none leaks into a
    # later case. Each marker file is the real artifact the sentinel creates.
    wf_dir1="$(mktemp -d)"
    sid="00000000-0000-4000-8000-000000000210"
    : > "$wf_dir1/$sid.workflow-off"
    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir1" WORKFLOW_PLANS_DIR="$wf_dir1" run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass ".workflow-off marker for the active session does not bypass the guard"
    else fail ".workflow-off marker present — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir1" 2>/dev/null

    # Its OWN directory: reusing the deleted one left this case pointing nowhere.
    wf_dir2="$(mktemp -d)"
    : > "$wf_dir2/$sid.worktree-off"
    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir2" WORKFLOW_PLANS_DIR="$wf_dir2" run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass ".worktree-off marker for the active session does not bypass the guard"
    else fail ".worktree-off marker present — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir2" 2>/dev/null

    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | SYSTEM_OPS_APPROVED=1 run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "SYSTEM_OPS_APPROVED=1 does not bypass the guard"
    else fail "SYSTEM_OPS_APPROVED=1 — expected block, got '$verdict'"; fi

    out="$(printf '%s' "$(payload_cmd 'rm -rf dir')" | ENFORCE_WORKTREE=off run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "ENFORCE_WORKTREE=off does not bypass the guard"
    else fail "ENFORCE_WORKTREE=off — expected block, got '$verdict'"; fi

    # CPR-ORTH: the same guarantee for the pwsh judgment, with both markers at once.
    wf_dir3="$(mktemp -d)"
    : > "$wf_dir3/$sid.workflow-off"
    : > "$wf_dir3/$sid.worktree-off"
    out="$(printf '%s' "$(payload_cmd 'Remove-Item -Recurse dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir3" WORKFLOW_PLANS_DIR="$wf_dir3" SYSTEM_OPS_APPROVED=1 run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "stacked markers/env vars do not bypass a PowerShell-shaped delete"
    else fail "stacked markers/env vars (pwsh target) — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir3" 2>/dev/null

    # CPR-ORTH: and for the third segment family, cmd.exe.
    wf_dir4="$(mktemp -d)"
    : > "$wf_dir4/$sid.workflow-off"
    : > "$wf_dir4/$sid.worktree-off"
    out="$(printf '%s' "$(payload_cmd 'cmd /c rmdir /s dir')" | CLAUDE_SESSION_ID="$sid" CLAUDE_WORKFLOW_DIR="$wf_dir4" WORKFLOW_PLANS_DIR="$wf_dir4" SYSTEM_OPS_APPROVED=1 run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then pass "stacked markers/env vars do not bypass a cmd.exe-shaped delete (C9)"
    else fail "stacked markers/env vars (cmd.exe target) — expected block, got '$verdict'"; fi
    rm -rf "$wf_dir4" 2>/dev/null
}
