# shellcheck shell=bash
# bin/lib/test-language-parts/pytest.sh — the pytest entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

declare -F crb_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"

# The reader child parses the file and never runs it; rc 79 = uv is not installed.
pytest_case_markers() {
    crb_native_path "${BASH_SOURCE[0]%/*}/pytest-case-reader.py"
    crb_run "$1" uv run --no-project python "$CRB_PATH"
}

# has_table_driven_pytest <file> — rc 0 when a test is decorated with @pytest.mark.parametrize
# (or `@mark.parametrize` after `from pytest import mark`); a line scan, so no uv is needed.
has_table_driven_pytest() {
    grep -qE '^[[:space:]]*@(pytest\.)?mark\.parametrize([[:space:](]|$)' "$1" 2>/dev/null
}

# pytest_env_clear_line <names-ERE> <line> — rc 0 when the line is one `os.environ.pop("NAME", None)`
# (either quote) of a named var and nothing else. Prints nothing.
pytest_env_clear_line() {
    local q="'" re
    re="^[[:space:]]*os\\.environ\\.pop\\((\"($1)\"|${q}($1)${q}),[[:space:]]*None\\)[[:space:]]*\$"
    [[ "${2%$'\r'}" =~ $re ]] && return 0
    return 1
}
