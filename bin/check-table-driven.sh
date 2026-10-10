#!/usr/bin/env bash
# bin/check-table-driven.sh — T1-D: tests of parser/regex/allowlist sources must be table-driven.
# Usage: check-table-driven.sh [--staged] [file ...]  (--staged reads git diff --cached)
# Exit: 0 compliant (or no parser target), 1 a test lacks the table-driven structure,
#       2 usage error, unreadable registry, or an unreachable detector part.
# The detector is the matched test-language registry entry's tableDrivenDetector, else
# the tableDrivenFallbackEntry's (docs/architecture/claude-code/test-language-registry.md).

set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test-language-registry.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
tlr_load || { echo "ERROR: test language registry not readable" >&2; exit 2; }

# Parser/regex/allowlist target files (repo-relative paths or basenames)
PARSER_TARGETS=(
    "hooks/lib/sentinel-patterns.js"
    "hooks/lib/bash-write-patterns.js"
    "hooks/lib/command-parser.js"
    "hooks/lib/strip-quoted-args.js"
    "bin/scan-outbound.sh"
    "bin/sweep-issues/scan-stale-paths.js"
    ".private-info-blocklist"
    ".private-info-allowlist"
)

VIOLATIONS=0
STAGED=0
FILES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged)
            STAGED=1
            shift
            ;;
        -*)
            echo "Usage: check-table-driven.sh [--staged] [file ...]" >&2
            exit 2
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

if [[ $STAGED -eq 1 ]]; then
    while IFS= read -r f; do
        [[ -n "$f" ]] && FILES+=("$f")
    done < <(git -C "$SCRIPT_CHECKOUT_ROOT" diff --cached --name-only 2>/dev/null || true)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Usage: check-table-driven.sh [--staged] [file ...]" >&2
    exit 2
fi

# Check whether a file basename matches a parser target
is_parser_target() {
    local file="$1"
    local bname
    bname="$(basename "$file")"
    for target in "${PARSER_TARGETS[@]}"; do
        local tbname
        tbname="$(basename "$target")"
        if [[ "$bname" == "$tbname" ]]; then
            return 0
        fi
        # Also match by repo-relative path
        local rel="${file#"$SCRIPT_CHECKOUT_ROOT/"}"
        if [[ "$rel" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

# Read the Tests: header (the entry's comment prefix, within headerMaxLines) from a test
# file; print each source file listed
read_tests_header() {
    local file="$1" prefix
    prefix="$(tlr_comment_prefix "$file")"
    head -n "$TLR_HEADER_MAX_LINES" "$file" 2>/dev/null \
        | awk -v p="$prefix" 'index($0, p) == 1 { r = substr($0, length(p) + 1); if (r ~ /^[[:space:]]*Tests:/) { sub(/^[[:space:]]*Tests:[[:space:]]*/, "", r); print r } }' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# has_detector <path> — the file's entry has a tableDrivenDetector (sets TLR_ID).
has_detector() {
    tlr_match "$1" && _tlr_get "$TLR_ID" tableDrivenDetector.file
}

# Check a test file directly: read its # Tests: header and verify table-driven if needed
check_test_file() {
    local test_file="$1"
    local needs_table_driven=0

    while IFS= read -r src; do
        [[ -z "$src" ]] && continue
        if is_parser_target "$src"; then
            needs_table_driven=1
            break
        fi
    done < <(read_tests_header "$test_file")

    if [[ $needs_table_driven -eq 0 ]]; then
        return 0
    fi

    local id="$TLR_TABLE_DRIVEN_FALLBACK" rc=0
    if has_detector "$test_file"; then id="$TLR_ID"; fi
    tlr_call_part "$id" tableDrivenDetector "$test_file" || rc=$?
    if [[ $rc -eq 70 ]]; then
        echo "ERROR: cannot check $test_file: the $id table-driven detector is unavailable" >&2
        exit 2
    fi

    if [[ $rc -ne 0 ]]; then
        echo "MISSING table-driven in $test_file (required: # Tests: points to parser target)"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
}

# Find test files that reference a source file basename in their # Tests: header
find_and_check_tests() {
    local src_file="$1"
    local bname
    bname="$(basename "$src_file")"
    local found=0

    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        # Check if this test file's # Tests: header mentions the source basename
        if read_tests_header "$test_file" | grep -qF "$bname"; then
            found=1
            check_test_file "$test_file"
        fi
    done < <(tlr_find "$SCRIPT_CHECKOUT_ROOT/tests" table-driven | grep -v '_archive' || true)

    # If no test file found for a parser target, that's not a violation of this check
    # (audit-tests.sh handles missing test coverage separately)
    return 0
}

# Main loop
for file in "${FILES[@]}"; do
    # Normalize: strip SCRIPT_CHECKOUT_ROOT prefix if present
    rel_file="${file#"$SCRIPT_CHECKOUT_ROOT/"}"
    abs_file="$SCRIPT_CHECKOUT_ROOT/$rel_file"

    if [[ ! -f "$abs_file" ]]; then
        # Try treating as absolute path as-is
        if [[ -f "$file" ]]; then
            abs_file="$file"
            rel_file="$file"
        else
            # File may not exist yet (staged deletion, etc.) — skip
            continue
        fi
    fi

    # A file is treated as a test file if it lives under tests/ (repo-relative, or any
    # tests/ dir when its entry has a detector), or it has a # Tests: header.
    has_tests_header=0
    if read_tests_header "$abs_file" | grep -q .; then
        has_tests_header=1
    fi
    in_tests=0
    if [[ "$abs_file" == */tests/* ]] && has_detector "$abs_file"; then in_tests=1; fi

    if [[ "$rel_file" == tests/* ]] || [[ $in_tests -eq 1 ]] || [[ $has_tests_header -eq 1 ]]; then
        check_test_file "$abs_file"
    else
        if is_parser_target "$rel_file"; then
            find_and_check_tests "$rel_file"
        fi
    fi
done

if [[ $VIOLATIONS -gt 0 ]]; then
    exit 1
fi
exit 0
