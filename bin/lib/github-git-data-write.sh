#!/usr/bin/env bash
# bin/lib/github-git-data-write.sh
#
# Writes multiple files atomically to GitHub via the Git Data API.
# Produces one commit on the target branch containing every file passed in via
# --file. Replaces local `git add/commit/push` for rotated docs/history.md +
# CHANGELOG.md updates under the enforce-worktree Positive-Allow redesign (#672).
#
# Usage:
#   bash bin/lib/github-git-data-write.sh \
#       --owner <o> --repo <r> --branch <b> --message <m> \
#       --file <repo-path>=<abs-local-path> \
#       [--file <repo-path>=<abs-local-path> ...] \
#       [--max-retries <n>]
#
# Exit codes:
#   0   success
#   1   non-recoverable error
#   11  retry exhausted (concurrent ref update could not be resolved)
set -euo pipefail

OWNER=""
REPO=""
BRANCH=""
MESSAGE=""
MAX_RETRIES="${MAX_RETRIES:-3}"
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)       OWNER="${2:-}";       shift 2 ;;
        --repo)        REPO="${2:-}";        shift 2 ;;
        --branch)      BRANCH="${2:-}";      shift 2 ;;
        --message)     MESSAGE="${2:-}";     shift 2 ;;
        --max-retries) MAX_RETRIES="${2:-3}"; shift 2 ;;
        --file)        FILES+=("${2:-}");   shift 2 ;;
        *) echo "github-git-data-write: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$OWNER" || -z "$REPO" || -z "$BRANCH" || -z "$MESSAGE" ]]; then
    echo "github-git-data-write: --owner, --repo, --branch, --message are required" >&2
    exit 1
