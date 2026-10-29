# shellcheck shell=bash
# bin/lib/test-language-parts/bash.sh — the bash entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

# Check whether a test file (.sh) has the bash table-driven pattern
has_table_driven_sh() {
    local file="$1"
    grep -qE "while[[:space:]]+IFS='\|'[[:space:]]+read[[:space:]]+-r" "$file" 2>/dev/null
}
