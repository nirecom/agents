# tests/feature-883-supervisor-guard-wsid/_lib.sh
# Shared helpers for feature-883-supervisor-guard-wsid tests.
# Sourced by the dispatcher; relies on `set -u` from the dispatcher.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-guard.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
RESOLVE_WSID_NODE="$_AGENTS_DIR_NODE/hooks/lib/resolve-workflow-session-id.js"
WORKFLOW_STATE_IO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

seed_state() {
    local tmp="$1" sid="$2" alert_json="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert = $alert_json;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# seed_workflow_started(tmp, sid): mark `workflow_init` complete for `sid`
# in the workflow-state store rooted at `$tmp` (hooks/workflow-state, keyed
# by CLAUDE_WORKFLOW_DIR — a DIFFERENT store than the supervisor alert state
# that seed_state() writes into WORKFLOW_PLANS_DIR). Since #1794,
# hooks/supervisor-guard.js gates branch (3) alert_armed_at on
# isWorkflowStarted(sessionId), which reads THIS store. Callers must invoke
# this with the same session id that the hook will resolve at runtime, and
# must also export CLAUDE_WORKFLOW_DIR="$tmp" on the hook invocation itself
# so both reads and writes land in the same fixture directory.
seed_workflow_started() {
    local tmp="$1" sid="$2"
    CLAUDE_WORKFLOW_DIR="$tmp" run_with_timeout 5 node -e "
const { markStep } = require('$WORKFLOW_STATE_IO_NODE');
markStep('$sid', 'workflow_init', 'complete');
" >/dev/null 2>&1
}

require_wsid() {
    local label="$1"
    if ! node -e "const m=require('$RESOLVE_WSID_NODE'); if(typeof m.resolveWorkflowSessionId!=='function') process.exit(1);" 2>/dev/null; then
        skip "$label (resolveWorkflowSessionId not implemented yet)"
        return 1
    fi
    return 0
}
