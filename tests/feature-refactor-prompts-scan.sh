#!/bin/bash
# Tests: bin/refactor-prompts/lib/filter-kinds.js, bin/refactor-prompts/scan-prompts.js
# Tags: prompts, refactor, skill, agent, bin
# Tests for /refactor-prompts — bin/refactor-prompts/scan-prompts.js
#
# scan-prompts.js reads {keywords:[{literal, source}]} from stdin (--keywords -)
# and walks the prompt corpus under AGENTS_CONFIG_DIR (rules/*.md, skills/*/SKILL.md,
# agents/*.md), emitting hot regions as JSON {version:1, scanned_files, hot_regions}.
#
# To isolate fixture content from the real corpus we point AGENTS_CONFIG_DIR
# at a temp directory shaped like the agents repo and place fixture files
# into temp_root/rules/ etc.
#
# RED: this suite fails clean while bin/refactor-prompts/scan-prompts.js is
# missing (precondition gate). Once the CLI lands, all 9 cases must pass.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_CLI="$AGENTS_DIR/bin/refactor-prompts/scan-prompts.js"
FILTER_LIB="$AGENTS_DIR/bin/refactor-prompts/lib/filter-kinds.js"
FIX_DIR="$AGENTS_DIR/tests/fixtures/refactor-prompts"

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

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$SCAN_CLI" ]   || missing+=("bin/refactor-prompts/scan-prompts.js")
[ -f "$FILTER_LIB" ] || missing+=("bin/refactor-prompts/lib/filter-kinds.js")
[ -d "$FIX_DIR" ]    || missing+=("tests/fixtures/refactor-prompts/")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# --- Helpers ----------------------------------------------------------------
setup_temp_root() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/rules" "$tmpdir/skills" "$tmpdir/agents" "$tmpdir/tests"
    # Normalize to forward slashes for cross-tool consistency on Windows.
    echo "${tmpdir//\\//}"
}

# Build a keywords JSON document from a list of "literal|source" pairs.
make_keywords_json() {
    node -e '
        const pairs = process.argv.slice(1);
        const doc = {
            version: 1,
            sources: ["bash-write-patterns.js", "settings.json"],
            keywords: pairs.map((p) => {
                const idx = p.indexOf("|");
                return { literal: p.slice(0, idx), source: p.slice(idx + 1) };
            }),
        };
        process.stdout.write(JSON.stringify(doc));
    ' "$@"
}

run_scan() {
    # Args: <temp_root> <keywords_json> [extra scan-prompts.js args ...]
    local root="$1"; shift
    local kws_json="$1"; shift
    AGENTS_CONFIG_DIR="$root" run_with_timeout node "$SCAN_CLI" --keywords - "$@" \
        <<<"$kws_json"
}

# ============================================================================
# TC1: empty fixture dir → exit 0 + valid JSON + hot_regions empty
# ============================================================================
ROOT1="$(setup_temp_root)"
KW_RM='[{"literal":"rm -rf","source":"settings.json"}]'
KW_RM_JSON="$(make_keywords_json "rm -rf|settings.json")"

TC1_OUT="$(mktemp -t scan-tc1.XXXXXX.json)"
TC1_ERR="$(mktemp -t scan-tc1.XXXXXX.log)"
run_scan "$ROOT1" "$KW_RM_JSON" >"$TC1_OUT" 2>"$TC1_ERR"
TC1_RC=$?
TC1_HOTLEN=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    console.log(Array.isArray(d.hot_regions) ? d.hot_regions.length : 'NA');
" "$TC1_OUT" 2>/dev/null || echo "NA")

if [ "$TC1_RC" -eq 0 ] && [ "$TC1_HOTLEN" = "0" ]; then
    pass "TC1: empty corpus → exit 0 + hot_regions empty"
else
    fail "TC1: rc=$TC1_RC hot_regions=$TC1_HOTLEN stderr=$(cat "$TC1_ERR")"
fi
rm -f "$TC1_OUT" "$TC1_ERR"
rm -rf "$ROOT1"

# ============================================================================
# TC2: redundant-rule.md → hot region with matched_keyword containing "rm"
# ============================================================================
ROOT2="$(setup_temp_root)"
cp "$FIX_DIR/redundant-rule.md" "$ROOT2/rules/redundant-rule.md"

TC2_OUT="$(mktemp -t scan-tc2.XXXXXX.json)"
run_scan "$ROOT2" "$KW_RM_JSON" >"$TC2_OUT" 2>/dev/null
TC2_RC=$?
TC2_HAS=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    const hits = (d.hot_regions || []).filter(h => /rm/.test(h.matched_keyword || ''));
    process.exit(hits.length > 0 ? 0 : 1);
