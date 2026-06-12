#!/bin/bash
# gh mock for migrate-repo canary tests.
#
# Behavior:
#   gh issue create ...   → log invocation, return sequential issue number (101+).
#   gh project item-add . → exit 0.
#   gh api ...            → exit 0 with minimal JSON.
#   anything else         → exit 0.
#
# Environment:
#   MOCK_LOG       — file to append invocation lines to (required for create logging).
#   MOCK_COUNTER   — file holding the next issue number (auto-initialized to 101).
#   MOCK_HAS_EXISTING_PROJECT — set to "1" to make `gh project list` return a matching project.
#
# Exit 99 from this script means an unexpected branch was hit (test failure marker).

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
                if [ "${MOCK_HAS_EXISTING_PROJECT:-}" = "1" ]; then
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
            *)
                echo '{"number":99,"id":"PVT_mock","fields":{"nodes":[]}}'
                ;;
        esac
        exit 0
        ;;
    api)
        first="${1:-}"
        echo "gh api $*" >> "$LOG"
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
