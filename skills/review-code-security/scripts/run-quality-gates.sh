#!/usr/bin/env bash
# Run code-quality lint gates alongside the security review.
# Advisory only — non-zero exit per gate is a warning, not a blocker.
set -uo pipefail

_resolve_merge_base() {
    local base=""
    if git fetch origin main --no-tags 2>/dev/null; then
        base=$(git merge-base origin/main HEAD 2>/dev/null || true)
    fi
    if [ -z "${base:-}" ]; then
        base=$(git merge-base main HEAD 2>/dev/null || true)
    fi
    if [ -z "${base:-}" ]; then
        base=HEAD~1
        echo "[run-quality-gates] merge-base fallback: HEAD~1" >&2
    fi
    echo "$base"
}

MERGE_BASE=$(_resolve_merge_base)

review-code-codex --base "$MERGE_BASE" --context "${AGENTS_CONFIG_DIR}/rules/core-principles.md" || true
review-skill-size --base "$MERGE_BASE" || true
review-code-size --base "$MERGE_BASE" || true
review-env-example --base "$MERGE_BASE" || true
review-step-numbers --base "$MERGE_BASE" || true
review-e2e-coverage --base "$MERGE_BASE" || true
review-bare-python --base "$MERGE_BASE" || true
