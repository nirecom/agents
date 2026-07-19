# shellcheck shell=bash
# Helpers for TL3-hook-session-start.
# Sourced by ../TL3-hook-session-start.sh — assumes AGENTS_DIR, pass(), fail() defined.

# WSL-via-Windows bridge: CLAUDECODE not propagated, global settings read from Windows profile — test may pass on WSL but fail on macOS native

# Two-directory env var system:
#   CLAUDE_WORKFLOW_DIR — state files and turn markers (hooks/lib/workflow-state/state-io.js)
#   WORKFLOW_PLANS_DIR  — plans-dir fixtures (hooks/lib/workflow-plans-dir.js; MUST be absolute)

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

make_tmp_base() {
    local d
    d="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'f943-ss-')).replace(/\\\\/g,'/');
console.log(dir);
" 2>/dev/null)"
    [ -z "$d" ] && d="$(mktemp -d)"
    echo "$d"
}
