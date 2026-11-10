#!/usr/bin/env bash
# host-adapter.sh — sourced; routes issue reads and writes to the forge CLI of the repo's origin host.
# The host comes from `git remote get-url origin` in HIA_ROOT (default: cwd): gitlab → glab,
# anything else → gh. Only the host's own CLI is started (never both); it runs in HIA_ROOT.
# hia_host [root] → github|gitlab|unknown;  hia_repo_slug [root] → OWNER/REPO of origin
# hia_issue_create <repo> <title> <body | --body-file F> [label...]  (prints the issue URL)
# hia_issue_close <repo> <n>;  hia_issue_comment <repo> <n> <body>  (gitlab: issue note);  hia_issue_latest_number
# hia_issue_closed_numbers [limit];  hia_issue_comment_first_match <n> <regex>;  hia_issue_field <n> <body|title>;
# hia_issue_closing_merge_shas <n>  (reads; non-zero on failure)
# An empty <repo> omits --repo, so the CLI resolves the project from HIA_ROOT itself.

_HIA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_hia_origin() { git -C "${1:-${HIA_ROOT:-.}}" remote get-url origin 2>/dev/null; }

# hia_host judges with the migrate rule (bin/lib/migrate-forge-type.js); no CLI or a failure → unknown.
hia_host() {
    local t
    t="$(node "$_HIA_DIR/../../detect-forge-type" --repo-dir "${1:-${HIA_ROOT:-.}}" --field type --guess-unconfigured-host 2>/dev/null)" || t=""
    case "$t" in
        github|gitlab) echo "$t" ;;
        *) echo unknown ;;
    esac
}

hia_repo_slug() {
    local url p=""
    url="$(_hia_origin "${1:-}")" || return 1
    url="${url%.git}"
    case "$url" in
        *://*) p="${url#*://}"; p="${p#*/}" ;;
        *:*) p="${url#*:}" ;;
    esac
    [[ -n "$p" ]] || return 1
    printf '%s\n' "$p"
}

# _hia_run <cli> <repo> <args...> — the CLI in HIA_ROOT, with --repo only when <repo> is set.
_hia_run() {
    local cli="$1" repo="$2"
    shift 2
    local ra=()
    [[ -n "$repo" ]] && ra=(--repo "$repo")
    (cd "${HIA_ROOT:-.}" && "$cli" "$@" "${ra[@]}")
}

hia_issue_create() {
    local repo="${1-}" title="${2:?hia_issue_create: title required}" body="" bf=""
    shift 2
    if [[ "${1-}" == --body-file ]]; then
        bf="${2:?hia_issue_create: --body-file needs a path}"
        shift 2
    else
        body="${1-}"
        shift
    fi
    local la=() l
    for l in "$@"; do la+=(--label "$l"); done
    if [[ "$(hia_host)" == gitlab ]]; then
        [[ -n "$bf" ]] && { body="$(cat "$bf")" || return 1; }
        _hia_run glab "$repo" issue create --title "$title" --description "$body" "${la[@]}" --yes
    elif [[ -n "$bf" ]]; then
        local fa=(--body-file "$bf")
        _hia_run gh "$repo" issue create --title "$title" "${fa[@]}" "${la[@]}"
    else
        _hia_run gh "$repo" issue create --title "$title" --body "$body" "${la[@]}"
    fi
}

# hia_issue_latest_number — the newest issue's number in HIA_ROOT's project (0 when none); needs jq on gitlab.
hia_issue_latest_number() {
    if [[ "$(hia_host)" == gitlab ]]; then
        local out
        out="$(_hia_run glab "" issue list --all --per-page 1 --output json)" || return 1
        printf '%s' "$out" | jq -r '.[0].iid // 0'
    else
        (cd "${HIA_ROOT:-.}" && gh issue list --state all --limit 1 \
            --search "sort:created-desc" --json number --jq '.[0].number // 0')
    fi
}

