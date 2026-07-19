#!/bin/bash
# Propagate the canonical .github/labels.yml from nirecom/agents to sibling repos.
#
# For each sibling: clone with a PAT-embedded URL, overwrite its labels.yml with
# the canonical content prefixed by a GENERATED header, commit+push when changed,
# then sync the GitHub label API objects via sync-labels.sh.
#
# Siblings are processed independently: one sibling's failure records a non-zero
# exit code but never stops the others. The PAT appears only in the clone URL —
# it is never echoed to stdout nor written into any labels.yml body.

set -uo pipefail

if [[ -z "${PROPAGATE_LABELS_PAT:-}" ]]; then
    printf '%s\n' "PROPAGATE_LABELS_PAT not set — skipping propagation"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_LABELS_FILE="${CANONICAL_LABELS_FILE:-.github/labels.yml}"
if [[ -z "${PROPAGATE_LABELS_REPOS:-}" ]]; then
    printf '%s\n' "PROPAGATE_LABELS_REPOS not set — skipping propagation"
    exit 0
fi
AGENTS_WORKSPACE="${AGENTS_WORKSPACE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# F2: reject path traversal in CANONICAL_LABELS_FILE
case "$CANONICAL_LABELS_FILE" in
    *..*)
        printf '%s\n' "CANONICAL_LABELS_FILE contains path traversal (..) — aborting" >&2
        exit 1
        ;;
esac

# F4: cleanup temp work dir on exit (only when auto-created)
if [[ -n "${GIT_WORK_DIR:-}" ]]; then
    _CLEANUP_WORK_DIR=0
else
    GIT_WORK_DIR="$(mktemp -d)"
    _CLEANUP_WORK_DIR=1
fi
trap '[[ "${_CLEANUP_WORK_DIR:-0}" = "1" ]] && rm -rf "${GIT_WORK_DIR:-}"' EXIT

GENERATED_HEADER="# GENERATED — source: nirecom/agents .github/labels.yml — do not edit directly"

EXIT_CODE=0

while IFS= read -r _ENTRY_PATH; do
    _ENTRY_PATH="${_ENTRY_PATH#"${_ENTRY_PATH%%[![:space:]]*}"}"
    _ENTRY_PATH="${_ENTRY_PATH%"${_ENTRY_PATH##*[![:space:]]}"}"
    [ -z "$_ENTRY_PATH" ] && continue

    if [ -d "$_ENTRY_PATH" ]; then
        _REMOTE_URL="$(git -C "$_ENTRY_PATH" remote get-url origin 2>/dev/null)" || {
            printf '%s\n' "cannot resolve remote for path: $_ENTRY_PATH — skipping" >&2
            EXIT_CODE=1
            continue
        }
    else
        case "$_ENTRY_PATH" in
            /*|[A-Za-z]:\\*)
                _REPO_BASENAME="$(basename "$_ENTRY_PATH")"
                _CURRENT_ORIGIN="$(git -C "$AGENTS_WORKSPACE" remote get-url origin 2>/dev/null)"
                _CURRENT_OWNER="$(printf '%s\n' "$_CURRENT_ORIGIN" | sed 's|.*github\.com[:/]\([^/]*\)/.*|\1|; t; s/.*//')"
                if [ -z "$_REPO_BASENAME" ] || [ -z "$_CURRENT_OWNER" ]; then
                    printf '%s\n' "cannot resolve owner/basename for path: $_ENTRY_PATH — skipping" >&2
                    EXIT_CODE=1
                    continue
                fi
                printf '%s\n' "path not found, resolving via basename+owner: $_ENTRY_PATH → $_CURRENT_OWNER/$_REPO_BASENAME"
                _REMOTE_URL="https://github.com/$_CURRENT_OWNER/$_REPO_BASENAME.git"
                ;;
            *)
                printf '%s\n' "cannot resolve remote for path: $_ENTRY_PATH — skipping" >&2
                EXIT_CODE=1
                continue
                ;;
        esac
    fi

    SIBLING="$(printf '%s\n' "$_REMOTE_URL" | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|; t; s|.*github\.com[:/]\(.*\)$|\1|')"

    if ! [[ "$SIBLING" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        printf '%s\n' "invalid resolved repo format: $SIBLING (from path: $_ENTRY_PATH) — skipping" >&2
        EXIT_CODE=1
        continue
    fi

    (
        set -e

        slug="${SIBLING//\//-}"
        DEST="$GIT_WORK_DIR/$slug"

        if ! git clone "https://x-access-token:$PROPAGATE_LABELS_PAT@github.com/$SIBLING.git" "$DEST"; then
            printf '%s\n' "clone failed for $SIBLING — skipping" >&2
            exit 1
        fi

        git -C "$DEST" remote set-url origin "https://github.com/$SIBLING.git"
        git -C "$DEST" config user.email "github-actions[bot]@users.noreply.github.com"
        git -C "$DEST" config user.name "github-actions[bot]"

        mkdir -p "$DEST/.github"
        tmp="$(mktemp)"
        { printf '%s\n' "$GENERATED_HEADER"; cat "$CANONICAL_LABELS_FILE"; } > "$tmp"
        cp "$tmp" "$DEST/.github/labels.yml"
        rm -f "$tmp"

        git -C "$DEST" add .github/labels.yml
        if git -C "$DEST" diff --cached --quiet; then
            printf '%s\n' "$SIBLING: labels.yml unchanged — skipping commit/push"
        else
            git -C "$DEST" commit -m "chore: propagate labels.yml from nirecom/agents"
            git -C "$DEST" push
        fi

        GH_TOKEN="$PROPAGATE_LABELS_PAT" bash "$SCRIPT_DIR/sync-labels.sh" \
            --repo "$SIBLING" "$CANONICAL_LABELS_FILE"
    )
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        EXIT_CODE=1
    fi
done < <(printf '%s\n' "$PROPAGATE_LABELS_REPOS" | tr ';' '\n')

exit "$EXIT_CODE"
