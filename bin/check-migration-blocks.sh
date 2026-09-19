#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_SCRIPT="$SCRIPT_DIR/lib/check-migration-blocks.js"
exec node "$NODE_SCRIPT" "$@"
