#!/usr/bin/env bash
# tests/lib/gh-projectv2-fields-mock.sh
# Tests: tests/lib/gh-projectv2-fields-mock.sh
# Tags: scope:issue-specific, shared-lib, gh-stub, projects-v2
# JSON-backed Projects v2 field/view model for gh mocks (#2925): a gh mock runs
#   bash gh-projectv2-fields-mock.sh api graphql <args...>
# for field lists, view lists and field/view mutations. Answers are real response JSON with --jq
# applied through jq, so any filter the code under test uses is served (per page or --paginate).

set -u

# Field knobs: GH_MOCK_FIELDS_STATE (file keeping TEXT fields across calls), GH_MOCK_FIELDS_LOG
# (one line per op), GH_MOCK_SID_FIELD present|legacy|absent|both (default present),
# GH_MOCK_SID_FIELD_ID / GH_MOCK_LEGACY_FIELD_ID (PVTF_fp / PVTF_legacy), GH_MOCK_NEW_FIELD_ID
# (create answer, PVTF_sid_new), GH_MOCK_CREATE_NO_ID=1 (answer without id), GH_MOCK_FIELD_PAGES 1|2
# (2 = TEXT fields on page 2), GH_MOCK_STATUS_FIELD present|absent, GH_MOCK_RESOLVED_CONTENT_DATE_ID,
# GH_MOCK_FIELD_LIST_FAIL all|paged (paged = only queries whose body carries "after:").
[ "${1:-}" = "api" ] && shift
[ "${1:-}" = "graphql" ] && shift

JQ_FILTER="" QUERY="" AFTER="" FIELD_ID_ARG="" NAME_ARG="" INPUT_FILE="" PAGINATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --jq|-q) JQ_FILTER="${2:-}"; shift 2 ;;
        --jq=*) JQ_FILTER="${1#--jq=}"; shift ;;
        --input) INPUT_FILE="${2:-}"; shift 2 ;;
        --paginate) PAGINATE=1; shift ;;
        -f|-F|--field|--raw-field)
            kv="${2:-}"
            case "$kv" in
                query=*) QUERY="${kv#query=}" ;;
                after=*|cursor=*|endCursor=*) AFTER="${kv#*=}" ;;
                fieldId=*) FIELD_ID_ARG="${kv#fieldId=}" ;;
                name=*) NAME_ARG="${kv#name=}" ;;
            esac
            shift 2 ;;
        *) shift ;;
    esac
done
INPUT_TEXT=""
if [ -n "$INPUT_FILE" ] && [ -f "$INPUT_FILE" ]; then
    INPUT_TEXT="$(cat "$INPUT_FILE")"
    [ -z "$QUERY" ] && QUERY="$INPUT_TEXT"
fi
FLAT="$(printf '%s' "$QUERY $NAME_ARG $FIELD_ID_ARG $INPUT_TEXT" | tr '\n\r' '  ')"

log_op() {
    [ -n "${GH_MOCK_FIELDS_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_MOCK_FIELDS_LOG"
    return 0
}

emit() {
    local json="$1" out
    if [ -n "$JQ_FILTER" ]; then
        out="$(printf '%s' "$json" | jq -r "$JQ_FILTER")" || exit 1
        printf '%s\n' "$out" | tr -d '\r'
    else
        printf '%s\n' "$json"
    fi
}

SID_ID="${GH_MOCK_SID_FIELD_ID:-PVTF_fp}"
LEGACY_ID="${GH_MOCK_LEGACY_FIELD_ID:-PVTF_legacy}"
STATE="${GH_MOCK_FIELDS_STATE:-}"
TAB=$'\t'

init_rows() {
    case "${GH_MOCK_SID_FIELD:-present}" in
        present) printf '%s\t%s\n' "$SID_ID" "session-id" ;;
        legacy)  printf '%s\t%s\n' "$LEGACY_ID" "session-fingerprint" ;;
        both)    printf '%s\t%s\n%s\t%s\n' "$LEGACY_ID" "session-fingerprint" "$SID_ID" "session-id" ;;
        absent)  : ;;
    esac
}

read_rows() {
    if [ -n "$STATE" ]; then
        [ -f "$STATE" ] || init_rows > "$STATE"
        cat "$STATE"
    else
        init_rows
    fi
}

text_nodes() {
    local rows id name sep="" out=""
    rows="$(read_rows)"
    while IFS="$TAB" read -r id name; do
        [ -n "$id" ] || continue
        out="$out$sep{\"__typename\":\"ProjectV2Field\",\"id\":\"$id\",\"name\":\"$name\",\"dataType\":\"TEXT\"}"
        sep=","
    done <<<"$rows"
    printf '%s' "$out"
}

