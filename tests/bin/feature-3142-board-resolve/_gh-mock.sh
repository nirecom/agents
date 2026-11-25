#!/usr/bin/env bash
# tests/bin/feature-3142-board-resolve/_gh-mock.sh — JSON-backed gh mock for the #3142 board tests.
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: scope:issue-specific, gh-stub, projects-v2, feature-3142
# Answers are real response JSON with --jq applied by real jq, so the code's own jq filters are verified.
# Knobs: GH_MOCK_LOG, GH_MOCK_REPO (owner/repo), GH_MOCK_LINKED_FILE (projectsV2 object JSON),
# GH_MOCK_FAIL (csv: linked,link,delete,create,item-add,issue-view,status-read,content-date,status-reset),
# GH_MOCK_ITEM_ON (csv project ids holding a card), GH_MOCK_ITEMADD_GONE_FILE (first GH_MOCK_ITEMADD_GONE_TIMES,
# default 1, item-adds say the board is gone), GH_MOCK_ISSUES_DIR (<cursor|first>.json), GH_MOCK_SLEEP,
# GH_MOCK_CARD_STATUS (default Todo), GH_MOCK_LINKED_RAW (verbatim projectsV2 answer, no jq),
# GH_MOCK_LINKED_NEXT_FILE (moved over GH_MOCK_LINKED_FILE after one answer: a board changing mid-resolve).
set -uo pipefail

LOG="${GH_MOCK_LOG:-/dev/null}"
printf '%s\n' "$*" | tr '\n\r' '  ' >>"$LOG"
printf '\n' >>"$LOG"

[ -n "${GH_MOCK_SLEEP:-}" ] && sleep "$GH_MOCK_SLEEP"
failing() { case ",${GH_MOCK_FAIL:-}," in *",$1,"*) return 0 ;; esac; return 1; }

JQ="" QUERY="" AFTER="" PAGINATE=0 JSONF=""
parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq|-q) JQ="${2:-}"; shift 2 ;;
      --json) JSONF="${2:-}"; shift 2 ;;
      --paginate) PAGINATE=1; shift ;;
      -f|-F|--field|--raw-field)
        case "${2:-}" in
          query=*) QUERY="${2#query=}" ;;
          after=*|cursor=*|endCursor=*) AFTER="${2#*=}" ;;
        esac
        shift 2 ;;
      *) shift ;;
    esac
  done
}
emit() {
  # -c: gh prints each non-string --jq result as one compact JSON line.
  if [ -n "$JQ" ]; then printf '%s' "$1" | jq -rc "$JQ" | tr -d '\r'; else printf '%s\n' "$1"; fi
}

REPO="${GH_MOCK_REPO:-mockowner/mockrepo}"
R_OWNER="${REPO%/*}" R_NAME="${REPO#*/}"

