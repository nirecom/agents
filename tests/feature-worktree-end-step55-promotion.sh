#!/bin/bash
# tests/feature-worktree-end-step55-promotion.sh
#
# Worktree-end Step 5.5 promotion feature.
#
# Tests:
#   - bin/worktree-notes-triage.js CLI (list / annotate subcommands)
#   - bin/worktree-final-report.js golden output (existing script; refactor must
#     preserve byte-for-byte equivalence)
#
# Test-first: the triage CLI does not yet exist. F1–F7 SKIP-gracefully when the
# binary is absent. R1 (golden report) runs against the existing
# bin/worktree-final-report.js, which already produces the golden bytes — the
# refactor must preserve them.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
TRIAGE_BIN="${_AGENTS_DIR_NODE}/bin/worktree-notes-triage.js"
FINAL_REPORT_BIN="${_AGENTS_DIR_NODE}/bin/worktree-final-report.js"
LIB_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes-sections.js"

FIXTURE_NOTES="${_AGENTS_DIR_NODE}/tests/fixtures/worktree-notes-sample.md"
FIXTURE_GOLDEN="${_AGENTS_DIR_NODE}/tests/fixtures/worktree-notes-sample-report.txt"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$1" "${@:2}"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$@"
    else
        "${@:2}"
    fi
}

require_bin() {
    if [ ! -f "$TRIAGE_BIN" ]; then
        skip "$1 (bin/worktree-notes-triage.js not implemented yet)"
        return 1
    fi
    return 0
}

require_final_report_lib() {
    # R1 runs against bin/worktree-final-report.js, which already exists. The
    # golden fixture matches its current output, so R1 passes pre-refactor and
    # must continue to pass post-refactor (the contract being preserved).
    if [ ! -f "$FINAL_REPORT_BIN" ]; then
        skip "$1 (bin/worktree-final-report.js missing)"
        return 1
    fi
    return 0
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'wt-promote-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'node -e "require(\"fs\").rmSync(process.argv[1], {recursive:true,force:true})" -- "$TMPDIR_BASE" 2>/dev/null' EXIT

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# Copy the sample fixture into a fresh temp dir, named WORKTREE_NOTES.md.
# Echoes the absolute (node-friendly) path.
make_notes_copy() {
    local subdir="$1"
    local dir="$TMPDIR_BASE/$subdir"
    mkdir -p "$dir"
    cp "$FIXTURE_NOTES" "$dir/WORKTREE_NOTES.md"
    node_path "$dir/WORKTREE_NOTES.md"
}

# Echo a path to a fresh empty-state notes file (all sections "- (none)").
make_empty_notes() {
    local subdir="$1"
    local dir="$TMPDIR_BASE/$subdir"
    mkdir -p "$dir"
    cat > "$dir/WORKTREE_NOTES.md" <<'EOF'
# Worktree Notes
Branch: test
Created: 2026-05-22
Path: /tmp/test
WORKTREE_BASE_DIR: (default)

## Gitignored files copied from main
- (none)

## BugsFound
- (none)

## RelatedTasks
- (none)

## NextTasks
- (none)

## History Notes
- (none)
EOF
    node_path "$dir/WORKTREE_NOTES.md"
}

# ============ Tests ============

# ---- R1 (golden): bin/worktree-final-report.js byte-for-byte match ----
test_R1_golden_report() {
    require_final_report_lib "R1: final-report golden match" || return

    local intent_dir="$TMPDIR_BASE/r1"
    mkdir -p "$intent_dir"
    printf '# Intent\nTest intent\n' > "$intent_dir/intent.md"
    local intent_node; intent_node="$(node_path "$intent_dir/intent.md")"

    local actual
    actual="$(run_with_timeout 30 node "$FINAL_REPORT_BIN" "$intent_node" "$FIXTURE_NOTES" "test-session-123" 2>/dev/null)"

    local expected
    expected="$(cat "$FIXTURE_GOLDEN")"

    if [ "$actual" = "$expected" ]; then
        pass "R1: final-report output matches golden fixture byte-for-byte"
    else
        fail "R1: golden mismatch
--- expected ---
$expected
--- actual ---
$actual
---"
    fi
}

# ---- F1: triage list — entries with correct lineNumbers, hasMarker=false ----
test_F1_triage_list_basic() {
    require_bin "F1: triage list basic" || return

    local notes; notes="$(make_notes_copy "f1")"
    local out
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"

    # Expect 3 entries (BugsFound, RelatedTasks, NextTasks — 1 each), all hasMarker=false.
    local len
    len="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j.length)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"
    local any_marker
    any_marker="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            process.stdout.write(String(j.some(e => e.hasMarker === true)));
        } catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"

    if [ "$len" = "3" ] && [ "$any_marker" = "false" ]; then
        pass "F1: triage list returns 3 entries, all hasMarker=false"
    else
        fail "F1: len=$len any_marker=$any_marker (out=$out)"
    fi
}

# ---- F2: triage list on all-none sections → [] ----
test_F2_triage_list_all_none() {
    require_bin "F2: triage list all-none" || return

    local notes; notes="$(make_empty_notes "f2")"
    local out
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"

    if [ "$out" = "[]" ]; then
        pass "F2: triage list with all '- (none)' sections returns []"
    else
        fail "F2: expected '[]', got: $out"
    fi
}