base_nodes() {
    local out="{\"__typename\":\"ProjectV2Field\",\"id\":\"PVTF_title\",\"name\":\"Title\",\"dataType\":\"TITLE\"}"
    if [ "${GH_MOCK_STATUS_FIELD:-present}" = "present" ]; then
        out="$out,{\"__typename\":\"ProjectV2SingleSelectField\",\"id\":\"${GH_MOCK_STATUS_FIELD_ID:-PVTSSF_status}\",\"name\":\"Status\",\"dataType\":\"SINGLE_SELECT\",\"options\":[{\"id\":\"${GH_MOCK_OPT_TODO:-OPT_todo}\",\"name\":\"Todo\"},{\"id\":\"${GH_MOCK_OPT_INPROG:-OPT_inprog}\",\"name\":\"In Progress\"},{\"id\":\"${GH_MOCK_OPT_DONE:-OPT_done}\",\"name\":\"Done\"}]}"
    fi
    if [ -n "${GH_MOCK_RESOLVED_CONTENT_DATE_ID:-}" ]; then
        out="$out,{\"__typename\":\"ProjectV2Field\",\"id\":\"$GH_MOCK_RESOLVED_CONTENT_DATE_ID\",\"name\":\"Content Date\",\"dataType\":\"DATE\"}"
    fi
    printf '%s' "$out"
}

# page_index <cursor> <npages> — 1-based page for a cursor; 0 = past the end.
page_index() {
    case "$1" in
        "") echo 1 ;;
        CUR_P*) local k="${1#CUR_P}"; k=$((k + 1)); if [ "$k" -le "$2" ]; then echo "$k"; else echo 0; fi ;;
        *) echo 0 ;;
    esac
}

wrap_page() { # <conn-key> <nodes> <idx> <npages>
    local info
    if [ "$3" -eq 0 ]; then
        info='{"hasNextPage":false,"endCursor":null}'
    elif [ "$3" -lt "$4" ]; then
        info="{\"hasNextPage\":true,\"endCursor\":\"CUR_P$3\"}"
    else
        info="{\"hasNextPage\":false,\"endCursor\":\"CUR_P$3\"}"
    fi
    printf '{"data":{"node":{"id":"PVT_mock","%s":{"nodes":[%s],"pageInfo":%s}}}}' "$1" "$2" "$info"
}

fields_page() { # <idx>
    local idx="$1" npages="${GH_MOCK_FIELD_PAGES:-1}" nodes="" t
    t="$(text_nodes)"
    if [ "$idx" -eq 1 ]; then
        nodes="$(base_nodes)"
        if [ "$npages" -eq 1 ] && [ -n "$t" ]; then nodes="$nodes,$t"; fi
    elif [ "$idx" -eq 2 ] && [ "$npages" -ge 2 ]; then
        nodes="$t"
    fi
    wrap_page fields "$nodes" "$idx" "$npages"
}

# View knobs: GH_MOCK_VIEWS "id:LAYOUT:fid,fid;id:LAYOUT:fid" (default none), GH_MOCK_VIEW_PAGES 1|2
# (2 = first view on page 1, the rest on page 2), GH_MOCK_VIEW_LIST_FAIL=1,
# GH_MOCK_VIEW_FIELDS_TRUNCATED "vid,vid" (those views report fields.pageInfo.hasNextPage=true).
views_page() { # <idx>
    local moreidx="$1" npages="${GH_MOCK_VIEW_PAGES:-1}" spec vid layout fids f nodes="" sep="" n=0 fn fsep want
    local -a specs farr
    IFS=';' read -r -a specs <<<"${GH_MOCK_VIEWS:-}"
    for spec in "${specs[@]}"; do
        [ -n "$spec" ] || continue
        n=$((n + 1))
        want=1
        if [ "$npages" -ge 2 ] && [ "$n" -gt 1 ]; then want=2; fi
        [ "$idx" -eq "$want" ] || continue
        vid="${spec%%:*}"; layout="${spec#*:}"; fids="${layout#*:}"; layout="${layout%%:*}"
        fn="" fsep=""
        IFS=',' read -r -a farr <<<"$fids"
        for f in "${farr[@]}"; do
            [ -n "$f" ] || continue
            fn="$fn$fsep{\"__typename\":\"ProjectV2Field\",\"id\":\"$f\"}"; fsep=","
        done
        more=false
        case ",${GH_MOCK_VIEW_FIELDS_TRUNCATED:-}," in *",$vid,"*) more=true ;; esac
        nodes="$nodes$sep{\"id\":\"$vid\",\"name\":\"$vid\",\"layout\":\"$layout\",\"fields\":{\"nodes\":[$fn],\"pageInfo\":{\"hasNextPage\":$more,\"endCursor\":null}},\"visibleFields\":{\"nodes\":[$fn]}}"
        sep=","
    done
    wrap_page views "$nodes" "$idx" "$npages"
}

