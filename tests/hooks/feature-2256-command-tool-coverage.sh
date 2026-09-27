#!/usr/bin/env bash
# tests/hooks/feature-2256-command-tool-coverage.sh
# Tests: hooks/lib/tool-command-text.js, hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: supervisor, command-tool, sentinel, normalization, TL2, scope:issue-specific

# #2256 round-2 C1 — the sentinel path must behave identically whether the command
# arrives as Bash.command, runInTerminal.command, runCommands.commands[0] or
# runCommands.commands[1]. The last shape is the load-bearing one: sentinel-patterns.js
# anchors ^...$ without the /m flag, so only per-element matching can see it.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECTION_DIR="$AGENTS_ROOT/tests/hooks/feature-2256-command-tool-coverage"
RWT="$AGENTS_ROOT/bin/run-with-timeout.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

# shellcheck source=./lib/section-runner.sh
. "$AGENTS_ROOT/tests/lib/section-runner.sh"

if ! command -v node >/dev/null 2>&1; then
    fail "node-missing" "node is required — this suite drives real hook processes"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    fail "git-missing" "git is required — the fixtures are real repositories"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

run_section "module-contract.sh" 120
run_section "gate-and-mark.sh" 300
run_section "sibling-hooks.sh" 240

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
