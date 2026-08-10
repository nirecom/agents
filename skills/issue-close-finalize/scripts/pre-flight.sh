#!/bin/bash
# pre-flight.sh — issue-close-finalize Pre-flight check.
#
# Resolves OWNER_REPO from the checkout's ORIGIN remote (#1899).
# Output (stdout, sourceable):
#   OWNER_REPO=<owner/repo>
# Exit codes:
#   0  — GitHub remote detected; OWNER_REPO emitted.
#   1  — non-GitHub remote OR error (caller should skip via `|| exit 0` if
#        treating non-GitHub as no-op). Diagnostic goes to stderr.
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

# shellcheck source=../../../bin/github-issues/lib/origin-repo.sh
. "$AGENTS_CONFIG_DIR/bin/github-issues/lib/origin-repo.sh"

rc=0
OWNER_REPO=$(resolve_origin_owner_repo) || rc=$?
if [[ "$rc" -ne 0 ]] || [[ -z "$OWNER_REPO" ]]; then
    echo "[GITHUB_ISSUES disabled: origin remote is missing or not a github.com repo (rc=$rc), skipping issue-close-finalize]" >&2
    exit 1
fi

echo "OWNER_REPO=$OWNER_REPO"