serve_pages() { # <page-fn> <npages>
    local idx
    if [ "$PAGINATE" -eq 1 ]; then
        idx=1
        while [ "$idx" -le "$2" ]; do emit "$("$1" "$idx")"; idx=$((idx + 1)); done
        return 0
    fi
    idx="$(page_index "$AFTER" "$2")"
    emit "$("$1" "$idx")"
}

# Mutation knob: GH_MOCK_FAIL create-field|rename-field|view-update.
case "$FLAT" in
    *updateProjectV2View*)
        log_op "view-update $FLAT"
        [ "${GH_MOCK_FAIL:-}" = "view-update" ] && { echo "error: updateProjectV2View denied" >&2; exit 1; }
        emit '{"data":{"updateProjectV2View":{"projectV2View":{"id":"PVTV_updated"}}}}'
        ;;
    *updateProjectV2Field*)
        fid="$FIELD_ID_ARG"
        if [ -z "$fid" ] && [[ "$FLAT" =~ fieldId[[:space:]]*:[[:space:]]*\\?\"([A-Za-z0-9_-]+) ]]; then
            fid="${BASH_REMATCH[1]}"
        fi
        log_op "rename fieldId=$fid $FLAT"
        [ "${GH_MOCK_FAIL:-}" = "rename-field" ] && { echo "error: updateProjectV2Field denied" >&2; exit 1; }
        case "$FLAT" in *session-id*) ;; *) echo "MOCK GH: rename without the session-id name" >&2; exit 1 ;; esac
        rows="$(read_rows)"
        printf '%s\n' "$rows" | grep -q "^$fid$TAB" || { echo "error: field $fid not found" >&2; exit 1; }
        if [ -n "$STATE" ]; then
            printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' -v id="$fid" 'NF { if ($1 == id) $2 = "session-id"; print }' > "$STATE.tmp"
            mv "$STATE.tmp" "$STATE"
        fi
        emit "{\"data\":{\"updateProjectV2Field\":{\"projectV2Field\":{\"id\":\"$fid\",\"name\":\"session-id\"}}}}"
        ;;
    *createProjectV2Field*)
        log_op "create $FLAT"
        case "$FLAT" in *TEXT*) ;; *) echo "MOCK GH: create without dataType TEXT" >&2; exit 1 ;; esac
        case "$FLAT" in *session-fingerprint*) echo "MOCK GH: create with the legacy name" >&2; exit 1 ;; esac
        case "$FLAT" in *session-id*) ;; *) echo "MOCK GH: create without the session-id name" >&2; exit 1 ;; esac
        [ "${GH_MOCK_FAIL:-}" = "create-field" ] && { echo "error: createProjectV2Field denied" >&2; exit 1; }
        new_id="${GH_MOCK_NEW_FIELD_ID:-PVTF_sid_new}"
        if [ -n "$STATE" ]; then
            read_rows > /dev/null
            printf '%s\t%s\n' "$new_id" "session-id" >> "$STATE"
        fi
        if [ "${GH_MOCK_CREATE_NO_ID:-}" = "1" ]; then
            emit '{"data":{"createProjectV2Field":{"projectV2Field":null}}}'
        else
            emit "{\"data\":{\"createProjectV2Field\":{\"projectV2Field\":{\"id\":\"$new_id\",\"name\":\"session-id\"}}}}"
        fi
        ;;
    *"views("*)
        log_op "list-views after=$AFTER"
        [ "${GH_MOCK_VIEW_LIST_FAIL:-}" = "1" ] && { echo "error: views query failed" >&2; exit 1; }
        serve_pages views_page "${GH_MOCK_VIEW_PAGES:-1}"
        ;;
    *"fields("*)
        log_op "list-fields after=$AFTER"
        case "${GH_MOCK_FIELD_LIST_FAIL:-}" in
            all) echo "error: fields query failed" >&2; exit 1 ;;
            paged) case "$FLAT" in *"after:"*|*"after :"*) echo "error: fields query failed" >&2; exit 1 ;; esac ;;
        esac
        serve_pages fields_page "${GH_MOCK_FIELD_PAGES:-1}"
        ;;
    *)
        echo "MOCK GH (fields model): unhandled graphql call" >&2
        exit 2
        ;;
esac
exit 0
