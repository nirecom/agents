# shellcheck shell=bash
# bin/lib/test-language-parts/pester.sh — the pester entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

declare -F crb_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"

# The reader child parses the file and never runs it; rc 79 = pwsh is not installed.
pester_case_markers() {
    crb_native_path "${BASH_SOURCE[0]%/*}/pester-case-reader.ps1"
    crb_run "$1" pwsh -NoProfile -NonInteractive -File "$CRB_PATH"
}

# pester_env_clear_line <names-ERE> <line> — rc 0 when the line is one `Remove-Item [-Path]
# Env:[\]NAME` of a named var, optionally with -ErrorAction SilentlyContinue / -Force. Prints nothing.
pester_env_clear_line() {
    local re
    re='^[[:space:]]*Remove-Item([[:space:]]+-Path)?[[:space:]]+Env:\\?('"$1"')([[:space:]]+(-ErrorAction[[:space:]]+SilentlyContinue|-Force))*[[:space:]]*$'
    [[ "${2%$'\r'}" =~ $re ]] && return 0
    return 1
}