" "$TC2_OUT" 2>/dev/null && echo yes || echo no)

if [ "$TC2_RC" -eq 0 ] && [ "$TC2_HAS" = "yes" ]; then
    pass "TC2: rm -rf in redundant-rule.md produces a hot region"
else
    fail "TC2: rc=$TC2_RC has-rm=$TC2_HAS"
fi
rm -f "$TC2_OUT"
rm -rf "$ROOT2"

# ============================================================================
# TC3: context window length ≤ 2*context_lines + 1 (with --context-lines 2)
# ============================================================================
ROOT3="$(setup_temp_root)"
cp "$FIX_DIR/redundant-rule.md" "$ROOT3/rules/redundant-rule.md"

TC3_OUT="$(mktemp -t scan-tc3.XXXXXX.json)"
run_scan "$ROOT3" "$KW_RM_JSON" --context-lines 2 >"$TC3_OUT" 2>/dev/null
TC3_RC=$?
TC3_OK=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    const hits = (d.hot_regions || []);
    if (!hits.length) { process.exit(1); }
    const bad = hits.find(h => !Array.isArray(h.context) || h.context.length > 5);
    process.exit(bad ? 1 : 0);
" "$TC3_OUT" 2>/dev/null && echo yes || echo no)

if [ "$TC3_RC" -eq 0 ] && [ "$TC3_OK" = "yes" ]; then
    pass "TC3: --context-lines 2 yields context array of length ≤ 5"
else
    fail "TC3: rc=$TC3_RC ok=$TC3_OK"
fi
rm -f "$TC3_OUT"
rm -rf "$ROOT3"

# ============================================================================
# TC4: line number is 1-based and matches keyword position in fixture file.
# redundant-rule.md (relevant lines):
#   1  # Risky Operations
#   2  (blank)
#   3  When running risky operations:
#   4  - `rm -rf` (POSIX)
#   5  - `Remove-Item -Recurse -Force` (PowerShell)
# Expected: a hot region for "rm -rf" must report line 4.
# ============================================================================
ROOT4="$(setup_temp_root)"
cp "$FIX_DIR/redundant-rule.md" "$ROOT4/rules/redundant-rule.md"

TC4_OUT="$(mktemp -t scan-tc4.XXXXXX.json)"
run_scan "$ROOT4" "$KW_RM_JSON" >"$TC4_OUT" 2>/dev/null
TC4_RC=$?
TC4_OK=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    const hit = (d.hot_regions || []).find(h => /rm/.test(h.matched_keyword || ''));
    if (!hit) { process.exit(1); }
    process.exit(hit.line === 4 ? 0 : 1);
" "$TC4_OUT" 2>/dev/null && echo yes || echo no)

if [ "$TC4_RC" -eq 0 ] && [ "$TC4_OK" = "yes" ]; then
    pass "TC4: rm -rf reported at line 4 (1-based)"
else
    fail "TC4: rc=$TC4_RC ok=$TC4_OK"
fi
rm -f "$TC4_OUT"
rm -rf "$ROOT4"

# ============================================================================
# TC5: process-trigger.md — scanner does NOT filter by semantic meaning,
# so the WORKFLOW_USER_VERIFIED region is left to the judge phase. The
# scanner only filters keywords that begin with "<<WORKFLOW_" via extract.
# Probe keyword: "Set-Content" (unrelated) → no hot region for trigger file.
# Probe with a literal that DOES appear (the word "sentinel") → hot region IS emitted.
# ============================================================================
ROOT5="$(setup_temp_root)"
cp "$FIX_DIR/process-trigger.md" "$ROOT5/rules/process-trigger.md"

KW_SENT_JSON="$(make_keywords_json "sentinel|bash-write-patterns.js")"
TC5_OUT="$(mktemp -t scan-tc5.XXXXXX.json)"
run_scan "$ROOT5" "$KW_SENT_JSON" >"$TC5_OUT" 2>/dev/null
TC5_RC=$?
TC5_HAS=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    process.exit((d.hot_regions || []).length > 0 ? 0 : 1);
" "$TC5_OUT" 2>/dev/null && echo yes || echo no)

if [ "$TC5_RC" -eq 0 ] && [ "$TC5_HAS" = "yes" ]; then
    pass "TC5: scanner emits hot region inside process-trigger.md (no semantic filter)"
else
    fail "TC5: rc=$TC5_RC has=$TC5_HAS"
fi
rm -f "$TC5_OUT"
rm -rf "$ROOT5"

