#!/usr/bin/env bash
# bin/mutation-probe.sh — T1-E1 lightweight mutation probe: replaces single-line
# const NAME = /regex/; declarations one at a time with /(?!)/ and verifies the test FAILs.
# Usage: mutation-probe.sh [--help] [--test-cmd CMD] [--threshold PCT] <target-js-file>
# Exit: 0 score meets threshold / 1 below threshold or no constants found /
#       2 usage error, file not found, unreadable registry, or a mutant not run /
#       77 the auto-detected test's launch.requires tool is not on PATH (nothing mutated)

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_help() {
    cat <<'HELP'
Usage: mutation-probe.sh [options] <target-js-file>

T1-E1 lightweight mutation probe. Mutates single-line const NAME = /regex/; declarations
one at a time and verifies that the test suite FAILs for each mutation.

Options:
  --help        Show this help and exit (exit 0)
  --test-cmd    Test command to run (default: auto-detect from # Tests: header)
  --threshold   Pass threshold in % (default: 80)

Exit codes:
  0 = mutation score meets threshold
  1 = mutation score below threshold or no regex constants found
  2 = usage error, target file not found, unreadable test language registry,
      or a mutant whose test was not launched (NOT RUN; no score)
  77 = the auto-detected test needs a tool that is not on PATH (nothing mutated)

Partial coverage: only single-line const NAME = /regex/; form is handled.
Multi-line forms and WRITE_PATTERNS arrays are excluded (T1-E2/Stryker target).
HELP
}

TARGET=""
TEST_CMD=""        # --test-cmd: trusted operator string, executed via bash -c
TEST_CMD_ARGV=()   # auto-detect: safe array, executed directly
USE_ARGV=false
VIA_EXEC=false     # auto-detected test launched through run_all_exec (bin/lib/run-all-launch.sh)
THRESHOLD=80

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --test-cmd)
            TEST_CMD="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 2
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "ERROR: target JS file required" >&2
    show_help >&2
    exit 2
fi

