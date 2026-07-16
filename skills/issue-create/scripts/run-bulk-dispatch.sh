#!/bin/bash
# run-bulk-dispatch.sh — Phase 4 bulk-sub-of: write TSV manifest + dispatch
# Usage: printf "title1\tbody1\ntitle2\tbody2" | bash run-bulk-dispatch.sh <plans_dir> <parent_n> [-- passthrough flags]
# Env:   AGENTS_CONFIG_DIR
# Stdin: TSV rows (title<TAB>body per child, \n-escaped bodies)
# Stdout: N URL lines (one per child, manifest order)
# Exit:  dispatch exit code
set -euo pipefail

PLANS_DIR="${1:?plans_dir required}"
PARENT_N="${2:?parent_n required}"
shift 2
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

MANIFEST="$PLANS_DIR/bulk-dispatch-$$.tsv"
cat > "$MANIFEST"

exec bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-dispatch.sh" \
    --verdict bulk-sub-of \
    --parent "$PARENT_N" \
    --manifest "$MANIFEST" \
    -- "$@"
