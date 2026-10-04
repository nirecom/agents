# shellcheck shell=bash
# bin/lib/test-language-parts/js.sh — the js entry's parts in the test-language registry.
# Source only; bin/lib/test-language-registry.sh (tlr_call_part) loads it on first use.

# Check whether a test file (.js) has the JS table-driven pattern
has_table_driven_js() {
    local file="$1"
    grep -qE "cases\.forEach\(|for \(const " "$file" 2>/dev/null
}
