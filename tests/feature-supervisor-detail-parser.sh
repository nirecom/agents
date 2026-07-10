#!/usr/bin/env bash
# tests/feature-supervisor-detail-parser.sh
# Tests: hooks/workflow-gate.js
# Tags: supervisor, em-supervisor, detail-parser, scope-drift, table-driven, scope:issue-specific, pwsh-not-required
# L3 gap (what this test does NOT catch):
# - parseDetailFilesToModify running inside a live Claude Code session with real plans-dir
# - Real WORKFLOW_PLANS_DIR layout from an actual worktree-start session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# T9: TABLE-DRIVEN test of parseDetailFilesToModify (new helper in workflow-gate.js)
# and the scope-drift matching rule. Cases:
#   (1) exact match p===d → declared
#   (2) directory-prefix match (d="hooks/lib/", p="hooks/lib/x.js") → declared
#   (3) (新規)/(NEW) annotation stripped → path extracted correctly
#   (4) NEGATIVE: d="hooks/workflow-gate.js", p="hooks/workflow-gate.js.bak" → NOT declared

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/workflow-gate.js"

PASS=0; FAIL=0; SKIP=0

# Table-driven: assert_eq injects case name into every assertion message
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr9'; }

if [ ! -f "$HOOK" ]; then
    fail "T9: workflow-gate.js not present (RED-EXPECTED — Change 2 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Check if parseDetailFilesToModify is exported or accessible
HAS_PARSER=$(run_with_timeout 10 node -e "
try {
    const wg = require('$_AGENTS_DIR_NODE/hooks/workflow-gate.js');
    process.stdout.write(typeof wg.parseDetailFilesToModify === 'function' ? 'exported' : 'not-exported');
} catch(e) {
    // workflow-gate is a main-module script; try to see if the function is at least
    // referenced in the source to detect RED state
    process.stdout.write('main-module');
}
" 2>/dev/null)

if [ "$HAS_PARSER" = "not-exported" ]; then
    fail "T9: parseDetailFilesToModify not exported from workflow-gate.js (RED-EXPECTED — Change 2 not yet applied)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

if [ "$HAS_PARSER" = "main-module" ]; then
    # workflow-gate.js is require.main-guarded; we invoke it via a wrapper
    # that sources the helper via a node -e splice of the detail.md content
    echo "INFO: workflow-gate.js is main-module only; testing parseDetailFilesToModify via node -e splice"
fi

# --- Fixture detail.md ---
write_fixture_detail() {
    local path="$1"
    cat > "$path" <<'DETAIL_FIXTURE'
# Implementation Detail Plan — T9 fixture

## Files to modify

- `hooks/workflow-gate.js` — main gate
- `hooks/lib/supervisor-state-writer.js` — writer
- `hooks/lib/` — directory prefix example
- `hooks/supervisor-off-proposal-shim.js`（新規）— new shim
- `hooks/new-helper.js` (NEW) — another new file

## Steps

Step 1: implement.
DETAIL_FIXTURE
}

# Parse helper: invoke parseDetailFilesToModify against a fixture detail.md
# Returns JSON array of declared paths
invoke_parser() {
    local tmp_node="$1" wsid="$2"
    run_with_timeout 10 node -e "
const wg = require('$_AGENTS_DIR_NODE/hooks/workflow-gate.js');
if (typeof wg.parseDetailFilesToModify !== 'function') {
    process.stdout.write('NOT_EXPORTED');
    process.exit(0);
}
const result = wg.parseDetailFilesToModify('$tmp_node', '$wsid');
process.stdout.write(JSON.stringify(result || []));
" 2>/dev/null
}

# Scope-drift matching: test a single file path against declared list
# Returns "declared" or "drift"
test_declared() {
    local tmp_node="$1" wsid="$2" test_path="$3"
    run_with_timeout 10 node -e "
const wg = require('$_AGENTS_DIR_NODE/hooks/workflow-gate.js');
if (typeof wg.parseDetailFilesToModify !== 'function') {
    process.stdout.write('NOT_EXPORTED');
    process.exit(0);
}
const declared = wg.parseDetailFilesToModify('$tmp_node', '$wsid') || [];
const p = '$test_path';
const isDeclared = declared.some(d => {
    if (p === d) return true;
    const dir = d.endsWith('/') ? d : d + '/';
    return p.startsWith(dir);
});
process.stdout.write(isDeclared ? 'declared' : 'drift');
" 2>/dev/null
}

# --- Run table-driven cases ---
run_t9_table() {
    local tmp wsid fixture_path
    tmp=$(make_tmp)
    wsid="t9-wsid-$$"
    fixture_path="$tmp/${wsid}-detail.md"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    write_fixture_detail "$fixture_path"

    # First check if parseDetailFilesToModify is exported
    local parsed
    parsed=$(invoke_parser "$tmp_node" "$wsid")

    if [ "$parsed" = "NOT_EXPORTED" ]; then
        fail "T9-table: parseDetailFilesToModify not yet exported from workflow-gate.js (RED-EXPECTED — Change 2 not yet applied)"
        rm -rf "$tmp"
        return
    fi

    # Verify fixture parsing extracted the correct paths
    local path_count
    path_count=$(echo "$parsed" | node -e "
const arr = JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(String(arr.length));
" 2>/dev/null)

    # Expect exactly 5 entries (4 file paths + 1 directory)
    assert_eq "T9-fixture-count" "5" "$path_count"

    # Test each case from the table
    while IFS='|' read -r name test_path want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        test_path="${test_path//[[:space:]]/}"
        local got
        got=$(test_declared "$tmp_node" "$wsid" "$test_path")
        assert_eq "$name" "$want" "$got"
    done <<'TABLE'
# case-name                    | test path                                     | expected
T9-exact-match                 | hooks/workflow-gate.js                        | declared
T9-exact-writer                | hooks/lib/supervisor-state-writer.js          | declared
T9-dir-prefix                  | hooks/lib/new-module.js                       | declared
T9-new-annotation-jp           | hooks/supervisor-off-proposal-shim.js         | declared
T9-new-annotation-en           | hooks/new-helper.js                           | declared
T9-negative-bak-suffix         | hooks/workflow-gate.js.bak                    | drift
T9-negative-unrelated          | bin/supervisor-review-codex                   | drift
T9-negative-partial-substring  | hooks/workflow-gate.js.backup                 | drift
TABLE

    rm -rf "$tmp"
}

# --- T9-annotation: verify annotation stripping ---
# (新規) and (NEW) annotations must not appear in parsed paths
run_t9_annotations() {
    local tmp wsid fixture_path
    tmp=$(make_tmp)
    wsid="t9ann-wsid-$$"
    fixture_path="$tmp/${wsid}-detail.md"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    write_fixture_detail "$fixture_path"

    local parsed
    parsed=$(invoke_parser "$tmp_node" "$wsid")

    if [ "$parsed" = "NOT_EXPORTED" ]; then
        skip "T9-annotations: parseDetailFilesToModify not exported (RED-EXPECTED)"
        rm -rf "$tmp"
        return
    fi

    # Paths must NOT contain annotation text
    local has_annotation
    has_annotation=$(echo "$parsed" | node -e "
const arr = JSON.parse(require('fs').readFileSync(0,'utf8'));
const bad = arr.filter(p => p.includes('新規') || p.includes('NEW') || p.includes('('));
process.stdout.write(bad.length > 0 ? 'has-annotation' : 'clean');
" 2>/dev/null)

    assert_eq "T9-no-annotation-in-paths" "clean" "$has_annotation"
    rm -rf "$tmp"
}

run_t9_table
run_t9_annotations

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
