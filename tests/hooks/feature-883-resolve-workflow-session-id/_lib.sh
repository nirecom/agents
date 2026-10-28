# tests/hooks/feature-883-resolve-workflow-session-id/_lib.sh
# Shared helpers for feature-883-resolve-workflow-session-id tests.
# Sourced by the dispatcher after it sets SCRIPT_CHECKOUT_ROOT and pins the isolation dirs; relies on `set -u` from the dispatcher.

if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

RESOLVE_WSID_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/resolve-workflow-session-id.js"
STATE_IO_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io.js"
SUPERVISOR_STATE_WRITER_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/supervisor-state-writer.js"

# pass / fail / skip / run_with_timeout come from tests/lib/harness.sh (sourced by the dispatcher).

require_function() {
    local fn="$1" label="$2"
    node -e "const m=require('$RESOLVE_WSID_NODE'); if(typeof m['$fn']!=='function') process.exit(1);" 2>/dev/null
    if [ $? -ne 0 ]; then skip "$label (resolveWorkflowSessionId not implemented yet)"; return 1; fi
    return 0
}

# Today's local date as YYYYMMDD (used by date-sanity guard).
TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
YESTERDAY=$(node -e "const d=new Date(Date.now()-86400000); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)

# Invoke resolveWorkflowSessionId({}) with WORKFLOW_PLANS_DIR=$1 and (optional) work_dir=$2
# (defaults to $1). process.cwd() is set to work_dir so Priority 1 (WORKTREE_NOTES.md) can be
# controlled per-test. CLAUDE_CODE_SESSION_ID is unset so the host session cannot leak in.
# Stdout: 'NULL' or the resolved sid.
call_resolve() {
    local plans_dir="$1" work_dir="${2:-$1}"
    (cd "$work_dir" && WORKFLOW_PLANS_DIR="$plans_dir" \
        run_with_timeout 5 env -u CLAUDE_CODE_SESSION_ID node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null)
}

# Variant of call_resolve that injects CLAUDE_CODE_SESSION_ID explicitly.
call_resolve_with_code_sid() {
    local plans_dir="$1" code_sid="$2" work_dir="${3:-$1}"
    (cd "$work_dir" && WORKFLOW_PLANS_DIR="$plans_dir" CLAUDE_CODE_SESSION_ID="$code_sid" \
        run_with_timeout 5 node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null)
}

# Set mtime on a list of files: pairs of (path, offset-seconds-from-now).
set_mtimes() {
    # Args: path1 offset1 path2 offset2 ...
    node -e "
const fs = require('fs');
const args = process.argv.slice(1);
const now = Date.now() / 1000;
for (let i = 0; i < args.length; i += 2) {
    const p = args[i];
    const off = parseFloat(args[i+1]);
    const t = now + off;
    fs.utimesSync(p, t, t);
}
" -- "$@" 2>/dev/null
}
