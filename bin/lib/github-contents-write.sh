#!/usr/bin/env bash
# bin/lib/github-contents-write.sh
#
# Writes a single file to GitHub via the Contents API (PUT).
# Replaces local `git add/commit/push` for docs/history.md and CHANGELOG.md
# under the enforce-worktree Positive-Allow redesign (#672).
#
# Usage:
#   bash bin/lib/github-contents-write.sh \
#       --owner <o> --repo <r> --path <repo-path> \
#       --file <abs-local-path> \
#       --message <commit-msg> \
#       [--branch <b>] [--max-retries <n>]
#
# Exit codes:
#   0   success
#   1   non-recoverable error (bad request, missing auth, etc.)
#   11  retry exhausted (concurrent SHA race could not be resolved)
#
# Retries on `does not match` / HTTP 409 / 422 (stale base SHA) by re-fetching
# the current SHA and re-PUTing. Other failures propagate verbatim.
set -euo pipefail

OWNER=""
REPO=""
FILE_PATH=""
FILE=""
MESSAGE=""
BRANCH="main"
MAX_RETRIES="${MAX_RETRIES:-3}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)        OWNER="${2:-}";        shift 2 ;;
        --repo)         REPO="${2:-}";         shift 2 ;;
        --path)         FILE_PATH="${2:-}";    shift 2 ;;
        --file)         FILE="${2:-}";         shift 2 ;;
        --message)      MESSAGE="${2:-}";      shift 2 ;;
        --branch)       BRANCH="${2:-}";       shift 2 ;;
        --max-retries)  MAX_RETRIES="${2:-3}"; shift 2 ;;
        *) echo "github-contents-write: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$OWNER" || -z "$REPO" || -z "$FILE_PATH" || -z "$FILE" || -z "$MESSAGE" ]]; then
    echo "github-contents-write: --owner, --repo, --path, --file, --message are required" >&2
    exit 1
fi

if [[ ! "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "github-contents-write: invalid --owner value" >&2; exit 1
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "github-contents-write: invalid --repo value" >&2; exit 1
fi
if [[ ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "github-contents-write: invalid --branch value" >&2; exit 1
fi
if [[ "$FILE_PATH" == /* || "$FILE_PATH" =~ (^|/)\.\.(/|$) ]]; then
    echo "github-contents-write: invalid --path value (no leading / or .. segments)" >&2; exit 1
fi

if [[ ! -f "$FILE" ]]; then
    echo "github-contents-write: content file does not exist: $FILE" >&2
    exit 1
fi

# Pre-flight: warn (not abort) if `repo` scope is absent.
if command -v gh >/dev/null 2>&1; then
    if ! gh auth status 2>&1 | grep -qE '(\bscopes:.*\brepo\b|\brepo\b)'; then
        echo "github-contents-write: warning — 'repo' scope may be absent; PUT may fail. Re-run: gh auth refresh -s repo" >&2
    fi
fi

# base64 encode the local file (no line wrapping)
if command -v base64 >/dev/null 2>&1; then
    if base64 --help 2>&1 | grep -q -- '-w'; then
        B64=$(base64 -w0 "$FILE")
    else
        B64=$(base64 "$FILE" | tr -d '\n')
    fi
else
    echo "github-contents-write: base64 command not found" >&2
    exit 1
fi

# Write base64 content to a temp file so jq --rawfile can read it without
# passing it through argv (avoids "Argument list too long" on Windows, #730).
# B64_TMP persists for the duration of the retry loop; cleaned up on all exit
# paths via the outer trap.
B64_TMP=$(mktemp)
printf '%s' "$B64" > "$B64_TMP"
trap 'rm -f "$B64_TMP"' EXIT

attempt=1
while (( attempt <= MAX_RETRIES )); do
    # Fetch current SHA (empty if file does not exist yet)
    SHA=""
    RESPONSE=$(gh api "repos/$OWNER/$REPO/contents/$FILE_PATH?ref=$BRANCH" 2>/dev/null || echo '{}')
    SHA=$(printf '%s' "$RESPONSE" | jq -r '.sha // empty' 2>/dev/null || true)

    # Build PUT body as a JSON file and pass via `gh api --input`. Passing the
    # base64 content via `-f "content=$B64"` or `--arg content "$B64"` exceeds
    # OS ARG_MAX on Windows for large files (issue #730). Use --rawfile to read
    # content from a file. $MESSAGE is user-provided text — use `--arg` for JSON
    # escaping.
    PUT_TMP=$(mktemp)
    trap 'rm -f "$PUT_TMP" "$B64_TMP"' EXIT
    if [[ -n "$SHA" ]]; then
        jq -n \
            --arg message "$MESSAGE" \
            --arg branch "$BRANCH" \
            --rawfile content "$B64_TMP" \
            --arg sha "$SHA" \
            '{message: $message, branch: $branch, content: $content, sha: $sha}' > "$PUT_TMP"
    else
        jq -n \
            --arg message "$MESSAGE" \
            --arg branch "$BRANCH" \
            --rawfile content "$B64_TMP" \
            '{message: $message, branch: $branch, content: $content}' > "$PUT_TMP"
    fi

    PUT_OUT=""
    PUT_RC=0
    PUT_OUT=$(gh api -X PUT "repos/$OWNER/$REPO/contents/$FILE_PATH" --input "$PUT_TMP" 2>&1) || PUT_RC=$?
    rm -f "$PUT_TMP"
    trap 'rm -f "$B64_TMP"' EXIT

    if (( PUT_RC == 0 )); then
        rm -f "$B64_TMP"
        trap - EXIT
        exit 0
    fi

    # Concurrent SHA mismatch — re-fetch and retry.
    if printf '%s' "$PUT_OUT" | grep -qE '(does not match|HTTP 409|HTTP 422|is at)'; then
        echo "github-contents-write: SHA mismatch on attempt ${attempt}/${MAX_RETRIES}, re-fetching" >&2
        attempt=$(( attempt + 1 ))
        continue
    fi

    # Non-recoverable
    rm -f "$B64_TMP"
    trap - EXIT
    echo "github-contents-write: PUT failed (rc=$PUT_RC):" >&2
    printf '%s\n' "$PUT_OUT" >&2
    exit 1
done

rm -f "$B64_TMP"
trap - EXIT
echo "github-contents-write: retry exhausted after ${MAX_RETRIES} attempts (concurrent writers? re-run manually):" >&2
echo "  gh api -X PUT repos/$OWNER/$REPO/contents/$FILE_PATH --input <json-body-file>" >&2
exit 11
