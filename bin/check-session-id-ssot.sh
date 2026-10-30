#!/usr/bin/env bash
# check-session-id-ssot.sh — thin adapter: the guard runs in Node (bin/check-session-id-ssot/main.js).
# Usage: check-session-id-ssot.sh [--staged] [file ...]   Exit: 0 clean | 1 violations | 2 usage or setup.
# Contract and rationale: docs/architecture/claude-code/session-id-resolution.md
set -euo pipefail

# The retired relay names; this exempt file is their one spelling, which main.js reads.
# shellcheck disable=SC2034 # read as text by bin/check-session-id-ssot/scan.js and the harness tests
TOMBSTONE_NAMES='CLAUDE_SESSION_ID|CLAUDE_ENV_FILE'

if ! command -v node >/dev/null 2>&1; then
  echo "check-session-id-ssot: node not found on PATH; the guard runs in Node" >&2
  exit 2
fi
main="$(dirname "${BASH_SOURCE[0]}")/check-session-id-ssot/main.js"
if [ ! -f "$main" ]; then
  echo "check-session-id-ssot: guard module unavailable ($main not found)" >&2
  exit 2
fi
exec node "$main" "$@"
