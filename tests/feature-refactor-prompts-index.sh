#!/bin/bash
# Tests: bin/refactor-prompts/index.sh, skills/refactor-prompts/SKILL.md
# Tags: prompts, refactor, dispatch, scratchpad, scope:common
#
# index.sh is the bash wrapper refactor-prompts/SKILL.md's scratchpad script actually
# invokes -- arg parsing, the AGENTS_CONFIG_DIR guard, the --keywords-only short-circuit,
# and piping extract-keywords.js's stdout into scan-prompts.js. Existing suites
# (feature-refactor-prompts-extract.sh, feature-refactor-prompts-scan.sh) call the two
# JS scripts directly via node and never exercise this wrapper at all -- this file closes
# that gap, including the scratchpad-script/file-handoff shape SKILL.md's step documents.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_SH="$AGENTS_DIR/bin/refactor-prompts/index.sh"

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

[ -f "$INDEX_SH" ] || { echo "FAIL: precondition missing — bin/refactor-prompts/index.sh"; echo ""; echo "Results: 0 passed, 1 failed"; exit 1; }

is_valid_json() { node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$1" >/dev/null 2>&1; }
doc_has_key() { node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));process.exit(Object.prototype.hasOwnProperty.call(d,process.argv[2])?0:1)" "$1" "$2" >/dev/null 2>&1; }

# --- fixture: a config root that has no hooks/lib/bash-write-patterns.js, so
# extract-keywords.js's own required-source guard fails and exits 1. ---------
BROKEN_ROOT="$(mktemp -d)"
cleanup_broken() { rm -rf "$BROKEN_ROOT"; }
trap cleanup_broken EXIT

# ============================================================================
# TC1: normal full-scan mode — exit 0, valid JSON scan doc (hot_regions, no keywords key)
# ============================================================================
TC1_OUT="$(mktemp -t index-tc1-out.XXXXXX.json)"
TC1_ERR="$(mktemp -t index-tc1-err.XXXXXX.log)"
AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout bash "$INDEX_SH" >"$TC1_OUT" 2>"$TC1_ERR"
TC1_RC=$?
if [ "$TC1_RC" -eq 0 ] && is_valid_json "$TC1_OUT" && doc_has_key "$TC1_OUT" hot_regions && ! doc_has_key "$TC1_OUT" keywords; then
    pass "TC1: index.sh full-scan mode exits 0 with a valid hot_regions scan doc"
else
    fail "TC1: rc=$TC1_RC stderr=$(cat "$TC1_ERR")"
fi
rm -f "$TC1_OUT" "$TC1_ERR"

# ============================================================================
# TC2: --keywords-only — exit 0, valid JSON keywords doc (keywords, no hot_regions key)
# ============================================================================
TC2_OUT="$(mktemp -t index-tc2-out.XXXXXX.json)"
TC2_ERR="$(mktemp -t index-tc2-err.XXXXXX.log)"
AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout bash "$INDEX_SH" --keywords-only >"$TC2_OUT" 2>"$TC2_ERR"
TC2_RC=$?
if [ "$TC2_RC" -eq 0 ] && is_valid_json "$TC2_OUT" && doc_has_key "$TC2_OUT" keywords && ! doc_has_key "$TC2_OUT" hot_regions; then
    pass "TC2: index.sh --keywords-only exits 0 and short-circuits before scan-prompts.js"
else
    fail "TC2: rc=$TC2_RC stderr=$(cat "$TC2_ERR")"
fi
rm -f "$TC2_OUT" "$TC2_ERR"

# ============================================================================
# TC3: --context-lines passthrough — flag reaches scan-prompts.js without breaking the wrapper
# ============================================================================
TC3_OUT="$(mktemp -t index-tc3-out.XXXXXX.json)"
TC3_ERR="$(mktemp -t index-tc3-err.XXXXXX.log)"
AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout bash "$INDEX_SH" --context-lines 1 >"$TC3_OUT" 2>"$TC3_ERR"
TC3_RC=$?
if [ "$TC3_RC" -eq 0 ] && is_valid_json "$TC3_OUT" && doc_has_key "$TC3_OUT" hot_regions; then
    pass "TC3: index.sh --context-lines N is accepted and passed through to the scan"
else
    fail "TC3: rc=$TC3_RC stderr=$(cat "$TC3_ERR")"
fi
rm -f "$TC3_OUT" "$TC3_ERR"

# ============================================================================
# TC4: AGENTS_CONFIG_DIR unset — exit 2, stderr names the missing var
# ============================================================================
TC4_OUT="$(mktemp -t index-tc4-out.XXXXXX.json)"
TC4_ERR="$(mktemp -t index-tc4-err.XXXXXX.log)"
(
    unset AGENTS_CONFIG_DIR
    run_with_timeout bash "$INDEX_SH" >"$TC4_OUT" 2>"$TC4_ERR"
)
TC4_RC=$?
if [ "$TC4_RC" -eq 2 ] && grep -qi "AGENTS_CONFIG_DIR" "$TC4_ERR"; then
    pass "TC4: AGENTS_CONFIG_DIR unset exits 2 with a diagnostic naming the var"
