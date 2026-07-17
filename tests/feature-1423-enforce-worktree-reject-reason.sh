#!/bin/bash
# tests/feature-1423-enforce-worktree-reject-reason.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/write-detector.js
# Tags: enforce-worktree, reject-reason, write-detector, feature-1423, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Whether write-detector.js is correctly wired in enforce-worktree.js at runtime
#   (test uses the real hook but cannot verify the module resolution path in isolation)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/enforce-worktree.js"

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
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'feat1423ew'; }

# build_json_file <json_file> <command> <cwd> <sid>
# Uses node to build JSON safely — handles $(), <<<, quotes, newlines, etc.
build_json_file() {
    local json_file="$1" cmd="$2" cwd="$3" sid="$4"
    node -e "
var fs = require('fs');
var obj = {
    tool_name: 'Bash',
    tool_input: { command: process.argv[2], cwd: process.argv[3] },
    session_id: process.argv[4]
};
fs.writeFileSync(process.argv[1], JSON.stringify(obj));
" "$json_file" "$cmd" "$cwd" "$sid"
}

# run_hook <json_file> <tmpdir_node>
# Returns stdout from the hook (unaffected by WORKFLOW_PLANS_DIR path).
run_hook() {
    local json_file="$1" tmpdir_node="$2"
    WORKFLOW_PLANS_DIR="$tmpdir_node" ENFORCE_WORKTREE=on \
        run_with_timeout 15 bash -c "cat '$json_file' | node '$HOOK'" 2>/dev/null
}

