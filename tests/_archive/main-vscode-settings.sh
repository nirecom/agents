#!/usr/bin/env bash
# Tests: main/vscode/settings
# Tags: vscode-settings
# Tests for install/linux/vscode-settings.sh
# Source script does not exist yet — all tests are skipped until it is created.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/install/linux/vscode-settings.sh"

ERRORS=0
SKIPPED=0

pass()  { echo "PASS: $1"; }
fail()  { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
skip()  { echo "SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Guard: skip everything if source script is absent
if [ ! -f "$SCRIPT" ]; then
    skip "Normal 1: creates settings.json with all 8 keys (source absent)"
    skip "Normal 2: adds 8 keys while preserving unrelated keys (source absent)"
    skip "Normal 3: creates .bak file for existing settings.json (source absent)"
    skip "Idempotency 4: two runs produce identical output (source absent)"
    skip "Edge 5: handles empty 0-byte settings.json (source absent)"
    skip "Edge 6: overwrites existing incorrect key value (source absent)"
    skip "Error 7: exits 0 and warns when directory does not exist (source absent)"
    skip "Error 8: exits 0 and does not corrupt malformed JSON (source absent)"
    echo ""
    echo "=== Results ==="
    echo "All tests skipped (source not yet implemented)."
    exit 0
fi

# Guard: require jq
if ! command -v jq >/dev/null 2>&1; then
    skip "Normal 1: creates settings.json with all 8 keys (jq absent)"
    skip "Normal 2: adds 8 keys while preserving unrelated keys (jq absent)"
    skip "Normal 3: creates .bak file for existing settings.json (jq absent)"
    skip "Idempotency 4: two runs produce identical output (jq absent)"
    skip "Edge 5: handles empty 0-byte settings.json (jq absent)"
    skip "Edge 6: overwrites existing incorrect key value (jq absent)"
    skip "Error 7: exits 0 and warns when directory does not exist (jq absent)"
    skip "Error 8: exits 0 and does not corrupt malformed JSON (jq absent)"
    echo ""
    echo "=== Results ==="
    echo "All tests skipped (jq not available)."
    exit 0
fi

# Required keys
REQUIRED_KEYS=(
    "chat.useClaudeMdFile"
    "chat.useAgentsMdFile"
    "chat.useNestedAgentsMdFiles"
    "github.copilot.chat.codeGeneration.useInstructionFiles"
    "chat.includeApplyingInstructions"
    "chat.promptFiles"
    "chat.promptFilesLocations"
    "chat.hookFilesLocations"
)

make_test_dir() {
    mktemp -d
}

run_script() {
    local dir="$1"
    VSCODE_USER_SETTINGS_DIR="$dir" run_with_timeout bash "$SCRIPT"
}

assert_keys_present() {
    local file="$1"
    local desc="$2"
    for key in "${REQUIRED_KEYS[@]}"; do
        if ! jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1; then
            fail "$desc — missing key: $key"
            return 1
        fi
    done
    return 0
}

echo "=== vscode-settings.sh tests ==="
echo ""

# --- Normal 1: new file ---
echo "=== Normal 1: creates settings.json with all 8 keys ==="
T=$(make_test_dir)
run_script "$T" >/dev/null 2>&1 || true
SETTINGS="$T/settings.json"
if [ ! -f "$SETTINGS" ]; then
    fail "Normal 1: settings.json was not created"
else
    ALL_OK=1
    for key in "${REQUIRED_KEYS[@]}"; do
        if ! jq -e --arg k "$key" 'has($k)' "$SETTINGS" >/dev/null 2>&1; then
            fail "Normal 1: missing key '$key'"
            ALL_OK=0
        fi
    done
    [ "$ALL_OK" -eq 1 ] && pass "Normal 1: all 8 keys present in new file"
fi
rm -rf "$T"

# --- Normal 2: existing file, preserve unrelated keys ---
echo ""
echo "=== Normal 2: adds 8 keys while preserving unrelated keys ==="
T=$(make_test_dir)
SETTINGS="$T/settings.json"
printf '{"editor.fontSize":14}\n' > "$SETTINGS"
run_script "$T" >/dev/null 2>&1 || true
PRESERVED=$(jq '."editor.fontSize"' "$SETTINGS" 2>/dev/null)
if [ "$PRESERVED" = "14" ]; then
    KEYS_OK=1
    for key in "${REQUIRED_KEYS[@]}"; do
        if ! jq -e --arg k "$key" 'has($k)' "$SETTINGS" >/dev/null 2>&1; then
            fail "Normal 2: missing key '$key'"
            KEYS_OK=0
        fi
    done
    [ "$KEYS_OK" -eq 1 ] && pass "Normal 2: pre-existing key preserved and 8 keys added"
else
    fail "Normal 2: editor.fontSize was not preserved (got: $PRESERVED)"
fi
rm -rf "$T"

# --- Normal 3: .bak created ---
echo ""
echo "=== Normal 3: .bak file created for existing settings.json ==="
T=$(make_test_dir)
SETTINGS="$T/settings.json"
printf '{"editor.fontSize":14}\n' > "$SETTINGS"
run_script "$T" >/dev/null 2>&1 || true
if [ -f "${SETTINGS}.bak" ]; then
    pass "Normal 3: .bak file created"
else
    fail "Normal 3: .bak file not found"
fi
rm -rf "$T"

# --- Idempotency 4: two runs ---
echo ""
echo "=== Idempotency 4: two consecutive runs produce identical output ==="
T=$(make_test_dir)
SETTINGS="$T/settings.json"
run_script "$T" >/dev/null 2>&1 || true
run_script "$T" >/dev/null 2>&1 || true
DUPE_FOUND=0
for key in "${REQUIRED_KEYS[@]}"; do
    COUNT=$(jq --arg k "$key" '[to_entries[] | select(.key == $k)] | length' "$SETTINGS" 2>/dev/null)
    if [ "$COUNT" != "1" ]; then
        fail "Idempotency 4: key '$key' appears $COUNT times (expected 1)"
        DUPE_FOUND=1
    fi
done
[ "$DUPE_FOUND" -eq 0 ] && pass "Idempotency 4: no duplicate keys after two runs"
rm -rf "$T"

# --- Edge 5: empty file ---
echo ""
echo "=== Edge 5: handles empty 0-byte settings.json ==="
T=$(make_test_dir)
SETTINGS="$T/settings.json"
touch "$SETTINGS"
EXIT_CODE=0
run_script "$T" >/dev/null 2>&1 || EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
    fail "Edge 5: script exited with code $EXIT_CODE on empty file"
else
    KEYS_OK=1
    for key in "${REQUIRED_KEYS[@]}"; do
        if ! jq -e --arg k "$key" 'has($k)' "$SETTINGS" >/dev/null 2>&1; then
            fail "Edge 5: missing key '$key' after empty file"
            KEYS_OK=0
        fi
    done
    [ "$KEYS_OK" -eq 1 ] && pass "Edge 5: empty file handled, all 8 keys written"
fi
rm -rf "$T"

# --- Edge 6: overwrite incorrect key ---
echo ""
echo "=== Edge 6: overwrites existing incorrect key value ==="
T=$(make_test_dir)
SETTINGS="$T/settings.json"
printf '{"chat.promptFiles":false}\n' > "$SETTINGS"
run_script "$T" >/dev/null 2>&1 || true
VALUE=$(jq '."chat.promptFiles"' "$SETTINGS" 2>/dev/null)
if [ "$VALUE" = "true" ]; then
    pass "Edge 6: chat.promptFiles overwritten from false to true"
else
    fail "Edge 6: chat.promptFiles not overwritten (got: $VALUE)"
fi
rm -rf "$T"

# --- Error 7: directory does not exist ---
echo ""
echo "=== Error 7: exits 0 and warns when directory does not exist ==="
T=$(make_test_dir)
MISSING="$T/nonexistent"
EXIT_CODE=0
OUTPUT=$(VSCODE_USER_SETTINGS_DIR="$MISSING" run_with_timeout bash "$SCRIPT" 2>&1) || EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
    fail "Error 7: expected exit 0, got $EXIT_CODE"
elif echo "$OUTPUT" | grep -qi -E "(warn|warning|not found|does not exist|skip)"; then
    pass "Error 7: exit 0 and warning emitted for missing directory"
else
    fail "Error 7: exit 0 but no warning in output: $OUTPUT"
fi
rm -rf "$T"

# --- Error 8: malformed JSON ---
echo ""
echo "=== Error 8: exits 0 and does not corrupt malformed JSON ==="
T=$(make_test_dir)
SETTINGS="$T/settings.json"
BROKEN="{ broken:"
printf '%s' "$BROKEN" > "$SETTINGS"
EXIT_CODE=0
run_script "$T" >/dev/null 2>&1 || EXIT_CODE=$?
AFTER=$(cat "$SETTINGS")
if [ "$EXIT_CODE" -ne 0 ]; then
    fail "Error 8: expected exit 0, got $EXIT_CODE"
elif [ "$AFTER" = "$BROKEN" ]; then
    pass "Error 8: exit 0 and malformed file preserved unchanged"
else
    fail "Error 8: file was modified (before='$BROKEN', after='$AFTER')"
fi
rm -rf "$T"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
    echo "All tests passed."
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo "$SKIPPED test(s) skipped."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
