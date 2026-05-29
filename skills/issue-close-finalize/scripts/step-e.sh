#!/bin/bash
# step-e.sh <N> <MERGE_COMMIT>
#
# Idempotent doc-append + commit for issue-close-finalize Step E.
# E.1 — fetch issue + doc-append to docs/history.md
# E.2 — git add docs/history.md docs/history/
# E.check — detect no-op via git status --porcelain
# E.3 — commit when changes present
# E.4 — push to origin <default-branch>
#
# MERGE_COMMIT may be empty (when NEXT_STEPS does not contain J).
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

# --- E.1 -----------------------------------------------------------------
COMMIT_FLAG=()
if [[ -n "$MERGE_COMMIT" ]]; then
    COMMIT_FLAG=(--commit "$MERGE_COMMIT")
else
    echo "[step-e: MERGE_COMMIT empty — invoking issue-to-history.sh without --commit]" >&2
fi

if ! ISSUE_CLOSE_SKILL=1 bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh" \
        "$N" "${COMMIT_FLAG[@]}" >&2; then
    echo "[step-e: E.1 failed (issue-to-history.sh) — continuing]" >&2
    emit "failed-E1"
    exit 0
fi

# --- E.2 -----------------------------------------------------------------
if ! ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/ >&2; then
    echo "[step-e: E.2 failed (git add) — continuing]" >&2
    emit "failed-E2"
    exit 0
fi

# --- E.check -------------------------------------------------------------
if [[ -z "$(git status --porcelain docs/history.md docs/history/)" ]]; then
    echo "[step-e: no-op (entry already present)]" >&2
    emit "noop"
    exit 0
fi

# --- E.3 -----------------------------------------------------------------
if ! ISSUE_CLOSE_SKILL=1 git commit -m "docs(history): record issue #$N" >&2; then
    echo "[step-e: E.3 failed (git commit) — continuing]" >&2
    emit "failed-E3"
    exit 0
fi

# --- E.4 -----------------------------------------------------------------
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)
if [[ -z "$DEFAULT_BRANCH" ]]; then
    echo "[step-e: E.4 failed — refs/remotes/origin/HEAD unset. Remediation: git remote set-head origin <default-branch>]" >&2
    emit "failed-E4"
    exit 0
fi

if ! ISSUE_CLOSE_SKILL=1 git push origin "$DEFAULT_BRANCH" >&2; then
    echo "[step-e: E.4 failed (git push) — continuing]" >&2
    emit "failed-E4"
    exit 0
fi

emit "appended"
