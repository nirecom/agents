#!/bin/bash
# issue-close-triage-lib.sh — shared helpers for issue-close-{stage,finalize}-triage.sh
# and check-phase1-complete.sh.
#
# Source guard prevents double-load when both a triage script and a caller
# source this file in the same shell.

[ -n "${ISSUE_CLOSE_LIB_LOADED:-}" ] && return 0
ISSUE_CLOSE_LIB_LOADED=1

# parse_sentinel <raw-comment-body>
#   Extracts the sentinel state token (e.g. "pending", "appended") from a
#   sentinel comment body. Prints empty string when no match.
parse_sentinel() {
    local raw="$1"
    printf '%s' "$raw" | sed -nE 's/^<!-- issue-close-sentinel: ([a-z]+).*-->.*/\1/p'
}

# check_history_entry <N>
#   Returns 0 if issue #N has a history entry that is ACTUALLY committed
#   on the current branch (not merely present in the working tree).
#
#   AND of two checks:
#     (a) docs/history.md (or docs/history/*.md) contains an entry header
#         referencing #N in the structured header position. Patterns:
#           ^### #N:                            (incident style)
#           ^### .+\(#N[,) ]                    (regular style — issue in header parens)
#     (b) at least one commit reachable from HEAD touches docs/history.md
#         or docs/history/ and mentions #N in its message.
#
#   (b) is the stronger guarantee: it proves the entry survived through
#   commit, not just was written to the working tree.
#
#   CWD must be a working tree root containing docs/history.md.
check_history_entry() {
    local n="$1"
    local pattern="^### (#${n}:|[^#].*#${n}[,) ])"

    # (a) header-style file content check + (b) commit reachability check.
    # Subshell with set +o pipefail: grep -q exits early (SIGPIPE to git log) but
    # the overall exit code is grep's, not git log's 141.
    if grep -qE "$pattern" docs/history.md 2>/dev/null; then
        if ( set +o pipefail; git log --oneline HEAD -- docs/history.md docs/history/ \
            2>/dev/null | grep -qE "#${n}([^0-9]|$)" ); then
            return 0
        fi
    fi

    # Same for archived history under docs/history/*.md.
    if grep -rqE "$pattern" docs/history/ 2>/dev/null; then
        if ( set +o pipefail; git log --oneline HEAD -- docs/history.md docs/history/ \
            2>/dev/null | grep -qE "#${n}([^0-9]|$)" ); then
            return 0
        fi
    fi

    return 1
}

# print_triage_output <state> <sentinel> <action> <next_steps>
#   Emits the eval-able shell assignments used by stage/finalize triage scripts.
print_triage_output() {
    local state="$1" sentinel="$2" action="$3" next_steps="$4"
    printf 'STATE=%s\n' "$state"
    printf 'SENTINEL=%s\n' "$sentinel"
    printf 'ACTION=%s\n' "$action"
    printf 'NEXT_STEPS=%s\n' "$next_steps"
}
