# board-create.sh — shared helpers for the two paths that create a repo's Projects v2 board (sourced).
# project_board_title <owner/repo> — prints "<owner/repo> — Issue Timeline" (U+2014), the only title rule.
# project_board_discard_unlinked <owner> <number> <owner/repo> — deletes a board just created whose link to
#   the repo failed (an unlinked board would make the next resolve no-link and create a duplicate).
#   rc 0 when deleted; rc 1 with the two manual recovery steps on stderr when the delete fails too.

project_board_title() {
    printf '%s — Issue Timeline\n' "${1:?owner/repo required}"
}

project_board_discard_unlinked() {
    local owner="${1:?owner required}" num="${2:?number required}" owner_repo="${3:?owner/repo required}"
    if gh project delete "$num" --owner "$owner" >/dev/null 2>&1; then
        echo "error: linking the new board #$num to $owner_repo failed, so the board was deleted; fix the cause and re-run." >&2
        return 0
    fi
    echo "error: linking the new board #$num to $owner_repo failed, and deleting it failed too. Run one of, then re-run:" >&2
    echo "  keep it:    gh project link $num --owner $owner --repo $owner_repo" >&2
    echo "  discard it: gh project delete $num --owner $owner" >&2
    return 1
}