fi
if (( ${#FILES[@]} == 0 )); then
    echo "github-git-data-write: at least one --file <repo-path>=<abs-local-path> is required" >&2
    exit 1
fi

if [[ ! "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "github-git-data-write: invalid --owner value" >&2; exit 1
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "github-git-data-write: invalid --repo value" >&2; exit 1
fi
if [[ ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "github-git-data-write: invalid --branch value" >&2; exit 1
fi

# Validate each --file entry and collect (repo_path, abs_local) pairs.
REPO_PATHS=()
LOCAL_PATHS=()
for entry in "${FILES[@]}"; do
    if [[ "$entry" != *=* ]]; then
        echo "github-git-data-write: --file entry missing '=<abs-local-path>': $entry" >&2
        exit 1
    fi
    rp="${entry%%=*}"
    lp="${entry#*=}"
    if [[ -z "$rp" || -z "$lp" ]]; then
        echo "github-git-data-write: --file entry has empty side: $entry" >&2
        exit 1
    fi
    if [[ "$rp" == /* || "$rp" =~ (^|/)\.\.(/|$) ]]; then
        echo "github-git-data-write: invalid repo path (no leading / or .. segments): $rp" >&2
        exit 1
    fi
    if [[ ! -f "$lp" ]]; then
        echo "github-git-data-write: local file does not exist: $lp" >&2
        exit 1
    fi
    REPO_PATHS+=("$rp")
    LOCAL_PATHS+=("$lp")
done

# Pre-flight: warn (not abort) if `repo` scope is absent.
if command -v gh >/dev/null 2>&1; then
    if ! gh auth status 2>&1 | grep -qE '(\bscopes:.*\brepo\b|\brepo\b)'; then
        echo "github-git-data-write: warning — 'repo' scope may be absent; calls may fail. Re-run: gh auth refresh -s repo" >&2
    fi
fi

# base64 helper (no line wrapping).
b64enc() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w0 "$1"
    else
        base64 "$1" | tr -d '\n'
    fi
}

# 1. Create blobs for each local file (one POST per blob). Blobs are content-
#    addressed, so this is safe to do once even across retries.
BLOB_SHAS=()
for lp in "${LOCAL_PATHS[@]}"; do
    B64=$(b64enc "$lp")
    if ! BLOB_SHA=$(gh api -X POST "repos/$OWNER/$REPO/git/blobs" \
            -f "encoding=base64" -f "content=$B64" --jq '.sha' 2>&1); then
        echo "github-git-data-write: blob create failed for $lp:" >&2
        printf '%s\n' "$BLOB_SHA" >&2
        exit 1
    fi
    BLOB_SHAS+=("$BLOB_SHA")
done

attempt=1
while (( attempt <= MAX_RETRIES )); do
    # 2. Fetch current ref (parent commit).
    if ! PARENT=$(gh api "repos/$OWNER/$REPO/git/refs/heads/$BRANCH" --jq '.object.sha' 2>&1); then
        echo "github-git-data-write: failed to fetch ref refs/heads/$BRANCH:" >&2
        printf '%s\n' "$PARENT" >&2
        exit 1
    fi

    # 3. Resolve base tree SHA from the parent commit.
    if ! BASE_TREE=$(gh api "repos/$OWNER/$REPO/git/commits/$PARENT" --jq '.tree.sha' 2>&1); then
        echo "github-git-data-write: failed to fetch parent commit $PARENT:" >&2
        printf '%s\n' "$BASE_TREE" >&2
        exit 1
    fi

    # 4. Build the tree JSON. Use jq to ensure valid JSON regardless of paths.
    TREE_JSON=$(
        jq -n \
            --arg base "$BASE_TREE" \
            --argjson paths "$(printf '%s\n' "${REPO_PATHS[@]}" | jq -R . | jq -s .)" \
            --argjson shas "$(printf '%s\n' "${BLOB_SHAS[@]}" | jq -R . | jq -s .)" \
            '{
              base_tree: $base,
              tree: [range(0; ($paths|length)) | {
                path: $paths[.],
                mode: "100644",
                type: "blob",
                sha: $shas[.]
              }]
            }'
    )

    TREE_TMP=$(mktemp)
    printf '%s' "$TREE_JSON" > "$TREE_TMP"
    NEW_TREE_OUT=""
    if ! NEW_TREE_OUT=$(gh api -X POST "repos/$OWNER/$REPO/git/trees" --input "$TREE_TMP" --jq '.sha' 2>&1); then
        rm -f "$TREE_TMP"
        echo "github-git-data-write: tree create failed:" >&2
        printf '%s\n' "$NEW_TREE_OUT" >&2
        exit 1
    fi
    rm -f "$TREE_TMP"
    NEW_TREE="$NEW_TREE_OUT"

    # 5. Create the new commit.
    if ! NEW_COMMIT=$(gh api -X POST "repos/$OWNER/$REPO/git/commits" \
            -f "message=$MESSAGE" -f "tree=$NEW_TREE" -f "parents[]=$PARENT" \
            --jq '.sha' 2>&1); then
        echo "github-git-data-write: commit create failed:" >&2
        printf '%s\n' "$NEW_COMMIT" >&2
        exit 1
    fi

    # 6. Update the ref (fast-forward).
    PATCH_OUT=""
    PATCH_RC=0
    PATCH_OUT=$(gh api -X PATCH "repos/$OWNER/$REPO/git/refs/heads/$BRANCH" \
        -f "sha=$NEW_COMMIT" 2>&1) || PATCH_RC=$?

    if (( PATCH_RC == 0 )); then
        exit 0
    fi

    if printf '%s' "$PATCH_OUT" | grep -qE '(HTTP 422|non-fast-forward|update is not a fast forward)'; then
        echo "github-git-data-write: non-fast-forward on attempt ${attempt}/${MAX_RETRIES}, retrying" >&2
        attempt=$(( attempt + 1 ))
        continue
    fi

    echo "github-git-data-write: ref update failed (rc=$PATCH_RC):" >&2
    printf '%s\n' "$PATCH_OUT" >&2
    exit 1
done

echo "github-git-data-write: retry exhausted after ${MAX_RETRIES} attempts (concurrent writers? re-run manually)" >&2
exit 11
