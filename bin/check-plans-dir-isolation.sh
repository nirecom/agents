#!/bin/bash
# bin/check-plans-dir-isolation.sh — static audit of the plans-dir dual-pin contract (#1799).
# W-candidate: pins CLAUDE_WORKFLOW_DIR without WORKFLOW_PLANS_DIR and reaches a supervisor-emit
# writer (must be dual-pinned). N-candidate: half-pinned, read-only paths only. Contract:
# rules/test/fixture-isolation.md. Report tool, not a gate: always exits 0.
# Usage: bin/check-plans-dir-isolation.sh [file ...]   (no args: tests/ top-level supported tests)

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
        # shellcheck source=lib/test-language-registry.sh
        if ! { . "$REPO_ROOT/bin/lib/test-language-registry.sh" && tlr_load; }; then
            echo "ERROR: test language registry not readable; nothing scanned" >&2
            return 0
        fi
        tlr_list_dir_into "$REPO_ROOT/tests" supported || return 0
        for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do
            classify_file "$f"
        done
    fi
    return 0
}

main "$@"
exit 0