# assert_blocked_with_pred <label> <hook_stdout> <pred_name>
# Passes if hook output has decision:block and reason contains (<pred_name>).
assert_blocked_with_pred() {
    local label="$1" out="$2" pred="$3"
    local result
    result=$(node -e "
try {
    var r = JSON.parse(process.argv[1]);
    if (!r.decision || r.decision !== 'block') {
        console.log('NOT_BLOCKED');
        process.exit(0);
    }
    var needle = '(' + process.argv[2] + ')';
    if (!r.reason || r.reason.indexOf(needle) === -1) {
        console.log('WRONG_PRED:' + (r.reason || '').substring(0, 120));
        process.exit(0);
    }
    console.log('OK');
} catch(e) {
    console.log('PARSE_ERR:' + process.argv[1].substring(0, 80));
}
" "$out" "$pred" 2>/dev/null)
    if [ "$result" = "OK" ]; then
        pass "$label: blocked with ($pred)"
    else
        fail "$label: expected (${pred}) in reason — got: $result"
    fi
}

# assert_allowed <label> <hook_stdout>
# Passes if hook output does NOT have decision:block.
assert_allowed() {
    local label="$1" out="$2"
    local result
    result=$(node -e "
try {
    var r = JSON.parse(process.argv[1]);
    if (r.decision && r.decision === 'block') {
        console.log('BLOCKED:' + (r.reason || '').substring(0, 120));
    } else {
        console.log('OK');
    }
} catch(e) {
    console.log('PARSE_ERR:' + process.argv[1].substring(0, 80));
}
" "$out" 2>/dev/null)
    if [ "$result" = "OK" ]; then
        pass "$label: allowed (not blocked)"
    else
        fail "$label: expected allow — got: $result"
    fi
}

# ── Preflight checks ──────────────────────────────────────────────────────────

if [ ! -f "$HOOK" ]; then
    skip "All: enforce-worktree.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree[[:space:]]+/, ""); print; exit}')"
if [ -n "$MAIN_WT" ] && command -v cygpath >/dev/null 2>&1; then
    MAIN_WT_J="$(cygpath -m "$MAIN_WT" 2>/dev/null || echo "$MAIN_WT")"
else
    MAIN_WT_J="$MAIN_WT"
fi

if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
    skip "All: cannot resolve main worktree — skipping all tests"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

SID_BASE="sid-1423-$$"

# ── T1: classify ──────────────────────────────────────────────────────────────
# cat <<< "hello"  — here-string; classify() matches WRITE_PATTERNS before any IR predicate
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t1"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'cat <<< "hello"' "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T1" "$OUT" "classify"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T2: isGitWriteIR ─────────────────────────────────────────────────────────
# cwd is a non-git temp dir so repoRoot=null; the !repoRoot block fires with (isGitWriteIR).
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t2"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'git push origin main' "$TMP_NODE" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T2" "$OUT" "isGitWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T3: isPkgMgrWriteIR ──────────────────────────────────────────────────────
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t3"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'npm install some-package' "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T3" "$OUT" "isPkgMgrWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T4: isPosixRedirWriteIR ──────────────────────────────────────────────────
# Path must be inside the main worktree — /tmp is outside session scope and would be allowed.
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t4"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" "echo x > ${MAIN_WT_J}/hooks/test-1423.txt" "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T4" "$OUT" "isPosixRedirWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T5: isFileOpWriteIR ──────────────────────────────────────────────────────
# Path must be inside the main worktree — /tmp is outside session scope and would be allowed.
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t5"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" "rm -rf ${MAIN_WT_J}/hooks/test-1423-dir" "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T5" "$OUT" "isFileOpWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T6: isPwshWriteIR ────────────────────────────────────────────────────────
# Path must be inside the main worktree — /tmp is outside session scope and would be allowed.
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t6"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" "Set-Content -Path ${MAIN_WT_J}/hooks/test-1423.txt -Value test" "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T6" "$OUT" "isPwshWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T7: isCommandSubstWriteIR ─────────────────────────────────────────────────
# Double-quoted $() so argvRaw preserves "$(git push origin main)" (bare token strips it).
# cwd is a non-git temp dir so repoRoot=null; the !repoRoot block fires with (isCommandSubstWriteIR).
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t7"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'echo "$(git push origin main)"' "$TMP_NODE" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T7" "$OUT" "isCommandSubstWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T8: isExoticExecWriteIR ──────────────────────────────────────────────────
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t8"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'eval "git push origin main"' "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T8" "$OUT" "isExoticExecWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T9: isInterpreterCWriteIR ─────────────────────────────────────────────────
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t9"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'bash -c "git push origin main"' "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T9" "$OUT" "isInterpreterCWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T10: isNewlineInjectedWriteIR ─────────────────────────────────────────────
# Command value contains a literal newline: the $'...' ANSI-C quoting in bash
# produces the literal newline character, which node receives as process.argv[2].
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t10"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" $'echo "reading only"\nrm /tmp/t10' "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T10" "$OUT" "isNewlineInjectedWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T11: isGhWriteCommand ────────────────────────────────────────────────────
# cwd is a non-git temp dir so repoRoot=null; the gh !detected block fires.
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t11"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'gh pr merge 1' "$TMP_NODE" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T11" "$OUT" "isGhWriteCommand"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T12: isEncodedCommandWriteIR ─────────────────────────────────────────────
# pwsh -enc (short for -EncodedCommand) — fail-closed PS encoded payload.
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t12"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'pwsh -enc dQBuAGkA' "$TMP_NODE" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T12" "$OUT" "isEncodedCommandWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T13: isExtendedFileOpWriteIR ─────────────────────────────────────────────
# sed -i (in-place edit) targeting a file in the main worktree.
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-t13"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" "sed -i 's/foo/bar/' ${MAIN_WT_J}/hooks/test-1423.txt" "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_blocked_with_pred "T13" "$OUT" "isExtendedFileOpWriteIR"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── T_ALLOW: symmetry (CPR-5) — read-only command must NOT be blocked ─────────
TMP=$(make_tmp)
if command -v cygpath >/dev/null 2>&1; then TMP_NODE=$(cygpath -m "$TMP"); else TMP_NODE="$TMP"; fi
SID="${SID_BASE}-tallow"
JSON_FILE=$(mktemp)
build_json_file "$JSON_FILE" 'ls /tmp' "$MAIN_WT_J" "$SID"
OUT=$(run_hook "$JSON_FILE" "$TMP_NODE")
assert_allowed "T_ALLOW" "$OUT"
rm -f "$JSON_FILE"; rm -rf "$TMP"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
