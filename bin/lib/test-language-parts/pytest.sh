# shellcheck shell=bash
# bin/lib/test-language-parts/pytest.sh — the pytest entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

declare -F crb_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"

# The reader child parses the file and never runs it; rc 79 = uv is not installed.
pytest_case_markers() {
    crb_native_path "${BASH_SOURCE[0]%/*}/pytest-case-reader.py"
    crb_run "$1" uv run --no-project python "$CRB_PATH"
}

# has_table_driven_pytest <file> — the analyzer's table-driven op on the syntax tree. rc 0 table-driven,
# 1 not, 70 cannot judge (uv missing, the child failed or the file does not parse).
has_table_driven_pytest() {
    local out a
    command -v uv >/dev/null 2>&1 || return 70
    crb_native_path "${BASH_SOURCE[0]%/*}/pytest-case-analyzer.py"; a="$CRB_PATH"
    crb_native_path "$1"
    out="$(uv run --no-project python "$a" table-driven "$CRB_PATH")" || return 70
    [[ "${out%$'\r'}" == table-driven ]]
}
