# shellcheck shell=bash
# bin/lib/test-language-parts/pester.sh — the pester entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

declare -F crb_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"

# The reader child parses the file and never runs it; rc 79 = pwsh is not installed.
pester_case_markers() {
    crb_native_path "${BASH_SOURCE[0]%/*}/pester-case-reader.ps1"
    crb_run "$1" pwsh -NoProfile -NonInteractive -File "$CRB_PATH"
}

# has_table_driven_pester <file> — rc 0 when an `It` line carries a -ForEach / -TestCases table
# (a line scan, so no pwsh is needed; PowerShell names are case-insensitive).
has_table_driven_pester() {
    grep -qiE '^[[:space:]]*It[[:space:]].*[[:space:]]-(ForEach|TestCases)([[:space:]]|$)' "$1" 2>/dev/null
}