else
    fail "TC4: rc=$TC4_RC stderr=$(cat "$TC4_ERR")"
fi
rm -f "$TC4_OUT" "$TC4_ERR"

# ============================================================================
# TC5: unknown flag — exit 2
# ============================================================================
TC5_OUT="$(mktemp -t index-tc5-out.XXXXXX.json)"
TC5_ERR="$(mktemp -t index-tc5-err.XXXXXX.log)"
AGENTS_CONFIG_DIR="$AGENTS_DIR" run_with_timeout bash "$INDEX_SH" --bogus-flag >"$TC5_OUT" 2>"$TC5_ERR"
TC5_RC=$?
if [ "$TC5_RC" -eq 2 ]; then
    pass "TC5: an unrecognized flag exits 2"
else
    fail "TC5: rc=$TC5_RC stderr=$(cat "$TC5_ERR")"
fi
rm -f "$TC5_OUT" "$TC5_ERR"

# ============================================================================
# TC6: extract-keywords.js failure propagates through index.sh's `|| exit $?`
# ============================================================================
TC6_OUT="$(mktemp -t index-tc6-out.XXXXXX.json)"
TC6_ERR="$(mktemp -t index-tc6-err.XXXXXX.log)"
AGENTS_CONFIG_DIR="$BROKEN_ROOT" run_with_timeout bash "$INDEX_SH" >"$TC6_OUT" 2>"$TC6_ERR"
TC6_RC=$?
if [ "$TC6_RC" -eq 1 ] && [ ! -s "$TC6_OUT" ]; then
    pass "TC6: extract-keywords.js's exit 1 propagates through index.sh with no stdout output"
else
    fail "TC6: rc=$TC6_RC stdout-size=$(wc -c <"$TC6_OUT") stderr=$(cat "$TC6_ERR")"
fi
rm -f "$TC6_OUT" "$TC6_ERR"

# ============================================================================
# TC7 (file-handoff, normal path): the exact scratchpad-script shape SKILL.md's step
# documents -- `bash <script>` where the script runs index.sh and redirects its stdout
# to a target JSON file. Assert the handoff file lands with a valid scan doc.
# ============================================================================
HANDOFF_DIR="$(mktemp -d)"
TARGET_JSON="$HANDOFF_DIR/scan-result.json"
SCRATCHPAD_OK="$HANDOFF_DIR/scratchpad-ok.sh"
{
    echo "#!/bin/bash"
    echo "set -e"
    echo "AGENTS_CONFIG_DIR=\"$AGENTS_DIR\" bash \"$INDEX_SH\" > \"$TARGET_JSON\""
} >"$SCRATCHPAD_OK"
run_with_timeout bash "$SCRATCHPAD_OK" >/dev/null 2>&1
TC7_RC=$?
if [ "$TC7_RC" -eq 0 ] && [ -s "$TARGET_JSON" ] && is_valid_json "$TARGET_JSON" && doc_has_key "$TARGET_JSON" hot_regions; then
    pass "TC7: scratchpad-script/file-handoff pattern lands a valid scan doc at the target path"
else
    fail "TC7: rc=$TC7_RC target-exists=$([ -f "$TARGET_JSON" ] && echo yes || echo no)"
fi

# ============================================================================
# TC8 (file-handoff, error path): same scratchpad shape against the broken config
# root -- the handoff script's own exit code must propagate index.sh's failure, and
# the target file must not silently end up holding a valid-looking doc.
# ============================================================================
TARGET_JSON_ERR="$HANDOFF_DIR/scan-result-broken.json"
SCRATCHPAD_ERR="$HANDOFF_DIR/scratchpad-err.sh"
{
    echo "#!/bin/bash"
    echo "set -e"
    echo "AGENTS_CONFIG_DIR=\"$BROKEN_ROOT\" bash \"$INDEX_SH\" > \"$TARGET_JSON_ERR\""
} >"$SCRATCHPAD_ERR"
run_with_timeout bash "$SCRATCHPAD_ERR" >/dev/null 2>&1
TC8_RC=$?
if [ "$TC8_RC" -ne 0 ] && ! is_valid_json "$TARGET_JSON_ERR"; then
    pass "TC8: scratchpad-script/file-handoff pattern surfaces index.sh's failure (nonzero exit, no valid doc written)"
else
    fail "TC8: rc=$TC8_RC target-is-valid-json=$(is_valid_json "$TARGET_JSON_ERR" && echo yes || echo no)"
fi
rm -rf "$HANDOFF_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