# hia_issue_closed_numbers [limit] — closed issue numbers, one per line; non-zero when the listing fails (gitlab needs jq).
hia_issue_closed_numbers() {
    local limit="${1:-1000}" out
    if [[ "$(hia_host)" == gitlab ]]; then
        out="$(cd "${HIA_ROOT:-.}" && glab api --paginate "projects/:id/issues?state=closed&per_page=100")" || return 1
        printf '%s' "$out" | jq -rs --argjson n "$limit" '[.[][].iid] | .[:$n] | .[]'
    else
        (cd "${HIA_ROOT:-.}" && gh issue list --state closed --limit "$limit" --json number --jq '.[].number')
    fi
}

# hia_issue_comment_first_match <n> <regex> — the first comment body of issue n matching regex (jq
# test()), empty when none; non-zero when the comments cannot be read (gitlab needs jq).
hia_issue_comment_first_match() {
    local num="${1:?hia_issue_comment_first_match: issue number required}" re="${2:?regex required}" out lit
    if [[ "$(hia_host)" == gitlab ]]; then
        out="$(cd "${HIA_ROOT:-.}" && glab api --paginate "projects/:id/issues/${num}/notes?per_page=100")" || return 1
        printf '%s' "$out" | jq -rs --arg re "$re" '[.[][].body | select(test($re))] | first // ""'
    else
        lit="${re//\\/\\\\}"
        lit="${lit//\"/\\\"}"
        (cd "${HIA_ROOT:-.}" && gh issue view "$num" --json comments --jq "[.comments[].body | select(test(\"${lit}\"))] | first // \"\"")
    fi
}

# hia_issue_field <n> <body|title> — the issue's body (gitlab: description) or title, empty when
# unset; non-zero when the issue cannot be read (gitlab needs jq).
hia_issue_field() {
    local num="${1:?hia_issue_field: issue number required}" field="${2:?hia_issue_field: body|title required}" out
    case "$field" in body|title) ;; *) echo "hia_issue_field: unknown field: $field" >&2; return 2 ;; esac
    if [[ "$(hia_host)" == gitlab ]]; then
        out="$(cd "${HIA_ROOT:-.}" && glab api "projects/:id/issues/${num}")" || return 1
        [[ "$field" == body ]] && field=description
        printf '%s' "$out" | jq -r --arg f "$field" '.[$f] // ""'
    else
        (cd "${HIA_ROOT:-.}" && gh issue view "$num" --json "$field" --jq ".${field} // \"\"")
    fi
}

# hia_issue_closing_merge_shas <n> — merge commit SHAs of the merged PRs / MRs that closed issue n,
# one per line, empty when none; non-zero when they cannot be read (gitlab needs jq).
hia_issue_closing_merge_shas() {
    local num="${1:?hia_issue_closing_merge_shas: issue number required}" out
    if [[ "$(hia_host)" == gitlab ]]; then
        out="$(cd "${HIA_ROOT:-.}" && glab api "projects/:id/issues/${num}/closed_by")" || return 1
        printf '%s' "$out" | jq -r '.[] | select(.state == "merged") | (.merge_commit_sha // .squash_commit_sha // empty)'
    else
        (cd "${HIA_ROOT:-.}" && gh issue view "$num" --json closedByPullRequestsReferences \
            --jq '.closedByPullRequestsReferences[] | select(.mergeCommit != null) | .mergeCommit.oid')
    fi
}

hia_issue_close() {
    local repo="${1-}" num="${2:?hia_issue_close: issue number required}"
    if [[ "$(hia_host)" == gitlab ]]; then
        _hia_run glab "$repo" issue close "$num"
    else
        _hia_run gh "$repo" issue close "$num" --reason completed
    fi
}

hia_issue_comment() {
    local repo="${1-}" num="${2:?hia_issue_comment: issue number required}" body="${3:?body required}"
    if [[ "$(hia_host)" == gitlab ]]; then
        _hia_run glab "$repo" issue note "$num" --message "$body"
    else
        _hia_run gh "$repo" issue comment "$num" --body "$body"
    fi
}
