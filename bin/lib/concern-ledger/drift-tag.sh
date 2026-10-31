#!/usr/bin/env bash
# bin/lib/concern-ledger/drift-tag.sh — the single owner of the [glossary-drift …]
# concern tag (#2529). A tagged concern is never rejected; only cl_accept closes it,
# and only when bin/check-glossary-ledger-grant confirms a WORKFLOW_GLOSSARY_ACCEPTED
# grant for its term AND DISCRIM. Every failure on the accept path refuses (rc 4).
# Sourced by bin/lib/concern-ledger.sh; no `set -e` (a sourced library).

CL_DRIFT_TAG_PREFIX='[glossary-drift '
CL_DRIFT_TERM_RE='\[glossary-drift term=([^]|]+)\]'
CL_DRIFT_ACCEPT_LABEL='accepted(glossary-drift)'
# The grant reader ships beside this library, so it is resolved from this file's own
# checkout — never from the main worktree, which may predate it while a linked worktree adds it.
CL_DRIFT_GRANT_CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/check-glossary-ledger-grant"

# cl_is_drift_tagged <text> — 0 when the text carries the tag, 1 otherwise.
cl_is_drift_tagged() {
    case "$1" in *"$CL_DRIFT_TAG_PREFIX"*) return 0 ;; esac
    return 1
}

# cl_drift_term <text> — the tag's term (term= as the first field), or nothing.
cl_drift_term() {
    if [[ "$1" =~ $CL_DRIFT_TERM_RE ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
    return 0
}

# _cl_drift_row <ledger> <id> — the target row, or rc 1 when absent.
_cl_drift_row() {
    [ -f "$1" ] || return 1
    local row
    row="$(grep -m1 -E "^${2}\|" "$1" 2>/dev/null)" || return 1
    [ -n "$row" ] || return 1
    printf '%s' "$row"
}

# cl_guard_reject <ledger> <id> — 4 when the target concern is tagged, else 0.
# Grants are never consulted: reject of a tagged concern is refused unconditionally.
cl_guard_reject() {
    local row rest
    row="$(_cl_drift_row "$1" "$2")" || return 0
    IFS='|' read -r _ _ _ _ _ _ _ _ _ _ rest <<< "$row"
    cl_is_drift_tagged "$rest" && return 4
    return 0
}

# _cl_drift_granted <text> <discrim> <sid> <format> — 0 when a grant covers the tag's term.
_cl_drift_granted() {
    local term
    term="$(cl_drift_term "$1")"
    [ -n "$term" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] || return 1
    [ -f "$CL_DRIFT_GRANT_CLI" ] || return 1
    node "$CL_DRIFT_GRANT_CLI" --session "$3" --format "$4" \
        --norm "$term" --discrim "$2" >/dev/null 2>&1 || return 1
}

# cl_accept <ledger> <id> <reason> <sid> <format> — close a tagged concern under a
# matching grant. 0 written; 2 the concern is untagged; 4 refused (no ledger, no
# row, no term, no grant, or the grant reader could not answer); 1 write failure.
cl_accept() {
    local ledger="$1" id="$2" reason="$3" sid="${4:-}" format="${5:-}"
    local row f7 rest
    row="$(_cl_drift_row "$ledger" "$id")" || return 4
    IFS='|' read -r _ _ _ _ _ _ f7 _ _ _ rest <<< "$row"
    # #2814: an [upstream-inconsistency …] concern closes on the user's recorded C; one that
    # also carries the glossary-drift tag needs its grant as well (both decisions, either order).
    if cl_is_upstream_tagged "$rest"; then
        if cl_is_drift_tagged "$rest"; then _cl_drift_granted "$rest" "$f7" "$sid" "$format" || return 4; fi
        cl_upstream_accept "$ledger" "$id" "$reason"; return $?
    fi
    cl_is_drift_tagged "$rest" || return 2
    _cl_drift_granted "$rest" "$f7" "$sid" "$format" || return 4
    _cl_dismiss_write "$ledger" "$id" "$reason" "$CL_DRIFT_ACCEPT_LABEL" || return 1
    return 0
}

# cl_list_drift <ledger> — "DISCRIM<TAB>term" per tagged concern still open or
# reopened. No ledger is an empty success; an unreadable ledger is rc 1.
cl_list_drift() {
    local ledger="$1" line f3 f7 rest
    [ -e "$ledger" ] || return 0
    [ -r "$ledger" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in C[0-9]*"|"*) ;; *) continue ;; esac
        IFS='|' read -r _ _ f3 _ _ _ f7 _ _ _ rest <<< "$line"
        case "$f3" in open|reopened) ;; *) continue ;; esac
        cl_is_drift_tagged "$rest" || continue
        printf '%s\t%s\n' "$f7" "$(cl_drift_term "$rest")"
    done < "$ledger" || return 1
    return 0
}

:  # load-success rc for the entrypoint's source check
