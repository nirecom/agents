#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"

# Normalize AGENTS_CONFIG_DIR to Windows-style path for Node.js on Windows/Cygwin.
AGENTS_CONFIG_DIR_N="$(cygpath -m "$AGENTS_CONFIG_DIR" 2>/dev/null || echo "$AGENTS_CONFIG_DIR")"

# Pass path and session ID via env vars — never via shell interpolation into the JS string.
RCS_BRIDGE="$AGENTS_CONFIG_DIR_N/hooks/lib/workflow-state/skip-signal-resolver.js" \
  RCS_SID="$SESSION_ID" \
  node -e '
const r = require(process.env.RCS_BRIDGE);
const v = r.resolveSkipConditionsFromComplexity(process.env.RCS_SID, "outline");
process.stdout.write(v ? "auto" : "judgment");
'
