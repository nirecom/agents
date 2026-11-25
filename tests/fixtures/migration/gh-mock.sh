#!/bin/bash
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: scope:common, gh-stub, projects-v2

# gh mock for migrate-repo canary tests: issue create → sequential number (101+), api → minimal JSON, else exit 0.
# Env: MOCK_LOG (invocation log), MOCK_COUNTER (next issue number file, starts at 101).
# MOCK_HAS_EXISTING_PROJECT=1: `gh project list` returns a matching project and the repository
#   projectsV2 query (#3142) returns board #99 as open and linked. MOCK_LINKED=0|1|2 overrides only the
#   linked answer (2: open #99 and #98, ambiguous); MOCK_LINKED_QUERY_FAILS=1 fails the projectsV2 query;
#   MOCK_PROJECT_LIST_JSON overrides only the `gh project list` answer. MOCK_LINKED_OWNER: owner login of
#   linked board #99 (default mockowner, the repo owner).
# MOCK_LINK_FAILS=1 / MOCK_DELETE_FAILS=1: link / `gh project delete` fail. Exit 99: unexpected branch (test failure).

set -u

LOG="${MOCK_LOG:-/dev/null}"
COUNTER_FILE="${MOCK_COUNTER:-/tmp/gh-mock-counter}"

# Initialize counter if missing.
if [ ! -f "$COUNTER_FILE" ]; then
    echo 101 > "$COUNTER_FILE"
fi

cmd="${1:-}"
shift || true