# ============================================================================
# TC6: multi-word keyword matches with both single and double internal spaces.
# Fixture content has "git commit  --amend" (DOUBLE space) — keyword
# "git commit --amend" with single space must still match.
# ============================================================================
ROOT6="$(setup_temp_root)"
cat > "$ROOT6/rules/double-space.md" <<'EOF'
# Git rules

Avoid `git commit  --amend` to rewrite history.
EOF

KW_AMEND_JSON="$(make_keywords_json "git commit --amend|bash-write-patterns.js")"
TC6_OUT="$(mktemp -t scan-tc6.XXXXXX.json)"
run_scan "$ROOT6" "$KW_AMEND_JSON" >"$TC6_OUT" 2>/dev/null
TC6_RC=$?
TC6_HAS=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    process.exit((d.hot_regions || []).length > 0 ? 0 : 1);
" "$TC6_OUT" 2>/dev/null && echo yes || echo no)

if [ "$TC6_RC" -eq 0 ] && [ "$TC6_HAS" = "yes" ]; then
    pass "TC6: 'git commit --amend' matches even with double spaces in source"
else
    fail "TC6: rc=$TC6_RC has=$TC6_HAS"
fi
rm -f "$TC6_OUT"
rm -rf "$ROOT6"

# ============================================================================
# TC7: word boundary — fixture contains "Remove-ItemProperty" but NOT
# "Remove-Item" alone. Keyword "Remove-Item" must NOT match
# "Remove-ItemProperty" (word boundary).
# ============================================================================
ROOT7="$(setup_temp_root)"
cat > "$ROOT7/rules/word-boundary.md" <<'EOF'
# Cmdlet rule

Use `Remove-ItemProperty` carefully when scripting.
EOF

KW_REMOVE_JSON="$(make_keywords_json "Remove-Item|bash-write-patterns.js")"
TC7_OUT="$(mktemp -t scan-tc7.XXXXXX.json)"
run_scan "$ROOT7" "$KW_REMOVE_JSON" >"$TC7_OUT" 2>/dev/null
TC7_RC=$?
TC7_LEN=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    console.log((d.hot_regions || []).length);
" "$TC7_OUT" 2>/dev/null || echo NA)

if [ "$TC7_RC" -eq 0 ] && [ "$TC7_LEN" = "0" ]; then
    pass "TC7: Remove-Item does NOT match Remove-ItemProperty (word boundary)"
else
    fail "TC7: rc=$TC7_RC hot_regions=$TC7_LEN"
fi
rm -f "$TC7_OUT"
rm -rf "$ROOT7"

# ============================================================================
# TC8: code fence content is scanned (matches inside ```bash blocks).
# ============================================================================
ROOT8="$(setup_temp_root)"
cat > "$ROOT8/rules/fenced.md" <<'EOF'
# Fenced code example

```bash
rm -rf /tmp
```
EOF

TC8_OUT="$(mktemp -t scan-tc8.XXXXXX.json)"
run_scan "$ROOT8" "$KW_RM_JSON" >"$TC8_OUT" 2>/dev/null
TC8_RC=$?
TC8_HAS=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    process.exit((d.hot_regions || []).length > 0 ? 0 : 1);
" "$TC8_OUT" 2>/dev/null && echo yes || echo no)

if [ "$TC8_RC" -eq 0 ] && [ "$TC8_HAS" = "yes" ]; then
    pass "TC8: hot region emitted for matches inside fenced code blocks"
else
    fail "TC8: rc=$TC8_RC has=$TC8_HAS"
fi
rm -f "$TC8_OUT"
rm -rf "$ROOT8"

# ============================================================================
# TC9: tests/ directory is excluded from scan scope.
# ============================================================================
ROOT9="$(setup_temp_root)"
cp "$FIX_DIR/redundant-rule.md" "$ROOT9/tests/test-file.md"

TC9_OUT="$(mktemp -t scan-tc9.XXXXXX.json)"
run_scan "$ROOT9" "$KW_RM_JSON" >"$TC9_OUT" 2>/dev/null
TC9_RC=$?
TC9_LEN=$(node -e "
    const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    console.log((d.hot_regions || []).length);
" "$TC9_OUT" 2>/dev/null || echo NA)

if [ "$TC9_RC" -eq 0 ] && [ "$TC9_LEN" = "0" ]; then
    pass "TC9: files under tests/ are excluded from the scan corpus"
else
    fail "TC9: rc=$TC9_RC hot_regions=$TC9_LEN"
fi
rm -f "$TC9_OUT"
rm -rf "$ROOT9"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