# ---- F3: triage annotate writes marker; entry removed from list (promoted → filtered) ----
test_F3_triage_annotate_then_list() {
    require_bin "F3: triage annotate → list" || return

    local notes; notes="$(make_notes_copy "f3")"

    # First, get the lineNumber of the BugsFound entry.
    local list_before
    list_before="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    local target_line
    target_line="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            // Pick the first entry — annotate it.
            process.stdout.write(String(j[0].lineNumber));
        } catch (e) { process.stdout.write('ERR'); }
    " -- "$list_before" 2>/dev/null)"

    if [ "$target_line" = "ERR" ] || [ -z "$target_line" ]; then
        fail "F3: could not read first entry lineNumber (list=$list_before)"
        return
    fi

    # Annotate.
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$target_line" 789 >/dev/null 2>&1
    local code=$?
    if [ "$code" != "0" ]; then
        fail "F3: triage annotate failed (exit $code)"
        return
    fi

    # Verify the marker landed in the file.
    if ! grep -q "<!-- promoted: #789 -->" "$notes" 2>/dev/null; then
        fail "F3: marker '<!-- promoted: #789 -->' not present in $notes after annotate"
        return
    fi

    # Re-list. list returns only unpromoted entries, so the annotated entry must
    # be absent (filtered as a promoted entry — hasMarker=true entries are triage
    # candidates no more; see triage.js cmdList filter and test A5).
    local list_after
    list_after="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    local found
    found="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            const target = parseInt(process.argv[2], 10);
            const e = j.find(x => x.lineNumber === target);
            process.stdout.write(e ? 'FOUND' : 'NOT_FOUND');
        } catch (e) { process.stdout.write('ERR'); }
    " -- "$list_after" "$target_line" 2>/dev/null)"

    if [ "$found" = "NOT_FOUND" ]; then
        pass "F3: triage annotate writes marker; promoted entry absent from list"
    else
        fail "F3: post-annotate entry still in list (got: $found list=$list_after)"
    fi
}

# ---- F4: list after annotation is shorter by 1 (promoted entry filtered out) ----
test_F4_list_excludes_marked() {
    require_bin "F4: list excludes marked entries" || return

    local notes; notes="$(make_notes_copy "f4")"

    # Annotate the first entry.
    local list_before
    list_before="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    local target_line
    target_line="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j[0].lineNumber)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$list_before" 2>/dev/null)"
    local len_before
    len_before="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j.length)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$list_before" 2>/dev/null)"

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$target_line" 42 >/dev/null 2>&1

    local list_after
    list_after="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    local len_after
    len_after="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j.length)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$list_after" 2>/dev/null)"
    # list returns only unpromoted entries; annotated entry must be gone (count drops by 1).
    local expected_after=$((len_before - 1))

    if [ "$len_after" = "$expected_after" ]; then
        pass "F4: list after annotation is shorter by 1 (promoted entry filtered)"
    else
        fail "F4: len_before=$len_before len_after=$len_after expected=$expected_after"
    fi
}

# ---- F5: triage annotate with lineNumber=0 → non-zero exit ----
test_F5_triage_annotate_invalid_line() {
    require_bin "F5: triage annotate invalid lineNumber" || return

    local notes; notes="$(make_notes_copy "f5")"
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" 0 99 >/dev/null 2>&1
    local code=$?

    if [ "$code" != "0" ]; then
        pass "F5: triage annotate lineNumber=0 → non-zero exit ($code)"
    else
        fail "F5: expected non-zero exit, got 0"
    fi
}

# ---- F6 (security): path traversal → non-zero exit ----
test_F6_path_traversal_rejected() {
    require_bin "F6: path traversal rejected" || return

    # Path containing '..' must be rejected regardless of basename.
    local bad_path="$TMPDIR_BASE/../etc/WORKTREE_NOTES.md"

    run_with_timeout 30 node "$TRIAGE_BIN" list "$bad_path" >/dev/null 2>&1
    local code_list=$?
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$bad_path" 2 1 >/dev/null 2>&1
    local code_anno=$?

    if [ "$code_list" != "0" ] && [ "$code_anno" != "0" ]; then
        pass "F6: path traversal rejected (list=$code_list, annotate=$code_anno)"
    else
        fail "F6: expected non-zero for both, got list=$code_list annotate=$code_anno"
    fi
}

# ---- F7 (security): basename != WORKTREE_NOTES.md → non-zero exit ----
test_F7_wrong_basename_rejected() {
    require_bin "F7: wrong basename rejected" || return

    local dir="$TMPDIR_BASE/f7"
    mkdir -p "$dir"
    : > "$dir/some-other-file.md"
    local wrong; wrong="$(node_path "$dir/some-other-file.md")"

    run_with_timeout 30 node "$TRIAGE_BIN" list "$wrong" >/dev/null 2>&1
    local code_list=$?
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$wrong" 1 1 >/dev/null 2>&1
    local code_anno=$?

    if [ "$code_list" != "0" ] && [ "$code_anno" != "0" ]; then
        pass "F7: non-WORKTREE_NOTES.md basename rejected (list=$code_list, annotate=$code_anno)"
    else
        fail "F7: expected non-zero for both, got list=$code_list annotate=$code_anno"
    fi
}

# ============ Run all ============

test_R1_golden_report
test_F1_triage_list_basic
test_F2_triage_list_all_none
test_F3_triage_annotate_then_list
test_F4_list_excludes_marked
test_F5_triage_annotate_invalid_line
test_F6_path_traversal_rejected
test_F7_wrong_basename_rejected

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
