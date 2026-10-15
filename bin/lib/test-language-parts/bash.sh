# shellcheck shell=bash
# bin/lib/test-language-parts/bash.sh — the bash entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

# Check whether a test file (.sh) has the bash table-driven pattern
has_table_driven_sh() {
    local file="$1"
    grep -qE "while[[:space:]]+IFS='\|'[[:space:]]+read[[:space:]]+-r" "$file" 2>/dev/null
}

# bash_env_clear_line <names-ERE> <line> — rc 0 when the line only clears the named env vars: a
# whole-line `unset`, or every named var on it an operand of `-u`. Prints nothing.
bash_env_clear_line() {
    local names="$1" text="$2" unset_re dash_u_re name_re
    unset_re='^[[:space:]]*unset([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)+([[:space:]]+2>[[:space:]]*/dev/null)?([[:space:]]*\|\|[[:space:]]*true)?[[:space:]]*$'
    dash_u_re="(^|[[:space:]])-u[[:space:]]+($names)([^A-Za-z0-9_]|\$)"
    name_re="(^|[^A-Za-z0-9_])($names)([^A-Za-z0-9_]|\$)"
    [[ "$text" =~ $unset_re ]] && return 0
    # Drop each `-u NAME`, keeping the char after it; the last group is that char.
    while [[ "$text" =~ $dash_u_re ]]; do
        text="${text/"${BASH_REMATCH[0]}"/ ${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}}"
    done
    [[ "$text" =~ $name_re ]] && return 1
    return 0
}
