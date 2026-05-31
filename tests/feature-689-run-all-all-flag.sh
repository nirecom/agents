#!/bin/bash
# tests/feature-689-run-all-all-flag.sh
# Tests: tests/run-all.sh
# Tags: test-selection, run-all, issue-689
#
# Issue #689 — tests/run-all.sh learns a `--all` flag that runs the full
# tests/*.sh suite, while a default invocation excludes tests/_archive/.
# Bare positional file args run only the named files.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ALL="$AGENTS_DIR/tests/run-all.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

if [ ! -f "$RUN_ALL" ]; then
    echo "SKIP: tests/run-all.sh not present"
    exit 77
fi

TMPDIR_BASE="$(mktemp -d 2>/dev/null || echo "/tmp/f689-runall-$$")"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# C1: `tests/run-all.sh --all` iterates all *.sh test files (treats --all as
# a flag, not a literal glob). Verify by checking the output mentions multiple
# distinct test files.
test_C1_all_flag_iterates() {
    local out
    out="$(run_with_timeout 120 bash "$RUN_ALL" --all 2>&1)"
    # The --all flag, when implemented, should NOT be interpreted as a literal
    # filename. If implemented correctly, output references multiple tests/*.sh
    # files. If --all is treated as a glob, there's no file matching literally
    # `--all` so nothing runs and PASS/FAIL/SKIP all stay at 0.
    local matched
    matched="$(echo "$out" | grep -cE '(PASS|FAIL|SKIP): .*tests/.*\.sh' || true)"
    if [ "${matched:-0}" -ge 2 ]; then
        pass "C1_all_flag_iterates: --all triggers iteration over tests/*.sh ($matched entries)"
    else
        fail "C1_all_flag_iterates: --all did not iterate test suite (matched=$matched)
--- output ---
$out"
    fi
}

# C2: tests/run-all.sh <existing>.sh runs only that file.
test_C2_positional_single_file() {
    local target="$AGENTS_DIR/tests/feature-689-run-all-all-flag.sh"
    if [ ! -f "$target" ]; then
        skip "C2_positional_single_file: target file missing"
        return
    fi
    # Pass this very test file by name. Because run-all invokes `bash <file>`
    # and re-enters this script, we'd infinite-loop. Instead, write a tiny
    # throwaway test file in a temp dir and feed it.
    local tmp_test="$TMPDIR_BASE/tmp-passthrough.sh"
    cat > "$tmp_test" <<'EOF'
#!/bin/bash
echo "MARKER_TMP_PASSTHROUGH"
exit 0
EOF
    chmod +x "$tmp_test"
    local out
    out="$(run_with_timeout 120 bash "$RUN_ALL" "$tmp_test" 2>&1)"
    local marker_count file_count
    marker_count="$(echo "$out" | grep -c "MARKER_TMP_PASSTHROUGH" || true)"
    file_count="$(echo "$out" | grep -cE '^(PASS|FAIL|SKIP): ' || true)"
    if [ "${marker_count:-0}" -ge 1 ] && [ "${file_count:-0}" = "1" ]; then
        pass "C2_positional_single_file: only the named file ran (marker=$marker_count, files=$file_count)"
    else
        fail "C2_positional_single_file: marker=$marker_count file_count=$file_count
--- output ---
$out"
    fi
}

# C3: default invocation excludes tests/_archive/*. Plant a fake _archive
# test that would print a marker if executed, then verify the marker is
# absent from default run-all output.
test_C3_default_excludes_archive() {
    local archive_dir="$AGENTS_DIR/tests/_archive"
    local sentinel_test="$archive_dir/feature-689-archive-sentinel.sh"
    local created=0
    mkdir -p "$archive_dir"
    if [ ! -f "$sentinel_test" ]; then
        cat > "$sentinel_test" <<'EOF'
#!/bin/bash
echo "MARKER_ARCHIVE_LEAKED"
exit 0
EOF
        chmod +x "$sentinel_test"
        created=1
    fi

    local out
    out="$(run_with_timeout 120 bash "$RUN_ALL" 2>&1)"

    [ "$created" = "1" ] && rm -f "$sentinel_test"

    if echo "$out" | grep -q "MARKER_ARCHIVE_LEAKED"; then
        fail "C3_default_excludes_archive: tests/_archive/* was executed
--- output ---
$out"
    else
        pass "C3_default_excludes_archive: default run skips tests/_archive/*"
    fi
}

test_C1_all_flag_iterates
test_C2_positional_single_file
test_C3_default_excludes_archive

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
