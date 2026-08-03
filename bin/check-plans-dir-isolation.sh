#!/bin/bash
# bin/check-plans-dir-isolation.sh
#
# Static audit classifier for the plans-dir dual-pin contract (#1799).
#
# A test that pins CLAUDE_WORKFLOW_DIR but NOT WORKFLOW_PLANS_DIR leaves
# supervisor-emit.js writing into the developer's real ~/.workflow-plans/ tree.
# This script classifies such half-pinned test files:
#
#   W-candidate — half-pinned AND statically reaches a supervisor-emit writer
#                 (workflow-gate.js / workflow-mark.js / supervisor-emit.js /
#                  report* facade). These MUST be dual-pinned.
#   N-candidate — half-pinned but only exercises read-only paths. Harmless
#                 today; dual-pin opportunistically.
#
# Files pinning BOTH vars are already isolated (skipped). Files pinning
# neither var are out of scope (skipped).
#
# Report tool, not a gate: always exits 0.
#
# Usage:
#   bin/check-plans-dir-isolation.sh [file ...]
#   bin/check-plans-dir-isolation.sh          # scans tests/*.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Static markers that indicate the file drives a code path calling safeAppend().
SUPERVISOR_EMIT_PATTERN='workflow-gate|workflow-mark|supervisor-emit|reportSentinel|reportBlock|reportFallback|reportRetrospective'

classify_file() {
    local file="$1"
    [ -f "$file" ] || return 0

    grep -q 'CLAUDE_WORKFLOW_DIR' "$file" 2>/dev/null || return 0
    # Both pinned → already isolated.
    if grep -q 'WORKFLOW_PLANS_DIR' "$file" 2>/dev/null; then
        return 0
    fi

    if grep -Eq "$SUPERVISOR_EMIT_PATTERN" "$file" 2>/dev/null; then
        echo "W-candidate: $(basename "$file")"
    else
        echo "N-candidate: $(basename "$file")"
    fi
}

main() {
    if [ "$#" -gt 0 ]; then
        for f in "$@"; do
            classify_file "$f"
        done
    else
        for f in "$REPO_ROOT"/tests/*.sh; do
            classify_file "$f"
        done
    fi
    return 0
}

main "$@"
exit 0
