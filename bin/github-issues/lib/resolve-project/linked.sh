# resolve-project/linked.sh — the repository's open linked Projects v2 boards (sourced by resolve-project.sh).
# _resolve_project_query_linked <owner> <repo> — counts the repo's open (not closed) linked boards.
#   rc 0: exactly one; sets _RP_LINKED_PID _RP_LINKED_PNUM _RP_LINKED_POWNER and RESOLVED_STATUS=resolved.
#   rc 1: sets RESOLVED_STATUS to no-link, ambiguous (2+ open, or the link list exceeds one page;
#   RESOLVED_CANDIDATES holds "<owner>#<number>" words) or fetch-failed, with the reason on stderr.
# _resolve_project_link_check <owner> <repo> <pid> — rc 0: pid is still the only open linked board;
#   rc 1: re-resolve (unlinked, closed, a second open board, or a truncated list); rc 2: the check failed.

_RESOLVE_PROJECT_LINKED_QUERY='query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    projectsV2(first: 100) {
      nodes { id number closed owner { ... on Organization { login } ... on User { login } } }
      pageInfo { hasNextPage }
    }
  }
}'

# _resolve_project_linked_jq <owner> <repo> <jq> — one projectsV2 query; prints the first CR-free line.
_resolve_project_linked_jq() {
    local out
    out="$(gh api graphql -F owner="$1" -F repo="$2" --jq "$3" \
        -f query="$_RESOLVE_PROJECT_LINKED_QUERY" 2>/dev/null)" || return 1
    out="${out//$'\r'/}"
    printf '%s\n' "${out%%$'\n'*}"
}

_resolve_project_query_linked() {
    local owner="$1" repo="$2" count cands node
    _RP_LINKED_PID="" _RP_LINKED_PNUM="" _RP_LINKED_POWNER=""
    if ! count="$(_resolve_project_linked_jq "$owner" "$repo" \
            '.data.repository.projectsV2 | if .pageInfo.hasNextPage then "truncated" else ([.nodes[] | select(.closed != true)] | length) end')"; then
        RESOLVED_STATUS="fetch-failed"
        echo "warn: resolve-project: gh api graphql (linked projectsV2) failed for $owner/$repo" >&2
        return 1
    fi
    if [[ "$count" == "0" ]]; then
        RESOLVED_STATUS="no-link"
        echo "warn: resolve-project: no Projects v2 linked to $owner/$repo (open boards only)" >&2
        return 1
    fi
    if [[ "$count" == "truncated" || ( "$count" =~ ^[0-9]+$ && "$count" -gt 1 ) ]]; then
        cands="$(_resolve_project_linked_jq "$owner" "$repo" \
            '[.data.repository.projectsV2.nodes[] | select(.closed != true) | "\(.owner.login)#\(.number)"] | join(" ")')" || cands=""
        _resolve_project_report_ambiguous "$owner/$repo" "$count" "$cands"
        return 1
    fi
    if [[ "$count" != "1" ]]; then
        RESOLVED_STATUS="fetch-failed"
        echo "warn: resolve-project: unexpected linked board count '$count' for $owner/$repo" >&2
        return 1
    fi
    # The node query re-counts: unless exactly one open board remains (a second one linked since the count
    # above, or a truncated list) it prints nothing, so the parse fails and no board is picked by API order.
    if ! node="$(_resolve_project_linked_jq "$owner" "$repo" \
            '.data.repository.projectsV2 | if .pageInfo.hasNextPage or ([.nodes[] | select(.closed != true) | 1] | add // 0) != 1 then empty else (.nodes | map(select(.closed != true)) | if length == 0 then empty else .[0] | {id, number, ownerLogin: .owner.login} end) end')" \
       || ! _resolve_project_parse_node "$node"; then
        RESOLVED_STATUS="fetch-failed"
        echo "warn: resolve-project: could not read the linked board of $owner/$repo: $node" >&2
        return 1
    fi
    RESOLVED_STATUS="resolved"
    return 0
}

# _resolve_project_parse_node <json> — {"id":..,"number":..,"ownerLogin":..} into _RP_LINKED_PID/_RP_LINKED_PNUM/_RP_LINKED_POWNER.
_resolve_project_parse_node() {
    local re_id='"id"[[:space:]]*:[[:space:]]*"([^"]+)"' re_num='"number"[[:space:]]*:[[:space:]]*([0-9]+)'
    local re_own='"ownerLogin"[[:space:]]*:[[:space:]]*"([^"]+)"'
    [[ "$1" =~ $re_id ]] && _RP_LINKED_PID="${BASH_REMATCH[1]}"
    [[ "$1" =~ $re_num ]] && _RP_LINKED_PNUM="${BASH_REMATCH[1]}"
    [[ "$1" =~ $re_own ]] && _RP_LINKED_POWNER="${BASH_REMATCH[1]}"
    [[ -n "$_RP_LINKED_PID" && -n "$_RP_LINKED_PNUM" && -n "$_RP_LINKED_POWNER" ]]
}

# _resolve_project_report_ambiguous <owner/repo> <count|truncated> <candidates> — status + recovery steps.
_resolve_project_report_ambiguous() {
    local key="$1" count="$2" cands="$3" c n o
    RESOLVED_STATUS="ambiguous"
    RESOLVED_CANDIDATES="$cands"
    if [[ "$count" == "truncated" ]]; then
        echo "error: resolve-project: $key links more than 100 Projects v2 boards (${cands:-unknown}) — refusing to pick one." >&2
    else
        echo "error: resolve-project: $key has $count open linked Projects v2 boards (${cands:-unknown}) — refusing to pick one." >&2
    fi
    echo "  Keep one open linked board; for each other board, run one of:" >&2
    for c in $cands; do
        [[ "$c" == *#* ]] || continue
        o="${c%#*}" n="${c##*#}"
        echo "    gh project close $n --owner $o    |    gh project unlink $n --owner $o --repo $key" >&2
    done
    [[ "$cands" == *#* ]] || echo "    gh project close <number> --owner <owner>    |    gh project unlink <number> --owner <owner> --repo $key" >&2
}

_resolve_project_link_check() {
    local verdict
    verdict="$(_resolve_project_linked_jq "$1" "$2" \
        '.data.repository.projectsV2 | if .pageInfo.hasNextPage then "truncated" else ([.nodes[] | select(.closed != true)] as $o | if ($o | length) >= 2 then "ambiguous" else ([$o[] | select(.id == "'"$3"'")] | length) end) end')" || return 2
    case "$verdict" in
        1) return 0 ;;
        0|ambiguous|truncated) return 1 ;;
        *) return 2 ;;
    esac
}
