# board-create.sh — shared helpers for the two paths that create a repo's Projects v2 board (sourced).
# project_board_title <owner/repo> — prints "<owner/repo> — Issue Timeline" (U+2014), the only title rule.
# project_board_discard_unlinked <owner> <number> <owner/repo> — deletes a board just created whose link to
#   the repo failed (an unlinked board would make the next resolve no-link and create a duplicate).
#   rc 0 when deleted; rc 1 with the two manual recovery steps on stderr when the delete fails too.

project_board_title() {
    printf '%s — Issue Timeline\n' "${1:?owner/repo required}"
}

# project_board_refuse_duplicate <owner> <owner/repo> — the title is a duplicate guard here, never a selector.
#   rc 0: no owner board carries the repo's title (current or old "<repo> — Issue Timeline" form), so a create may go on.
#   rc 1: one does (or the list failed), so nothing is created; stderr names the `gh project link` to run.
project_board_refuse_duplicate() {
    local owner="${1:?owner required}" owner_repo="${2:?owner/repo required}" listing num
    if ! listing=$(gh project list --owner "$owner" --format json --limit 200 2>/dev/null); then
        echo "error: could not list $owner's boards to check for a same-titled one; nothing created" >&2
        return 1
    fi
    num=$(printf '%s' "$listing" | jq -r --arg a "$(project_board_title "$owner_repo")" --arg b "$(project_board_title "${owner_repo#*/}")" \
        '[.projects[]? | select(.title == $a or .title == $b) | .number] | first // empty' 2>/dev/null | tr -d '\r')
    [ -z "$num" ] && return 0
    echo "error: board #$num already has this repo's title but is not linked to $owner_repo; nothing created. Link it, then re-run:" >&2
    echo "  gh project link $num --owner $owner --repo $owner_repo" >&2
    return 1
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
