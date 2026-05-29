#!/bin/bash
# pre-flight.sh — issue-close-finalize Pre-flight check.
#
# Checks for GitHub remote and resolves OWNER_REPO via gh.
# Output (stdout, sourceable):
#   OWNER_REPO=<owner/repo>
# Exit codes:
#   0  — GitHub remote detected; OWNER_REPO emitted.
#   1  — non-GitHub remote OR error (caller should skip via `|| exit 0` if
#        treating non-GitHub as no-op). Diagnostic goes to stderr.
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

rc=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" || rc=$?
if [[ "$rc" -eq 1 ]]; then
    echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping issue-close-finalize]" >&2
    exit 1
fi
# rc=0 (GitHub) or rc=2 (unknown): proceed

OWNER_REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')
if [[ -z "$OWNER_REPO" ]]; then
    echo "Error: unable to resolve owner/repo via gh" >&2
    exit 1
fi

echo "OWNER_REPO=$OWNER_REPO"
