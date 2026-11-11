# shellcheck shell=bash
# bin/lib/gh-user-block-guard.sh — `<user>` block guard for wrappers that write GitHub issues (#2940).
# The judgement is bin/user-block-guard (contract in bin/user-block-guard.d/main.js); this lib
# only maps its exit code for a wrapper, which cannot show an approval dialog.
#
#   gh_user_block_guard <label> <cli-args…>
#     return 0 = the CLI allowed (rc 0); return 1 = anything else (deny, ask, usage, missing CLI)
#   On return 1, GH_USER_BLOCK_GUARD_MESSAGE holds the reason (also printed on stderr).
# Body files go in as --new-body-file "$(native_path "$tmp")". Sourced: never exits, only returns.
# Never call it on the right-hand side of a pipe: the message variable would not reach the caller.

_ghubg_block() {
    GH_USER_BLOCK_GUARD_MESSAGE="[$1] $2 — wrapper 経路は承認できない。ユーザーが直接編集する"  # lang-check: ignore (user-facing text)
    printf '%s\n' "$GH_USER_BLOCK_GUARD_MESSAGE" >&2
}

gh_user_block_guard() {
    GH_USER_BLOCK_GUARD_MESSAGE=""
    local label="${1:-user-block-guard}"
    [ $# -gt 0 ] && shift

    local bindir cli
    bindir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    cli="$bindir/user-block-guard"
    if [ -z "$bindir" ] || [ ! -f "$cli" ]; then
        _ghubg_block "$label" "user-block-guard: bin/user-block-guard が見つからない (fail-closed)"
        return 1
    fi
    if command -v cygpath >/dev/null 2>&1; then
        cli="$(cygpath -m -- "$cli" 2>/dev/null)" || cli="$bindir/user-block-guard"
    fi

    local out="" rc=0
    out="$(node "$cli" "$@")" || rc=$?
    [ "$rc" -eq 0 ] && return 0

    local reason="${out%%$'\n'*}"
    [ -n "$reason" ] || reason="user-block-guard: rc=$rc"
    _ghubg_block "$label" "$reason"
    return 1
}
