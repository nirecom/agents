#!/bin/bash
# Tests: feature/334/command/head
# Tags: 334, command-head
set -euo pipefail
AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}
run_with_timeout node "$AGENTS_DIR/tests/lib/test-command-head.js"
