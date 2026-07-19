# shellcheck shell=bash
# Helpers for feature-943-e2e-stop-final-report-guard.
# Sourced by ../feature-943-e2e-stop-final-report-guard.sh — assumes AGENTS_DIR, pass(), fail() defined.

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
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'f943-sfr-')).replace(/\\\\/g,'/');
console.log(dir);
" 2>/dev/null)"
    [ -z "$d" ] && d="$(mktemp -d)"
    echo "$d"
}

# write_final_report_env <plans-dir> <sid>
# Writes <sid>-final-report-env.json with all 4 required categories set to
# not_required plus their _REASON counterparts — the fixture that arms the guard.
write_final_report_env() {
    local plans="$1" sid="$2"
    cat > "$plans/$sid-final-report-env.json" <<ENV_EOF
{
  "CC_RESTART_REQUIRED": "not_required",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "not_required",
  "OS_REBOOT_REASON": ""
}
ENV_EOF
}
