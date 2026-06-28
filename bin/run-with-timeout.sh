#!/usr/bin/env bash
# Portable timeout wrapper — works on macOS (no timeout command) and Linux.
# Usage: bin/run-with-timeout.sh <seconds> <command> [args...]
set -euo pipefail
TIMEOUT_SECS=${1:?Usage: run-with-timeout.sh <seconds> <command> [args...]}
shift
if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" "$@"
else
    perl -e 'alarm $ARGV[0]; exec @ARGV[1..$#ARGV]' -- "$TIMEOUT_SECS" "$@"
fi
