#!/bin/bash
# step-e.sh <N> <MERGE_COMMIT>
#
# Phase 2 Step E: writes docs/history.md via the GitHub Contents API
# (single-file path) or the Git Data API (atomic rotation path) — no local
# git add/commit/push. Replaces the prior ISSUE_CLOSE_SKILL=1 env-var bypass
# (removed in #672).
#
# E.1   fetch current docs/history.md from GitHub into a staging file
# E.1a  invoke issue-to-history.sh --target <staging-file>
# E.check  no-op when sha256 unchanged
# E.2   validate staging file via github-contents-validate.sh
# E.3   rotation gate: >= 500 lines triggers doc-rotate.py + Git Data API commit
# E.4   single-file write via Contents API (or atomic write when rotated)
#
# Output (stdout, sourceable, KEY=value only):
#   STEP_E_STATUS=appended|noop|failed-E<n>
#
# All diagnostics go to stderr.
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

N="${1:?issue number required}"
MERGE_COMMIT="${2:-}"

emit() { echo "STEP_E_STATUS=$1"; }

# Resolve staging dir (outside any git repo — fail-open under enforce-worktree).
STAGING_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")
mkdir -p "$STAGING_DIR"
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)-$$}"
STAGING_FILE="$STAGING_DIR/${SESSION_ID}-history-staging.md"

# Resolve owner/repo/default branch.
if ! OWNER_REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
    echo "[step-e: failed to resolve owner/repo via gh]" >&2
    emit "failed-E1"
    exit 0
fi
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO#*/}"
DEF=$(gh api "repos/$OWNER/$REPO" --jq '.default_branch' 2>/dev/null || echo "main")

# --- E.1: fetch current docs/history.md into staging file ---------------
if ! RESP=$(gh api "repos/$OWNER/$REPO/contents/docs/history.md?ref=$DEF" 2>/dev/null); then
    echo "[step-e: E.1 failed — could not fetch docs/history.md from GitHub]" >&2
    emit "failed-E1"
    exit 0
fi
ORIG_SHA=$(printf '%s' "$RESP" | jq -r '.sha // empty')
printf '%s' "$RESP" | jq -r '.content' | tr -d '\n' | base64 -d > "$STAGING_FILE"
ORIG_HASH=$(sha256sum "$STAGING_FILE" | awk '{print $1}')

# --- E.1a: append entry via issue-to-history.sh -------------------------
COMMIT_FLAG=()
if [[ -n "$MERGE_COMMIT" ]]; then
    COMMIT_FLAG=(--commit "$MERGE_COMMIT")
else
    echo "[step-e: MERGE_COMMIT empty — invoking issue-to-history.sh without --commit]" >&2
fi

if ! bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh" \
        "$N" "${COMMIT_FLAG[@]}" --target "$STAGING_FILE" >&2; then
    echo "[step-e: E.1a failed (issue-to-history.sh)]" >&2
    rm -f "$STAGING_FILE"
    emit "failed-E1"
    exit 0
fi

# --- E.check: no-op detection -------------------------------------------
NEW_HASH=$(sha256sum "$STAGING_FILE" | awk '{print $1}')
if [[ "$ORIG_HASH" == "$NEW_HASH" ]]; then
    echo "[step-e: no-op (entry already present)]" >&2
    rm -f "$STAGING_FILE"
    emit "noop"
    exit 0
fi

# --- E.2: validate the staging file -------------------------------------
if ! bash "$AGENTS_CONFIG_DIR/bin/lib/github-contents-validate.sh" \
        --path "docs/history.md" \
        --file "$STAGING_FILE" \
        --commit-subject "docs(history): record issue #$N"; then
    echo "[step-e: E.2 validation failed]" >&2
    rm -f "$STAGING_FILE"
    emit "failed-E2"
    exit 0
fi

# --- E.3 + E.4: rotation gate + write -----------------------------------
LINES=$(wc -l < "$STAGING_FILE")
if (( LINES >= 500 )); then
    # Rotation path: doc-rotate.py produces archive files alongside STAGING_FILE.
    # Archives land in $STAGING_DIR/history/YYYY.md, which is what we want.
    if ! uv run "$AGENTS_CONFIG_DIR/bin/doc-rotate.py" "$STAGING_FILE" --threshold-warn 500 >&2; then
        echo "[step-e: doc-rotate.py failed]" >&2
        rm -f "$STAGING_FILE"
        emit "failed-E3"
        exit 0
    fi
    ROTATE_DIR="$(dirname "$STAGING_FILE")/history"
    FILES_ARGS=(--file "docs/history.md=$STAGING_FILE")
    if [[ -d "$ROTATE_DIR" ]]; then
        for archive in "$ROTATE_DIR"/*.md; do
            [[ -f "$archive" ]] || continue
            BASENAME=$(basename "$archive")
            FILES_ARGS+=(--file "docs/history/$BASENAME=$archive")
        done
    fi
    if ! bash "$AGENTS_CONFIG_DIR/bin/lib/github-git-data-write.sh" \
            --owner "$OWNER" --repo "$REPO" --branch "$DEF" \
            --message "docs(history): record issue #$N" \
            "${FILES_ARGS[@]}"; then
        echo "[step-e: E.4 atomic rotation write failed]" >&2
        [[ -d "$ROTATE_DIR" ]] && rm -rf "$ROTATE_DIR"
        rm -f "$STAGING_FILE"
        emit "failed-E4"
        exit 0
    fi
    [[ -d "$ROTATE_DIR" ]] && rm -rf "$ROTATE_DIR"
    rm -f "$STAGING_FILE"
else
    # Single-file path
    if ! bash "$AGENTS_CONFIG_DIR/bin/lib/github-contents-write.sh" \
            --owner "$OWNER" \
            --repo "$REPO" \
            --path "docs/history.md" \
            --file "$STAGING_FILE" \
            --message "docs(history): record issue #$N" \
            --branch "$DEF"; then
        echo "[step-e: E.4 single-file write failed]" >&2
        rm -f "$STAGING_FILE"
        emit "failed-E4"
        exit 0
    fi
    rm -f "$STAGING_FILE"
fi

# ORIG_SHA captured for future diagnostics; mark unused.
: "${ORIG_SHA:-}"

emit "appended"
