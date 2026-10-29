#!/bin/bash
# Scan content for private information patterns (#2507: the scanner is bin/scan-outbound.d/cli.js).
# Usage: scan-outbound.sh [--stdin [label]] [--manifest] [file ...]
# Exit: 0 clean, 1 hard violation, 2 warn only, 3 usage error, 4 cannot scan (fail-closed).

set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
    echo "Error: node not found on PATH — cannot scan" >&2
    exit 4
fi
cli="$(dirname "$0")/scan-outbound.d/cli.js"
if [[ ! -f "$cli" ]]; then
    echo "Error: scanner implementation not found at $cli — cannot scan" >&2
    exit 4
fi
exec node "$cli" "$@"
