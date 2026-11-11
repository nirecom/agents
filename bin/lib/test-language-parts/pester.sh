# shellcheck shell=bash
# bin/lib/test-language-parts/pester.sh — the pester entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

declare -F crb_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"

# The reader child parses the file and never runs it; rc 79 = pwsh is not installed.
pester_case_markers() {
    crb_native_path "${BASH_SOURCE[0]%/*}/pester-case-reader.ps1"
    crb_run "$1" pwsh -NoProfile -NonInteractive -File "$CRB_PATH"
}

# has_table_driven_pester <file> — the analyzer's table-driven op on the AST. rc 0 table-driven,
# 1 not, 70 cannot judge (pwsh missing, the child failed or the file does not parse).
has_table_driven_pester() {
    local out a
    command -v pwsh >/dev/null 2>&1 || return 70
    crb_native_path "${BASH_SOURCE[0]%/*}/pester-case-analyzer.ps1"; a="$CRB_PATH"
    crb_native_path "$1"
    out="$(pwsh -NoProfile -NonInteractive -File "$a" table-driven "$CRB_PATH")" || return 70
    [[ "${out%$'\r'}" == table-driven ]]
}
