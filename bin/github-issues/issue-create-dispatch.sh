#!/usr/bin/env bash
# Dispatch wrapper for /issue-create skill — executes the mechanical branch
# selected by Claude's survey verdict (none / reopen / sub-of / make-parent / sibling).
#
# Usage:
#   issue-create-dispatch.sh --verdict <kind> [verdict-specific flags] -- <issue-create.sh args...>
#
# Verdicts:
#   none         (no extra flags)            New issue with no relation
#   reopen       --target N                  Reopen #N; no new issue created
#   sub-of       --parent N                  New issue, attached as sub-issue of #N
#   make-parent  --children N,M,...          New issue becomes parent of comma-separated children
#   sibling      --related N,M,...           New issue with "Related to #N" appended to body
#   bulk-sub-of  --parent N --manifest FILE   Create N new sub-issues under #N from manifest
#
# Stdout: final issue URL(s).
#   single verdicts (none/reopen/sub-of/make-parent/sibling): one URL (last line of stdout).
#   bulk-sub-of: N URLs in manifest order (one per line, end of stdout; progress on stderr only).
#   reopen: URL of the reopened issue; all other verdicts: URL of the new issue.
# Exit: 0 on success; 2 on usage error; 1 on structural failure.

set -euo pipefail

VERDICT=""
TARGET=""
PARENT=""
CHILDREN=""
RELATED=""
MANIFEST=""
PASSTHROUGH=()

usage() {
    sed -n '2,20p' "$0" >&2
    exit 2
}

is_numeric() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_numeric() {
    local flag="$1" val="$2"
    if ! is_numeric "$val"; then
        echo "Error: $flag must be a positive integer, got: $val" >&2
        exit 2
    fi
}

validate_numeric_list() {
    local flag="$1" list="$2"
    IFS=',' read -ra ITEMS <<< "$list"
    for item in "${ITEMS[@]}"; do
        item="${item// /}"   # trim spaces
        if ! is_numeric "$item"; then
            echo "Error: $flag values must be positive integers, got: '$item'" >&2
            exit 2
        fi
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --verdict)   VERDICT="${2:?--verdict requires value}";  shift 2 ;;
        --target)    TARGET="${2:?--target requires value}";    shift 2 ;;
        --parent)    PARENT="${2:?--parent requires value}";    shift 2 ;;
        --children)  CHILDREN="${2:?--children requires value}"; shift 2 ;;
        --related)   RELATED="${2:?--related requires value}";  shift 2 ;;
        --manifest)  MANIFEST="${2:?--manifest requires value}"; shift 2 ;;
        --)          shift; PASSTHROUGH=("$@"); break ;;
        -h|--help)   usage ;;
        *) echo "Error: unknown argument before --: $1" >&2; exit 2 ;;
    esac
done

case "$VERDICT" in
    none|reopen|sub-of|make-parent|sibling|bulk-sub-of) ;;
    "")  echo "Error: --verdict required" >&2; exit 2 ;;
    *)   echo "Error: unknown verdict: $VERDICT" >&2; exit 2 ;;
esac

# Validate numeric flag values after VERDICT is confirmed.
[ -n "$TARGET" ]   && validate_numeric "--target" "$TARGET"
[ -n "$PARENT" ]   && validate_numeric "--parent" "$PARENT"
[ -n "$CHILDREN" ] && validate_numeric_list "--children" "$CHILDREN"
[ -n "$RELATED" ]  && validate_numeric_list "--related" "$RELATED"

if [[ "$VERDICT" == "bulk-sub-of" ]]; then
    [[ -n "$PARENT" ]] || { echo "Error: --parent required for --verdict bulk-sub-of" >&2; exit 2; }
    validate_numeric "--parent" "$PARENT"
    [[ -n "$MANIFEST" ]] || { echo "Error: --manifest required for --verdict bulk-sub-of" >&2; exit 2; }
    [[ -f "$MANIFEST" ]] || { echo "Error: --manifest file not found: $MANIFEST" >&2; exit 2; }
    [[ -s "$MANIFEST" ]] || { echo "Error: --manifest file is empty" >&2; exit 2; }
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2; exit 1
fi

CONFIG_DIR="${AGENTS_CONFIG_DIR:-}"
if [ -z "$CONFIG_DIR" ]; then
    CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
ISSUE_CREATE_SH="$CONFIG_DIR/bin/github-issues/issue-create.sh"

get_repo_slug() {
    gh repo view --json nameWithOwner --jq .nameWithOwner | tr -d '\r'
}

