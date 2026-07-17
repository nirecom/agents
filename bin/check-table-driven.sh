#!/usr/bin/env bash
# bin/check-table-driven.sh
# T1-D enforcement: checks that test files for parser/regex/allowlist source files
# have a table-driven pattern.
#
# Usage: check-table-driven.sh [--staged] [file ...]
#   --staged: read staged files from git diff --cached --name-only
#   file ...: explicit file list (test files or source files)
#
# Exit codes:
#   0 = all compliant (or no parser targets found)
#   1 = test file(s) missing table-driven structure
#   2 = usage error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parser/regex/allowlist target files (repo-relative paths or basenames)
PARSER_TARGETS=(
    "hooks/lib/sentinel-patterns.js"
    "hooks/lib/bash-write-patterns.js"
    "hooks/lib/command-parser.js"
    "hooks/lib/strip-quoted-args.js"
    "bin/scan-outbound.sh"
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
    done < <(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || true)
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
        local rel="${file#"$REPO_ROOT/"}"
        if [[ "$rel" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

# Check whether a test file (.sh) has the bash table-driven pattern
has_table_driven_sh() {
    local file="$1"
    grep -qE "while[[:space:]]+IFS='\|'[[:space:]]+read[[:space:]]+-r" "$file" 2>/dev/null
}

# Check whether a test file (.js) has the JS table-driven pattern
has_table_driven_js() {
    local file="$1"
    grep -qE "cases\.forEach\(|for \(const " "$file" 2>/dev/null
}

# Read the # Tests: header from a test file; print each source file listed
read_tests_header() {
    local file="$1"
    # Read first 10 lines, find # Tests: line
    head -10 "$file" 2>/dev/null | grep -E '^#[[:space:]]*Tests:' | sed 's/^#[[:space:]]*Tests:[[:space:]]*//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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

    local compliant=0
    case "$test_file" in
        *.sh)
            has_table_driven_sh "$test_file" && compliant=1
            ;;
        *.js)
            has_table_driven_js "$test_file" && compliant=1
            ;;
        *)
            has_table_driven_sh "$test_file" && compliant=1
            ;;
    esac

    if [[ $compliant -eq 0 ]]; then
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
    done < <(find "$REPO_ROOT/tests" -name "*.sh" -o -name "*.js" 2>/dev/null | grep -v '_archive' || true)

    # If no test file found for a parser target, that's not a violation of this check
    # (audit-tests.sh handles missing test coverage separately)
    return 0
}

# Main loop
for file in "${FILES[@]}"; do
    # Normalize: strip REPO_ROOT prefix if present
    rel_file="${file#"$REPO_ROOT/"}"
    abs_file="$REPO_ROOT/$rel_file"

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

    # Determine if this is a test file or source file.
    # A file is treated as a test file if:
    #   1. It lives under tests/, OR
    #   2. It has a # Tests: header (test file at arbitrary path, e.g. mktemp in tests)
    has_tests_header=0
    if read_tests_header "$abs_file" | grep -q .; then
        has_tests_header=1
    fi

    if [[ "$rel_file" == tests/* ]] || [[ "$abs_file" == */tests/*.sh ]] || [[ "$abs_file" == */tests/*.js ]] || [[ $has_tests_header -eq 1 ]]; then
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
