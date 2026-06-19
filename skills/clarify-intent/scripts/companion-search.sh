#!/usr/bin/env bash
# companion-search.sh — companion-issue search helper for clarify-intent CI-2b
# Usage: companion-search.sh --primary N --exclude N1,N2,...
#
# Exits:
#   0 — candidates found (confirmation needed)
#   1 — skip (non-GitHub remote, no candidates, or missing --primary)
#
# On exit 0: TSV to stdout — <N>\t<title>\t<reason>\t<state>
set -euo pipefail

PRIMARY=""
EXCLUDE_CSV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary) PRIMARY="${2:-}"; shift 2 ;;
        --exclude) EXCLUDE_CSV="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$PRIMARY" ] && exit 1

# GitHub gate
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" >/dev/null 2>&1 || exit 1

# Run search
RESULTS=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/find-companion-issues.sh" \
    --primary "$PRIMARY" \
    ${EXCLUDE_CSV:+--exclude "$EXCLUDE_CSV"} \
    2>/dev/null) || RESULTS=""

[ -z "$RESULTS" ] && exit 1

printf '%s\n' "$RESULTS"
