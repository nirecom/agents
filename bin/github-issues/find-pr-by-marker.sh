#!/bin/bash
# find-pr-by-marker.sh [--repo <owner/repo|repo>] <N>
# Resolve issue #<N> -> (PR_NUMBER, MERGE_COMMIT). Primary: gh/glab "closed by"
# API (issue must be CLOSED; newest merged wins). Fallback: PR/MR body marker
# `<!-- issue-close-pr-of: <N> -->`. --repo targets a cross-repo (GitHub only;
# short form normalized via `gh repo view`). GitLab: forge auto-detected,
# cross-repo rejected, project path is the CWD origin's (nested namespace ok).
# Output: PR_NUMBER=<n> / MERGE_COMMIT=<sha>; exit 1 on failure (stderr diagnostic).

set -uo pipefail

# Derive AGENTS_CONFIG_DIR from this script's own path when unset (#2308).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_CONFIG_DIR="${AGENTS_CONFIG_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
urlenc() { node -e "process.stdout.write(encodeURIComponent(process.argv[1]))" "$1"; }

REPO_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARG="$2"; shift 2 ;;
        --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Error: issue number required" >&2
    exit 1
fi

N="$1"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only (got: $N)" >&2
    exit 1
fi

# Forge detection (#2308). Unknown/empty falls back to GitHub (pre-2308 default).
FORGE=$(node "$AGENTS_CONFIG_DIR/bin/detect-forge-type" --repo-dir . --field type 2>/dev/null)
[ -z "$FORGE" ] && FORGE="github"

if [ "$FORGE" = "gitlab" ]; then
    GL_PROJECT=$(node "$AGENTS_CONFIG_DIR/bin/detect-forge-type" --repo-dir . --field project 2>/dev/null)
    if [ -z "$GL_PROJECT" ]; then
        echo "Error: could not resolve GitLab project path from origin" >&2; exit 1
    fi
    if [ -n "$REPO_ARG" ] && [ "$REPO_ARG" != "$GL_PROJECT" ]; then
        echo "Error: GitLab mode does not support cross-repo --repo; run from the target project's worktree" >&2; exit 2
    fi
    GL_ENC=$(urlenc "$GL_PROJECT")
    # Primary: MRs that closed the issue (GitLab SSOT). Newest merged wins.
    PRIMARY_LINE=$(glab api "projects/$GL_ENC/issues/$N/closed_by" \
        --jq '[.[] | select(.merge_commit_sha != null)] | sort_by(.merged_at) | last | "\(.iid)\t\(.merge_commit_sha // "")"' \
        2>/dev/null) || PRIMARY_LINE=""
    if [ -n "$PRIMARY_LINE" ]; then
        PR_NUM=$(printf '%s' "$PRIMARY_LINE" | cut -f1)
        MERGE_SHA=$(printf '%s' "$PRIMARY_LINE" | cut -f2)
        if [ -n "$PR_NUM" ] && [ "$PR_NUM" != "null" ] && [ -n "$MERGE_SHA" ]; then
            printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$PR_NUM" "$MERGE_SHA"
            exit 0
        fi
    fi
    # Fallback: marker search across merged MR descriptions. Newest merged wins.
    MARKER="<!-- issue-close-pr-of: ${N} -->"
    PR_LINE=$(glab api "projects/$GL_ENC/merge_requests?state=merged&search=$(urlenc "$MARKER")&in=description" \
        --jq '[.[] | select(.merge_commit_sha != null)] | sort_by(.merged_at) | last | "\(.iid)\t\(.merge_commit_sha // "")"' \
        2>/dev/null) || PR_LINE=""
    if [ -n "$PR_LINE" ] && [ "$(printf '%s' "$PR_LINE" | cut -f2)" != "" ]; then
        printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$(printf '%s' "$PR_LINE" | cut -f1)" "$(printf '%s' "$PR_LINE" | cut -f2)"
        exit 0
    fi
    echo "Error: no MR found for #${N} (closed_by empty and marker absent)" >&2
    exit 1
elif [ "$FORGE" != "github" ]; then
    # unknown or unrecognised forge type → warn and fall through to GitHub
    echo "Warning: unrecognised forge type '${FORGE}'; falling back to GitHub" >&2
fi

# Validate --repo format before any use (prevents flag-injection into gh).
if [[ -n "$REPO_ARG" ]]; then
    if ! [[ "$REPO_ARG" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]]; then
        echo "Error: invalid --repo value: $REPO_ARG" >&2
        exit 2
    fi
fi

# Normalize short-form repo (no slash) to full owner/repo (fail-closed).
if [[ -n "$REPO_ARG" ]] && [[ "$REPO_ARG" != *"/"* ]]; then
    REPO_ARG=$(gh repo view "$REPO_ARG" --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null) || {
        echo "Error: failed to resolve short-form repo '$REPO_ARG'" >&2
        exit 2
    }
fi

# Primary: closedByPullRequestsReferences (GitHub SSOT — #418 fix).
# Only meaningful when CLOSED. Pre-jq'd output: `<number>\t<sha>`.
PR_NUM=""
MERGE_SHA=""
STATE=$(gh issue view "$N" ${REPO_ARG:+--repo "$REPO_ARG"} --json state --jq '.state' 2>/dev/null) || STATE=""
if [ "$STATE" = "CLOSED" ]; then
    PRIMARY_LINE=$(gh issue view "$N" ${REPO_ARG:+--repo "$REPO_ARG"} --json closedByPullRequestsReferences \
        --jq '[.closedByPullRequestsReferences[]] | sort_by(.mergedAt) | last | "\(.number)\t\(.mergeCommit.oid // "")"' \
        2>/dev/null) || PRIMARY_LINE=""
    if [ -n "$PRIMARY_LINE" ]; then
        PR_NUM=$(printf '%s' "$PRIMARY_LINE" | cut -f1)
        MERGE_SHA=$(printf '%s' "$PRIMARY_LINE" | cut -f2)
    fi
fi

if [ -n "$PR_NUM" ] && [ -n "$MERGE_SHA" ]; then
    printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$PR_NUM" "$MERGE_SHA"
    exit 0
fi

# Fallback: marker-based PR search across merged PRs. Pre-jq'd output:
# `<number>\t<sha>`. When there are multiple matches, `sort_by(.mergedAt) | last`
# keeps the most recent merge.
# When --repo is set, fallback is skipped — the cross-repo PR is in the named repo.
PR_LINE=""
if [ -z "$REPO_ARG" ]; then
  PR_LINE=$(gh pr list \
      --search "in:body \"<!-- issue-close-pr-of: ${N} -->\"" \
      --state merged --json number,mergedAt,mergeCommit \
      --jq '[.[]] | sort_by(.mergedAt) | last | "\(.number)\t\(.mergeCommit.oid // "")"' \
      2>/dev/null) || PR_LINE=""
fi

if [ -n "$PR_LINE" ] && [ "$(printf '%s' "$PR_LINE" | cut -f2)" != "" ]; then
    PR_NUM=$(printf '%s' "$PR_LINE" | cut -f1)
    MERGE_SHA=$(printf '%s' "$PR_LINE" | cut -f2)
    printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$PR_NUM" "$MERGE_SHA"
    exit 0
fi

echo "Error: no PR found for #${N} (closedByPullRequestsReferences empty and marker absent)" >&2
exit 1