# Resolve absolute path
if [[ "$TARGET" != /* ]]; then
    TARGET="$SCRIPT_CHECKOUT_ROOT/$TARGET"
fi

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: file not found: $TARGET" >&2
    exit 2
fi

basename_target="$(basename "$TARGET")"

# Emit partial coverage warnings for known files
case "$basename_target" in
    sentinel-patterns.js)
        echo "WARNING: sentinel-patterns.js has many multi-line constant forms." >&2
        echo "         Only single-line const forms are probed (partial coverage)." >&2
        echo "         Full coverage is planned for T1-E2 (Stryker)." >&2
        ;;
    bash-write-patterns.js)
        echo "WARNING: regex fields inside WRITE_PATTERNS array in bash-write-patterns.js" >&2
        echo "         are excluded (partial coverage). Only single-line const forms are probed." >&2
        ;;
esac

# Auto-detect test command if not specified
if [[ -z "$TEST_CMD" ]]; then
    bname_noext="${basename_target%.js}"
    if [[ -f "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-${bname_noext}.js" ]]; then
        TEST_CMD_ARGV=(node "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-${bname_noext}.js")
        USE_ARGV=true
    else
        # shellcheck source=lib/test-language-registry.sh
        if ! . "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh" || ! tlr_load; then
            echo "ERROR: test language registry not readable" >&2
            exit 2
        fi
        # The first supported registry entry (table order) with a test naming the target.
        # grep only narrows the candidates; a header line (its own commentPrefix, line start,
        # within headerMaxLines) decides.
        found_test=""
        while IFS= read -r g; do
            [[ -n "$g" ]] || continue
            while IFS= read -r cand; do
                tlr_comment_prefix "$cand" >/dev/null
                if awk -v p="$TLR_COMMENT_PREFIX Tests:" -v b="$basename_target" -v M="$TLR_HEADER_MAX_LINES" \
                    'FNR > M + 0 { exit } index($0, p) == 1 && index(substr($0, length(p) + 1), b) { f = 1; exit } END { exit !f }' "$cand"; then
                    found_test="$cand"
                    break
                fi
            done < <(grep -rlF -e "$basename_target" "$SCRIPT_CHECKOUT_ROOT/tests" --include="$g" 2>/dev/null)
            [[ -n "$found_test" ]] && break
        done < <(tlr_globs supported)
        if [[ -n "$found_test" ]]; then
            if tlr_match "$found_test" && _tlr_get "$TLR_ID" launch.requires && ! command -v "$_TLR_V" >/dev/null 2>&1; then
                echo "SKIP: $_TLR_V not on PATH (mutation probe not run)"
                exit 77
            fi
            # shellcheck source=lib/run-all-launch.sh
            [[ -f "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh" ]] && . "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
            declare -F run_all_exec >/dev/null || run_all_exec() { tlr_exec_plain "$@"; }
            TEST_CMD_ARGV=(run_all_exec "$found_test" /dev/null /dev/null)
            USE_ARGV=true
            VIA_EXEC=true
        else
            echo "ERROR: no test file found for $basename_target" >&2
            echo "       Use --test-cmd to specify the test command." >&2
            exit 2
        fi
    fi
fi

TARGET_ABS="$TARGET"
BACKUP="${TARGET_ABS}.probe-backup"

# Safety trap: always restore backup on exit
trap 'rc=$?; if [[ -f "$BACKUP" ]]; then mv "$BACKUP" "$TARGET_ABS"; fi; exit $rc' EXIT INT TERM

TOTAL=0
KILLED=0
NOT_RUN=0

# Find single-line const regex declarations
# Pattern: const NAME = /.../ [flags];
CONST_PATTERN='^[[:space:]]*const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*/[^/].*[gimsuvyd]*;'

mapfile -t MATCHES < <(grep -En "$CONST_PATTERN" "$TARGET_ABS" 2>/dev/null || true)

for match in "${MATCHES[@]}"; do
    [[ -z "$match" ]] && continue
    lineno="${match%%:*}"
    line="${match#*:}"

    # Extract const name
    const_name="$(echo "$line" | grep -oE 'const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | head -1 | awk '{print $NF}' || true)"
    [[ -z "$const_name" ]] && continue
    # Guard: const_name must be a plain identifier (no shell metacharacters for sed safety)
    [[ "$const_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    TOTAL=$((TOTAL + 1))

    # Backup original
    cp "$TARGET_ABS" "$BACKUP"

    # Replace the matching line with a never-match mutation (use | as sed delimiter)
    sed -i "${lineno}s|.*|const ${const_name} = /(?!)/; // MUTATED by mutation-probe.sh|" "$TARGET_ABS"

    # Run test and capture exit code
    # Auto-detect case: use array to avoid quote-injection (M1 security fix)
    # --test-cmd case: trusted operator input, bash -c is acceptable
    test_rc=0
    unset RUN_ALL_EXEC_LAUNCHED
    if $USE_ARGV; then
        "${TEST_CMD_ARGV[@]}" >/dev/null 2>&1 || test_rc=$?
    else
        bash -c "$TEST_CMD" >/dev/null 2>&1 || test_rc=$?
    fi

    # Restore from backup
    mv "$BACKUP" "$TARGET_ABS"

    # A launcher that leaves RUN_ALL_EXEC_LAUNCHED unset is taken to have launched.
    if $VIA_EXEC && [[ "${RUN_ALL_EXEC_LAUNCHED:-1}" == 0 ]]; then
        echo "NOT RUN: $const_name (line $lineno — test not launched)"
        NOT_RUN=$((NOT_RUN + 1))
    elif [[ $test_rc -ne 0 ]]; then
        echo "KILLED: $const_name (line $lineno)"
        KILLED=$((KILLED + 1))
    else
        echo "LIVE:   $const_name (line $lineno — coverage gap)"
    fi
done

if [[ $TOTAL -eq 0 ]]; then
    echo "INFO: no single-line const regex found in $TARGET" >&2
    echo "      (partial coverage — see bin/mutation-probe.sh --help)" >&2
    exit 1
fi

if [[ $NOT_RUN -gt 0 ]]; then
    echo "ERROR: $NOT_RUN of $TOTAL mutant(s) not run (test not launched); no score" >&2
    exit 2
fi

SCORE=$(( KILLED * 100 / TOTAL ))
echo ""
echo "=== Mutation Score ==="
echo "KILLED: $KILLED / $TOTAL (score: ${SCORE}%)"
echo "Threshold: ${THRESHOLD}%"

if [[ $SCORE -ge $THRESHOLD ]]; then
    echo "PASS: mutation score meets threshold"
    exit 0
else
    echo "FAIL: mutation score below threshold"
    exit 1
fi