# Always called with the CHILD issue number — never the parent.
# Returns the child's integer databaseId via GraphQL (gh issue view --json databaseId
# was removed from the gh CLI; GraphQL is the supported path).
get_child_database_id() {
    local issue_number="$1"
    local slug owner repo
    slug="$(get_repo_slug)"
    owner="${slug%%/*}"
    repo="${slug##*/}"
    gh api graphql \
        -f query="{ repository(owner: \"${owner}\", name: \"${repo}\") { issue(number: ${issue_number}) { databaseId } } }" \
        --jq '.data.repository.issue.databaseId' | tr -d '\r'
}

# $1 = parent issue number (URL path), $2 = child integer databaseId (body).
attach_subissue() {
    local parent_number="$1"
    local child_database_id="$2"
    local slug
    slug="$(get_repo_slug)"
    MSYS_NO_PATHCONV=1 gh api -X POST \
        "repos/${slug}/issues/${parent_number}/sub_issues" \
        -F "sub_issue_id=${child_database_id}" >/dev/null
}

create_via_issue_create() {
    bash "$ISSUE_CREATE_SH" "$@" | tail -n 1 | tr -d '\r'
}

extract_issue_number() {
    printf '%s' "$1" | grep -oE '[0-9]+$'
}

# Inject "Related to #N" lines into a --body argument inside PASSTHROUGH.
# Updates PASSTHROUGH in place.
inject_related_into_body() {
    local suffix="$1"
    local i=0
    local found=0
    local new=()
    while [ $i -lt ${#PASSTHROUGH[@]} ]; do
        local arg="${PASSTHROUGH[$i]}"
        if [ "$arg" = "--body" ] && [ $((i + 1)) -lt ${#PASSTHROUGH[@]} ]; then
            new+=("--body" "${PASSTHROUGH[$((i + 1))]}"$'\n\n'"$suffix")
            i=$((i + 2))
            found=1
            continue
        fi
        if [ "$arg" = "--body-file" ] && [ $((i + 1)) -lt ${#PASSTHROUGH[@]} ]; then
            local src="${PASSTHROUGH[$((i + 1))]}"
            local tmp
            tmp="$(mktemp 2>/dev/null || mktemp -t issue-dispatch)"
            TMP_BODY_FILE="$tmp"
            trap 'rm -f "${TMP_BODY_FILE:-}"' EXIT
            cat "$src" > "$tmp"
            printf '\n\n%s\n' "$suffix" >> "$tmp"
            new+=("--body-file" "$tmp")
            i=$((i + 2))
            found=1
            continue
        fi
        new+=("$arg")
        i=$((i + 1))
    done
    if [ $found -eq 0 ]; then
        echo "Error: --body or --body-file is required for --verdict sibling" >&2
        exit 2
    fi
    PASSTHROUGH=("${new[@]}")
}

case "$VERDICT" in
    none)
        url="$(create_via_issue_create "${PASSTHROUGH[@]}")"
        echo "$url"
        ;;

    reopen)
        [ -n "$TARGET" ] || { echo "Error: --target required for --verdict reopen" >&2; exit 2; }
        MSYS_NO_PATHCONV=1 gh issue reopen "$TARGET" >/dev/null
        slug="$(get_repo_slug)"
        echo "https://github.com/${slug}/issues/${TARGET}"
        ;;

    sibling)
        [ -n "$RELATED" ] || { echo "Error: --related required for --verdict sibling" >&2; exit 2; }
        suffix=""
        IFS=',' read -ra REL_LIST <<< "$RELATED"
        for r in "${REL_LIST[@]}"; do
            r="${r// /}"   # trim spaces
            if [ -z "$suffix" ]; then
                suffix="Related to #${r}"
            else
                suffix="${suffix}"$'\n'"Related to #${r}"
            fi
        done
        inject_related_into_body "$suffix"
        url="$(create_via_issue_create "${PASSTHROUGH[@]}")"
        echo "$url"
        ;;

    sub-of)
        [ -n "$PARENT" ] || { echo "Error: --parent required for --verdict sub-of" >&2; exit 2; }
        url="$(create_via_issue_create "${PASSTHROUGH[@]}")"
        child_number="$(extract_issue_number "$url")"
        child_database_id="$(get_child_database_id "$child_number")"
        # Disable set -e for the attach step so we can surface the parent URL on failure.
        if ! attach_subissue "$PARENT" "$child_database_id"; then
            echo "Error: failed to attach #${child_number} as sub-issue of #${PARENT}" >&2
            echo "The issue was created: ${url}" >&2
            echo "Retry: gh api -X POST repos/<slug>/issues/${PARENT}/sub_issues -F sub_issue_id=${child_database_id}" >&2
            exit 1
        fi
        slug="$(get_repo_slug)"
        if ! bash "$(dirname "${BASH_SOURCE[0]}")/parent-ancestor-reopen.sh" "$slug" "$child_number"; then
            echo "WARN: ancestor reopen had failures for #${child_number} — see above" >&2
        fi
        echo "$url"
        ;;

    make-parent)
        [ -n "$CHILDREN" ] || { echo "Error: --children required for --verdict make-parent" >&2; exit 2; }
        url="$(create_via_issue_create "${PASSTHROUGH[@]}")"
        new_parent_number="$(extract_issue_number "$url")"
        IFS=',' read -ra CHILD_LIST <<< "$CHILDREN"
        failed=()
        for child in "${CHILD_LIST[@]}"; do
            child="${child// /}"   # trim spaces
            child_database_id=""
            # Use if ! to handle get_child_database_id failure without set -e exit.
            if ! child_database_id="$(get_child_database_id "$child")"; then
                failed+=("$child")
                continue
            fi
            if ! attach_subissue "$new_parent_number" "$child_database_id"; then
                failed+=("$child")
            fi
        done
        if [ ${#failed[@]} -gt 0 ]; then
            echo "Error: failed to attach children to ${url}: ${failed[*]}" >&2
            echo "Parent issue is created. Retry the failed children manually:" >&2
            for f in "${failed[@]}"; do
                echo "  gh api graphql -f query='{ repository(owner: \"OWNER\", name: \"REPO\") { issue(number: ${f}) { databaseId } } }' --jq '.data.repository.issue.databaseId'  # get integer id" >&2
                echo "  gh api -X POST repos/<slug>/issues/${new_parent_number}/sub_issues -F sub_issue_id=<integer>" >&2
            done
            exit 1
        fi
        echo "$url"
        ;;

    bulk-sub-of)
        # Manifest: TSV file with one "title<TAB>body" row per child.
        # Body may contain \n escape sequences for embedded newlines.
        # Title must not contain literal TAB characters.
        # Stdout: one URL per successfully created child, in manifest order.
        slug="$(get_repo_slug)"
        created_urls=()
        failed=()
        while IFS=$'\t' read -r title body_raw || [[ -n "$title" ]]; do
            [[ -z "$title" ]] && continue
            body="${body_raw//\\n/$'\n'}"
            child_url=""
            if ! child_url="$(create_via_issue_create \
                    --title "$title" --body "$body" "${PASSTHROUGH[@]}")"; then
                failed+=("create:$(printf '%s' "$title" | cut -c1-40)")
                continue
            fi
            child_number="$(extract_issue_number "$child_url")"
            child_database_id=""
            if ! child_database_id="$(get_child_database_id "$child_number")"; then
                failed+=("dbid:#${child_number}")
                # Record orphaned URL: child was created but cannot be attached.
                created_urls+=("$child_url")
                continue
            fi
            if ! attach_subissue "$PARENT" "$child_database_id"; then
                failed+=("attach:#${child_number}")
                # Still record URL so caller can log the orphaned child.
                created_urls+=("$child_url")
                continue
            fi
            created_urls+=("$child_url")
        done < "$MANIFEST"
        # Reopen parent ancestor when at least one child was attached (mirrors sub-of).
        if [[ ${#created_urls[@]} -gt 0 ]]; then
            if ! bash "$(dirname "${BASH_SOURCE[0]}")/parent-ancestor-reopen.sh" "$slug" \
                    "$(extract_issue_number "${created_urls[0]}")"; then
                echo "WARN: ancestor reopen had failures for parent #${PARENT} — see above" >&2
            fi
        fi
        # Emit all successfully created URLs (manifest order) to stdout first.
        for url in "${created_urls[@]}"; do
            echo "$url"
        done
        if [[ ${#failed[@]} -gt 0 ]]; then
            echo "Error: ${#failed[@]} operation(s) failed for bulk-sub-of under #${PARENT}:" >&2
            for f in "${failed[@]}"; do
                echo "  $f" >&2
            done
            echo "Successfully created: ${#created_urls[@]} issue(s)." >&2
            echo "Retry attach failures: gh api -X POST repos/${slug}/issues/${PARENT}/sub_issues -F sub_issue_id=<integer databaseId of child>" >&2
            exit 1
        fi
        ;;
esac
