#!/usr/bin/env bash
# Tests: hooks/workflow-mark.js
# Tags: workflow-mark, hook, TL3, run-e2e, scope:permanent
#
# Issue #943 — per-hook seam TL3 test: workflow-mark.js (PostToolUse).
# Real `claude -p` session emits a WORKFLOW_MARK_STEP sentinel via Bash;
# the PostToolUse hook writes steps.research.status=complete to the state file.
# Layer: TL3 (live claude -p session, real hook registration, real state file).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/TL3-hook-workflow-mark/helpers.sh
. "$AGENTS_DIR/tests/TL3-hook-workflow-mark/helpers.sh"
# shellcheck source=tests/TL3-hook-workflow-mark/main.sh
. "$AGENTS_DIR/tests/TL3-hook-workflow-mark/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
