#!/bin/bash
# Tests: feature/424/command/parser
# Tags: 424, command-parser
set -euo pipefail
DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}
run_with_timeout node "$DOTFILES_DIR/tests/lib/test-command-parser.js"
