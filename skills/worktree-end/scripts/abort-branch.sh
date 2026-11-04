#!/usr/bin/env bash
# skills/worktree-end/scripts/abort-branch.sh — the scripted parts of the /worktree-end abort
# branch (REASON=workflow-aborted-cleanup). Procedure: abort-branch.md.
#   --session <sid>                      run in the linked worktree: refuse on uncommitted tracked
#                                        changes (WE-3), then `wip-state abandon` every claimed issue
#                                        whose `wip-state check --session-id <sid>` answers `same`
#   --delete-branch <branch> --main <m>  WE-15 of the abort branch: `git -C <m> branch -d <branch>`;
#                                        an unmerged branch is kept with a warning
# WIP_STATE_SH overrides the wip-state entrypoint (tests). A wip-state failure only warns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WIP_STATE_SH="${WIP_STATE_SH:-$REPO_ROOT/bin/github-issues/wip-state.sh}"

usage() {
    echo "usage: abort-branch.sh --session <sid> | --delete-branch <branch> --main <main-worktree>" >&2
    exit 2
}

SID=""
BRANCH=""
MAIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session) [ $# -ge 2 ] || usage; SID="$2"; shift 2 ;;
        --delete-branch) [ $# -ge 2 ] || usage; BRANCH="$2"; shift 2 ;;
        --main) [ $# -ge 2 ] || usage; MAIN="$2"; shift 2 ;;
        *) usage ;;
    esac
done

delete_branch() {
    if git -C "$MAIN" branch -d "$BRANCH"; then
        echo "abort-branch: deleted branch $BRANCH"
    else
        echo "warn: branch $BRANCH not deleted (unmerged commits or still checked out) — kept; delete it by hand once its commits are safe" >&2
    fi
}

abandon_wip() {
    local dirty issues n owner
    dirty="$(git status --porcelain --untracked-files=no)"
    if [ -n "$dirty" ]; then
        echo "abort-branch: uncommitted changes to tracked files — commit or stash them first (WE-3):" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    fi
    issues="$(node "$SCRIPT_DIR/read-abort-issues.js" "$SID")"
    for n in $issues; do
        if ! owner="$(bash "$WIP_STATE_SH" check "$n" --session-id "$SID")"; then
            echo "warn: wip-state check failed for #$n — WIP mark left in place; continuing" >&2
            continue
        fi
        owner="${owner%$'\r'}"
        if [ "$owner" != "same" ]; then
            echo "warn: #$n WIP mark is not this session's (check=$owner) — left in place; continuing" >&2
            continue
        fi
        if bash "$WIP_STATE_SH" abandon "$n"; then
            echo "abort-branch: WIP mark abandoned for #$n"
        else
            echo "warn: wip-state abandon failed for #$n — continuing" >&2
        fi
    done
}

if [ -n "$BRANCH" ]; then
    [ -n "$MAIN" ] || usage
    delete_branch
elif [ -n "$SID" ]; then
    abandon_wip
else
    usage
fi
