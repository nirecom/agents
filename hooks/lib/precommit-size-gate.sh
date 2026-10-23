#!/bin/bash
# Sourced by hooks/pre-commit (#2631). The agents repo's last line of defence on file size:
# one bin/size-check call judges every staged file against hooks/lib/size-limits.js.
# rc 1 (HARD), rc 2 (usage error: a broken install) and rc 3 (infrastructure) all block (fail-closed).
# Reads $_cfg_dir and _is_agents_session_repo from hooks/pre-commit (ambient).

_precommit_size_gate() {
    local _sz_top _sz_out _sz_rc
    _sz_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$_sz_top" ]] || return 0
    (unset GIT_DIR GIT_WORK_TREE GIT_PREFIX; _is_agents_session_repo "$_sz_top") || return 0
    _sz_out=""
    _sz_rc=0
    _sz_out="$(node "$_cfg_dir/bin/size-check" --staged-auto --session-gate)" || _sz_rc=$?
    case "$_sz_rc" in
        0)
            printf '%s\n' "$_sz_out" | grep -E '^(WARN|SHRINK)'$'\t' >&2 || true
            ;;
        1)
            printf '%s\n' "$_sz_out" | grep -E '^(HARD|WARN|SHRINK)'$'\t' || true
            echo ""
            echo "Commit blocked: staged files exceed the HARD size limit (record: verdict value pre warn hard unit path)."
            echo "Shrink or split them — see rules/coding/file-split.md."
            exit 1
            ;;
        2)
            echo "Commit blocked: size-check usage error (rc=2) — the size gate is misinstalled." >&2
            exit 1
            ;;
        *)
            echo "Commit blocked: size-check could not finish (rc=$_sz_rc, infrastructure error) — the size gate fails closed." >&2
            echo "Fix the git/read error reported above and commit again." >&2
            exit 1
            ;;
    esac
}