case "$cmd" in
    issue)
        sub="${1:-}"; shift || true
        case "$sub" in
            create)
                # Log full args for later inspection.
                echo "gh issue create $*" >> "$LOG"
                n=$(cat "$COUNTER_FILE")
                echo "$((n + 1))" > "$COUNTER_FILE"
                # gh prints the issue URL to stdout on create.
                echo "https://github.com/example/repo/issues/$n"
                exit 0
                ;;
            list)
                # Return one issue when MOCK_HAS_ISSUES=1, else empty list.
                # If --jq is provided, apply it to the JSON output (so orchestrate.sh
                # can pass --jq '.[0].number // 0' and get an integer back).
                echo "gh issue list $*" >> "$LOG"
                highest_n="${MOCK_HIGHEST_ISSUE_N:-5}"
                if [ "${MOCK_HAS_ISSUES:-}" = "1" ]; then
                    base_json="[{\"number\":${highest_n}}]"
                else
                    base_json="[]"
                fi
                jq_filter=""
                prev=""
                for arg in "$@"; do
                    [ "$prev" = "--jq" ] && jq_filter="$arg"
                    prev="$arg"
                done
                if [ -n "$jq_filter" ] && command -v jq >/dev/null 2>&1; then
                    echo "$base_json" | jq -r "$jq_filter"
                else
                    echo "$base_json"
                fi
                exit 0
                ;;
            view)
                # Return minimal JSON node id when --json id is requested.
                echo '{"id":"I_kwDOmockNode"}'
                exit 0
                ;;
            *)
                echo "gh issue $sub $*" >> "$LOG"
                exit 0
                ;;
        esac
        ;;
    repo)
        sub="${1:-}"; shift || true
        echo "gh repo $sub $*" >> "$LOG"
        case "$sub" in
            view)
                has_jq=0; json_field=""; prev=""
                for arg in "$@"; do
                    [ "$prev" = "--json" ] && json_field="$arg"
                    [ "$arg" = "--jq" ] && has_jq=1
                    prev="$arg"
                done
                if [ "$has_jq" = "1" ]; then
                    case "$json_field" in
                        owner) echo "mockowner" ;;
                        name)  echo "mockrepo" ;;
                        *)     echo "" ;;
                    esac
                else
                    echo '{"owner":{"login":"mockowner"},"name":"mockrepo"}'
                fi
                ;;
            *) echo '{}' ;;
        esac
        exit 0
        ;;
    auth)
        sub="${1:-}"; shift || true
        echo "gh auth $sub $*" >> "$LOG"
        [ "$sub" = "status" ] && echo "Logged in. Scopes: project, repo"
        exit 0
        ;;
    project)
        sub="${1:-}"; shift || true
        echo "gh project $sub $*" >> "$LOG"
        case "$sub" in
            list)
                if [ -n "${MOCK_PROJECT_LIST_JSON:-}" ]; then
                    echo "$MOCK_PROJECT_LIST_JSON"
                elif [ "${MOCK_HAS_EXISTING_PROJECT:-}" = "1" ]; then
                    echo '{"projects":[{"number":99,"title":"mockrepo — Issue Timeline","id":"PVT_kwDOmock"}]}'
                else
                    echo '{"projects":[]}'
                fi
                ;;
            view)
                echo '{"id":"PVT_kwDOmock","number":99}'
                ;;
            field-list)
                echo '{"fields":[{"name":"Status","id":"PVTF_status"}]}'
                ;;
            field-create)
                echo '{"id":"PVTF_contentdate_mock"}'
                ;;
            link)
                [ "${MOCK_LINK_FAILS:-}" = "1" ] && { echo "mock project link failure" >&2; exit 1; }
                ;;
            delete)
                [ "${MOCK_DELETE_FAILS:-}" = "1" ] && { echo "mock project delete failure" >&2; exit 1; }
                ;;
            *)
                echo '{"number":99,"id":"PVT_mock","fields":{"nodes":[]}}'
                ;;
        esac
        exit 0
        ;;
    api)
        first="${1:-}"
        echo "gh api $*" >> "$LOG"
        # #3142: the repository's linked boards, with --jq applied compactly as gh prints it.
        case "$*" in
            graphql*projectsV2*)
                [ "${MOCK_LINKED_QUERY_FAILS:-}" = "1" ] && { echo "mock projectsV2 query failure" >&2; exit 1; }
                nodes='[]'
                one="{\"id\":\"PVT_kwDOmock\",\"number\":99,\"closed\":false,\"owner\":{\"login\":\"${MOCK_LINKED_OWNER:-mockowner}\"}}"
                case "${MOCK_LINKED:-${MOCK_HAS_EXISTING_PROJECT:-0}}" in
                    1) nodes="[$one]" ;;
                    2) nodes="[$one,{\"id\":\"PVT_kwDOmock2\",\"number\":98,\"closed\":false,\"owner\":{\"login\":\"mockowner\"}}]" ;;
                esac
                linked_json="{\"data\":{\"repository\":{\"projectsV2\":{\"nodes\":$nodes,\"pageInfo\":{\"hasNextPage\":false}}}}}"
                linked_jq=""; prev=""
                for arg in "$@"; do [ "$prev" = "--jq" ] && linked_jq="$arg"; prev="$arg"; done
                if [ -n "$linked_jq" ]; then printf '%s' "$linked_json" | jq -rc "$linked_jq"; else echo "$linked_json"; fi
                exit 0
                ;;
        esac
        if [ "$first" = "graphql" ]; then
            query_body=""
            jq_filter=""
            prev_arg=""
            for arg in "$@"; do
                case "$arg" in
                    query=*) query_body="${arg#query=}" ;;
                    --jq)    : ;; # next arg is the filter
                    *)
                        [ "$prev_arg" = "--jq" ] && jq_filter="$arg"
                        ;;
                esac
                prev_arg="$arg"
            done
            json_out=""
            case "$query_body" in
                *createProjectV2Field*)
                    json_out='{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_contentdate_mock"}}}}' ;;
                *createProjectV2*)
                    json_out='{"data":{"createProjectV2":{"projectV2":{"id":"PVT_kwDOmock","number":99}}}}' ;;
                *viewer*id*)
                    json_out='{"data":{"viewer":{"id":"MDQ6User_mock123"}}}' ;;
                *user*login*)
                    json_out='{"data":{"user":{"id":"MDQ6User_mock123"}}}' ;;
                *organization*login*)
                    json_out='{"data":{"organization":{"id":"MDEyOk9yZ_mock123"}}}' ;;
                *linkProjectV2ToRepository*)
                    if [ "${MOCK_LINK_FAILS:-}" = "1" ]; then
                        echo '{"errors":[{"message":"mock link failure"}]}'
                        exit 1
                    fi
                    json_out='{"data":{"linkProjectV2ToRepository":{"repository":{"id":"R_kgDOmock"}}}}' ;;
                *)
                    json_out='{"data":{}}' ;;
            esac
            if [ -n "$jq_filter" ] && command -v jq >/dev/null 2>&1; then
                echo "$json_out" | jq -r "$jq_filter"
            else
                echo "$json_out"
            fi
        else
            base_json='{"node_id":"R_kgDOmock","name":"mockrepo","full_name":"mockowner/mockrepo"}'
            jq_filter=""
            prev=""
            for arg in "$@"; do
                [ "$prev" = "--jq" ] && jq_filter="$arg"
                prev="$arg"
            done
            if [ -n "$jq_filter" ] && command -v jq >/dev/null 2>&1; then
                echo "$base_json" | jq -r "$jq_filter"
            else
                echo "$base_json"
            fi
        fi
        exit 0
        ;;
    *)
        echo "gh $cmd $*" >> "$LOG"
        exit 0
        ;;
esac
