#!/usr/bin/env bash
# detect-non-github.sh — shared non-GitHub-remote detection wrapper.
#
# Wraps bin/is-github-dotcom-remote for SKILL.md consumers that need the
# non-GitHub skip gate. Emits a context-specific skip message to STDOUT
# (single output channel; no stderr) when a non-GitHub remote is detected.
#
# Usage: detect-non-github.sh "<context-label>"
#   <context-label> is interpolated into the skip message, e.g.
#   "Phase 1 pre-flight" or "issue-close-stage".
#
# Exit codes (normalized from is-github-dotcom-remote 3-value contract):
#   0 — GitHub remote (or unknown/fail-open); caller proceeds with gh.
#   1 — non-GitHub remote; skip message printed to stdout; caller skips gh.
#
# Note: rc=2 (unknown) from is-github-dotcom-remote is folded into exit 0
#       (fail-open), preserving prior inline-block behavior where NON_GITHUB
#       stayed 0 on rc=2. set -e is intentionally NOT used so the non-zero
#       rc from is-github-dotcom-remote does not abort this wrapper.
set -u

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

LABEL="${1:-issue routing}"

rc=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" || rc=$?

if [ "$rc" = "1" ]; then
    echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping ${LABEL}]"
    exit 1
fi

# rc=0 (GitHub) or rc=2 (unknown/error): fail-open, proceed.
exit 0
