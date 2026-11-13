#!/bin/bash
# run-bulk-dispatch.sh — Phase 4 bulk-sub-of: write TSV manifest + dispatch
# Usage: printf "title1\tbody1\ntitle2\tbody2" | bash run-bulk-dispatch.sh <manifest_path> <parent_n> [-- passthrough flags]
#   <manifest_path>: <PLANS_DIR>/<session-id>-bulk-dispatch-<n>.tsv, n = parent_n (checked before stdin is read; exit 2 if invalid)
# Stdin: TSV rows (title<TAB>body per child, \n-escaped bodies)
# Stdout: N URL lines (one per child, manifest order)
# Exit:  dispatch exit code; 2 on an invalid manifest path
set -euo pipefail

MANIFEST="${1-}"
PARENT_N="${2:?parent_n required}"
shift 2
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

usage_error() {
    echo "run-bulk-dispatch.sh: $1" >&2
    echo "Usage: bash run-bulk-dispatch.sh <manifest_path> <parent_n> [-- passthrough flags]  (manifest_path: <PLANS_DIR>/<session-id>-bulk-dispatch-<n>.tsv, n = parent_n)" >&2
    exit 2
}

[[ -n "$MANIFEST" ]] || usage_error "manifest_path is empty"
[[ ! -d "$MANIFEST" ]] || usage_error "manifest_path is a directory, not a file path: $MANIFEST"
[[ -d "$(dirname -- "$MANIFEST")" ]] || usage_error "parent directory of manifest_path does not exist: $MANIFEST"
[[ "$(basename -- "$MANIFEST")" == *-bulk-dispatch-*.tsv ]] || usage_error "manifest_path file name must match *-bulk-dispatch-*.tsv: $MANIFEST"

if [[ -e "$MANIFEST" ]]; then
    echo "run-bulk-dispatch.sh: warning: replacing the previous manifest at $MANIFEST; its titles are overwritten" >&2
fi
cat > "$MANIFEST"

exec bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-dispatch.sh" \
    --verdict bulk-sub-of \
    --parent "$PARENT_N" \
    --manifest "$MANIFEST" \
    -- "$@"
