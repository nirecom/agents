#!/usr/bin/env bash
# resolve-board.sh [--no-cache-read] <owner/repo> — the board resolver (lib/resolve-project.sh) for node callers.
# Prints key=value lines: status, owner, number, project_id, content_date_field_id, status_field_id,
#   todo_option_id, in_progress_option_id, done_option_id, session_id_field_id, candidates.
# Exit 0 whenever a result is printed (any status), 2 on a usage error. --no-cache-read implies --no-cache-write.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/resolve-project.sh
. "$SCRIPT_DIR/lib/resolve-project.sh"

usage() { echo "usage: resolve-board.sh [--no-cache-read] <owner/repo>" >&2; exit 2; }

repo=""
declare -a flags=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache-read) flags+=(--no-cache-read --no-cache-write) ;;
        -*) usage ;;
        *) [[ -z "$repo" ]] || usage; repo="$1" ;;
    esac
    shift
done
[[ -n "$repo" ]] || usage

resolve_project_for_repo --repo "$repo" ${flags[@]+"${flags[@]}"} || true

printf 'status=%s\n' "${RESOLVED_STATUS:-fetch-failed}"
printf 'owner=%s\n' "$RESOLVED_OWNER"
printf 'number=%s\n' "$RESOLVED_PROJECT_NUM"
printf 'project_id=%s\n' "$RESOLVED_PROJECT_ID"
printf 'content_date_field_id=%s\n' "$RESOLVED_CONTENT_DATE_FIELD_ID"
printf 'status_field_id=%s\n' "$RESOLVED_STATUS_FIELD_ID"
printf 'todo_option_id=%s\n' "$RESOLVED_TODO_OPTION_ID"
printf 'in_progress_option_id=%s\n' "$RESOLVED_IN_PROGRESS_OPTION_ID"
printf 'done_option_id=%s\n' "$RESOLVED_DONE_OPTION_ID"
printf 'session_id_field_id=%s\n' "$RESOLVED_SESSION_ID_FIELD_ID"
printf 'candidates=%s\n' "${RESOLVED_CANDIDATES:-}"
