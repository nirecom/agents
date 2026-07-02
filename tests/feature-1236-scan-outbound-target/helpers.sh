#!/bin/bash
# Shared helpers for feature-1236-scan-outbound-target tests.
# Sourced by part-a.sh and part-b.sh — not a standalone runner.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_NODE="$AGENTS_DIR"
fi

HOOK_SRC="$AGENTS_DIR/hooks/scan-outbound.js"
FORGE_EXTRACT_SRC="$AGENTS_DIR/hooks/lib/forge-write-extract.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT
