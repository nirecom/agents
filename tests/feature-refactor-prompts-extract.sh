#!/bin/bash
# Tests: bin/refactor-prompts/extract-keywords.js, bin/refactor-prompts/lib/filter-kinds.js, hooks/enforce-system-ops.js, hooks/lib/bash-write-patterns.js
# Tags: refactor-prompts-extract
# Tests for /refactor-prompts — bin/refactor-prompts/extract-keywords.js
#
# extract-keywords.js reads hooks/lib/bash-write-patterns.js and settings.json,
# applies kind/sentinel/PATH_GUARD_TOOLS filters, and emits a JSON document
# {version:1, sources:[...], keywords:[{literal, source}]}.
#
# RED: this suite fails clean while bin/refactor-prompts/extract-keywords.js
# is missing (precondition gate). Once the CLI lands, all 10 cases must pass.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT_CLI="$AGENTS_DIR/bin/refactor-prompts/extract-keywords.js"
FILTER_LIB="$AGENTS_DIR/bin/refactor-prompts/lib/filter-kinds.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# Use forward slashes so node on Windows + bash both accept the path.
export AGENTS_CONFIG_DIR="C:/git/agents"

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$EXTRACT_CLI" ] || missing+=("bin/refactor-prompts/extract-keywords.js")
[ -f "$FILTER_LIB" ]  || missing+=("bin/refactor-prompts/lib/filter-kinds.js")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# --- Rename/restore trap for TC9, TC10 --------------------------------------
BACKUP_FILE=""
cleanup_backup() {
    if [ -n "$BACKUP_FILE" ] && [ -f "${BACKUP_FILE}.bak" ]; then
        mv "${BACKUP_FILE}.bak" "$BACKUP_FILE"
    fi
    BACKUP_FILE=""
}
trap cleanup_backup EXIT

# --- Run CLI once and cache for TC1–TC8 -------------------------------------
TMP_OUT="$(mktemp -t extract-out.XXXXXX.json)"
TMP_ERR="$(mktemp -t extract-err.XXXXXX.log)"
run_with_timeout node "$EXTRACT_CLI" >"$TMP_OUT" 2>"$TMP_ERR"
RC=$?

# TC1: exit 0 + valid JSON
if [ "$RC" -eq 0 ] && node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$TMP_OUT" >/dev/null 2>&1; then
    pass "TC1: extract-keywords.js exits 0 and emits valid JSON"
else
    fail "TC1: expected exit 0 + valid JSON (rc=$RC stderr=$(cat "$TMP_ERR"))"
fi

# Helper: check whether the keywords array contains a literal matching a JS predicate.
has_literal_matching() {
    local predicate="$1"
    node -e "
        const fs = require('fs');
        const doc = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        const kws = (doc.keywords || []).map(k => k.literal);
        const pred = $predicate;
        process.exit(kws.some(pred) ? 0 : 1);
    " "$TMP_OUT" 2>/dev/null
}

# TC2: keywords contains an entry containing "Remove-Item"
if has_literal_matching '(s) => typeof s === "string" && s.includes("Remove-Item")'; then
    pass "TC2: keywords contains a Remove-Item literal"
else
    fail "TC2: keywords did not contain any literal with Remove-Item"
fi

# TC3: keywords contains an entry exactly equal to "rm -rf" (from settings.json deny)
if has_literal_matching '(s) => s === "rm -rf"'; then
    pass "TC3: keywords contains \"rm -rf\" from settings.json"
else
    fail "TC3: keywords did not contain literal \"rm -rf\""
fi

# TC4: keywords does NOT contain ">>" (posix-redirect excluded)
if has_literal_matching '(s) => s === ">>" || s === ">"'; then
    fail "TC4: posix-redirect literals (> / >>) leaked into keywords"
else
    pass "TC4: posix-redirect literals excluded"
fi

# TC5: keywords does NOT contain here-doc anchors
if has_literal_matching '(s) => s === "<<EOF" || s === "<< EOF" || (typeof s === "string" && s.startsWith("<<") && !s.startsWith("<<WORKFLOW_"))'; then
    fail "TC5: here-doc literals leaked into keywords"
else
    pass "TC5: here-doc literals excluded"
fi

# TC6: keywords does NOT contain "bash -c" (interpreter excluded)
if has_literal_matching '(s) => s === "bash -c" || s === "bash" || s === "sh -c"'; then
    fail "TC6: interpreter literals leaked into keywords"
else
    pass "TC6: interpreter literals excluded"
fi

# TC7: no literal starts with "<<WORKFLOW_" (sentinel filtered)
if has_literal_matching '(s) => typeof s === "string" && s.startsWith("<<WORKFLOW_")'; then
    fail "TC7: <<WORKFLOW_* sentinel leaked into keywords"
else
    pass "TC7: <<WORKFLOW_* sentinels filtered out"
fi

# TC8: PATH_GUARD_TOOLS literals are not present
if has_literal_matching '(s) => s === "Read" || s === "Edit" || s === "Write" || s === "Grep"'; then
    fail "TC8: PATH_GUARD_TOOLS literals leaked into keywords"
else
    pass "TC8: Read/Edit/Write/Grep skipped via PATH_GUARD_TOOLS"
fi

rm -f "$TMP_OUT" "$TMP_ERR"

# ============================================================================
# TC9: enforce-system-ops.js fail-soft
#   Rename hooks/enforce-system-ops.js, run extract-keywords.js, assert exit 0
#   AND stderr mentions warn/WARN. Restore the file.
# ============================================================================
HOOK_OPTIONAL="$AGENTS_CONFIG_DIR/hooks/enforce-system-ops.js"
if [ -f "$HOOK_OPTIONAL" ]; then
    BACKUP_FILE="$HOOK_OPTIONAL"
    mv "$HOOK_OPTIONAL" "${HOOK_OPTIONAL}.bak"
    TC9_OUT="$(mktemp -t extract-tc9-out.XXXXXX.json)"
    TC9_ERR="$(mktemp -t extract-tc9-err.XXXXXX.log)"
    run_with_timeout node "$EXTRACT_CLI" >"$TC9_OUT" 2>"$TC9_ERR"
    TC9_RC=$?
    mv "${HOOK_OPTIONAL}.bak" "$HOOK_OPTIONAL"
    BACKUP_FILE=""

    if [ "$TC9_RC" -eq 0 ] && grep -qiE 'warn' "$TC9_ERR"; then
        pass "TC9: missing enforce-system-ops.js is fail-soft (exit 0 + warn)"
    else
        fail "TC9: expected exit 0 + warn on stderr (rc=$TC9_RC stderr=$(cat "$TC9_ERR"))"
    fi
    rm -f "$TC9_OUT" "$TC9_ERR"
else
    fail "TC9: precondition missing — hooks/enforce-system-ops.js not found"
fi

# ============================================================================
# TC10: bash-write-patterns.js missing is a hard error
# ============================================================================
PATTERNS_REQUIRED="$AGENTS_CONFIG_DIR/hooks/lib/bash-write-patterns.js"
if [ -f "$PATTERNS_REQUIRED" ]; then
    BACKUP_FILE="$PATTERNS_REQUIRED"
    mv "$PATTERNS_REQUIRED" "${PATTERNS_REQUIRED}.bak"
    TC10_OUT="$(mktemp -t extract-tc10-out.XXXXXX.json)"
    TC10_ERR="$(mktemp -t extract-tc10-err.XXXXXX.log)"
    run_with_timeout node "$EXTRACT_CLI" >"$TC10_OUT" 2>"$TC10_ERR"
    TC10_RC=$?
    mv "${PATTERNS_REQUIRED}.bak" "$PATTERNS_REQUIRED"
    BACKUP_FILE=""

    if [ "$TC10_RC" -eq 1 ]; then
        pass "TC10: missing bash-write-patterns.js exits 1"
    else
        fail "TC10: expected exit 1, got rc=$TC10_RC stderr=$(cat "$TC10_ERR")"
    fi
    rm -f "$TC10_OUT" "$TC10_ERR"
else
    fail "TC10: precondition missing — hooks/lib/bash-write-patterns.js not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