case "${1:-} ${2:-}" in
  "auth status") echo "Token scopes: 'repo', 'project'"; exit 0 ;;
  "repo view")
    shift 2; parse "$@"
    emit "{\"owner\":{\"login\":\"$R_OWNER\"},\"name\":\"$R_NAME\",\"nameWithOwner\":\"$REPO\"}"; exit 0 ;;
  "issue view")
    n="${3:-0}"; shift 3; parse "$@"
    failing issue-view && { echo "error: issue view failed" >&2; exit 1; }
    emit "{\"url\":\"https://github.com/$REPO/issues/$n\",\"createdAt\":\"2026-01-02T03:04:05Z\",\"id\":\"I_$n\"}"; exit 0 ;;
  "project delete")
    failing delete && { echo "error: project delete failed" >&2; exit 1; }
    exit 0 ;;
  "project link")
    failing link && { echo "error: project link failed" >&2; exit 1; }
    exit 0 ;;
  "project item-add")
    shift 2; parse "$@"
    failing item-add && { echo "error: item-add failed" >&2; exit 1; }
    gone_file="${GH_MOCK_ITEMADD_GONE_FILE:-}"
    gone_n=0
    [ -n "$gone_file" ] && [ -f "$gone_file" ] && gone_n="$(wc -l <"$gone_file" | tr -d ' ')"
    if [ -n "$gone_file" ] && [ "$gone_n" -lt "${GH_MOCK_ITEMADD_GONE_TIMES:-1}" ]; then
      echo gone >>"$gone_file"
      echo "GraphQL: Could not resolve to a ProjectV2 with the number 1. (closed)" >&2
      exit 1
    fi
    emit '{"id":"PVTI_added"}'; exit 0 ;;
  "project item-edit")
    case " $* " in
      *" --date "*) failing content-date && { echo "error: content date write failed" >&2; exit 1; } ;;
      *" --single-select-option-id "*) failing status-reset && { echo "error: status reset failed" >&2; exit 1; } ;;
    esac
    exit 0 ;;
  "api graphql") ;;
  api\ repos/*) shift 2; parse "$@"; emit '{"node_id":"R_mock"}'; exit 0 ;;
  *) echo "MOCK GH (3142): unhandled: $*" >&2; exit 2 ;;
esac

shift 2
parse "$@"
FLAT="$(printf '%s' "$QUERY" | tr '\n\r' '  ')"

case "$FLAT" in
  *linkProjectV2ToRepository*)
    failing link && { echo "error: link failed" >&2; exit 1; }
    emit '{"data":{"linkProjectV2ToRepository":{"repository":{"id":"R_mock"}}}}' ;;
  *createProjectV2Field*)
    emit '{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_new"}}}}' ;;
  *createProjectV2*)
    failing create && { echo "error: create failed" >&2; exit 1; }
    emit "{\"data\":{\"createProjectV2\":{\"projectV2\":{\"id\":\"PVT_new\",\"number\":42,\"owner\":{\"login\":\"$R_OWNER\"}}}}}" ;;
  *"issues("*)
    pages="${GH_MOCK_ISSUES_DIR:-}"
    if [ "$PAGINATE" -eq 1 ]; then
      cur="first"
      while [ -f "$pages/$cur.json" ]; do
        body="$(cat "$pages/$cur.json")"; emit "$body"
        nxt="$(printf '%s' "$body" | jq -r '.data.repository.issues.pageInfo | if .hasNextPage then .endCursor else "" end')"
        [ -n "$nxt" ] || break
        cur="$nxt"
      done
    else
      cur="${AFTER:-first}"; [ "$cur" = "null" ] && cur="first"
      [ -f "$pages/$cur.json" ] || { echo "MOCK GH (3142): no issues page $cur" >&2; exit 2; }
      emit "$(cat "$pages/$cur.json")"
    fi ;;
  *projectItems*)
    nodes="" sep=""
    IFS=',' read -r -a on <<<"${GH_MOCK_ITEM_ON:-}"
    for p in "${on[@]}"; do
      [ -n "$p" ] || continue
      nodes="$nodes$sep{\"id\":\"PVTI_on_$p\",\"project\":{\"id\":\"$p\"}}"; sep=","
    done
    emit "{\"data\":{\"repository\":{\"issue\":{\"projectItems\":{\"nodes\":[$nodes]}}}}}" ;;
  *projectsV2*)
    failing linked && { echo "error: graphql projectsV2 failed" >&2; exit 1; }
    [ -n "${GH_MOCK_LINKED_RAW:-}" ] && { printf '%s\n' "$GH_MOCK_LINKED_RAW"; exit 0; }
    obj='{"nodes":[],"pageInfo":{"hasNextPage":false}}'
    [ -n "${GH_MOCK_LINKED_FILE:-}" ] && [ -f "$GH_MOCK_LINKED_FILE" ] && obj="$(cat "$GH_MOCK_LINKED_FILE")"
    emit "{\"data\":{\"repository\":{\"projectsV2\":$obj}}}"
    # Race knob: the next projectsV2 call sees GH_MOCK_LINKED_NEXT_FILE (moved over GH_MOCK_LINKED_FILE).
    next="${GH_MOCK_LINKED_NEXT_FILE:-}"
    [ -n "$next" ] && [ -f "$next" ] && mv -f "$next" "$GH_MOCK_LINKED_FILE"
    ;;
  *fieldValueByName*)
    failing status-read && { echo "error: status read failed" >&2; exit 1; }
    emit "{\"data\":{\"node\":{\"fieldValueByName\":{\"name\":\"${GH_MOCK_CARD_STATUS:-Todo}\"}}}}" ;;
  *"fields("*)
    emit '{"data":{"node":{"id":"PVT_x","fields":{"nodes":[{"__typename":"ProjectV2Field","id":"PVTF_cd","name":"Content Date","dataType":"DATE"},{"__typename":"ProjectV2SingleSelectField","id":"PVTSSF_st","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"OPT_todo","name":"Todo"},{"id":"OPT_ip","name":"In Progress"},{"id":"OPT_done","name":"Done"}]},{"__typename":"ProjectV2Field","id":"PVTF_sid","name":"session-id","dataType":"TEXT"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' ;;
  *viewer*) emit "{\"data\":{\"viewer\":{\"id\":\"U_viewer\",\"login\":\"$R_OWNER\"}}}" ;;
  *"user("*) emit '{"data":{"user":{"id":"U_user"}}}' ;;
  *"organization("*) emit '{"data":{"organization":{"id":"O_org"}}}' ;;
  *) echo "MOCK GH (3142): unhandled graphql: $FLAT" >&2; exit 2 ;;
esac
exit 0
