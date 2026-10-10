#!/bin/bash
set -euo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${SESSION_ID:?SESSION_ID not set}"

# Normalize SCRIPT_CHECKOUT_ROOT to Windows-style path for Node.js on Windows/Cygwin.
SCRIPT_CHECKOUT_ROOT_N="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT" 2>/dev/null || echo "$SCRIPT_CHECKOUT_ROOT")"

# Pass path and session ID via env vars — never via shell interpolation into the JS string.
RCS_BRIDGE="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state/skip-signal-resolver.js" \
  RCS_SID="$SESSION_ID" \
  node -e '
const r = require(process.env.RCS_BRIDGE);
const v = r.resolveSkipConditionsFromComplexity(process.env.RCS_SID, "outline");
process.stdout.write(v ? "auto" : "judgment");
'
