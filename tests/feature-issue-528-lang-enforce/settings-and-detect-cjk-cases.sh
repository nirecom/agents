#!/bin/bash
# tests/feature-issue-528-lang-enforce/settings-and-detect-cjk-cases.sh
# Tests: settings.json, hooks/lib/detect-cjk.js, hooks/lib/lang-config.js
# Tags: worktree, docs, static-check, detect-cjk, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.
# Also defines LANG_CONFIG_LIB, which the later case files rely on, so it must be
# sourced before them.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

# ============================================================================
# Group 5 — settings.json static check
# ============================================================================

echo ""
echo "=== Group 5: settings.json static check ==="

# T24: settings.json contains "check-worktree-notes-lang.js" as registered hook
if [ -f "$SETTINGS_JSON" ] && grep -q "check-worktree-notes-lang.js" "$SETTINGS_JSON"; then
    pass "T24: settings.json registers check-worktree-notes-lang.js"
else
    fail "T24: settings.json does NOT register check-worktree-notes-lang.js"
fi

# T24r1: settings.json does NOT register check-ask-lang.js (removed in #645)
if [ -f "$SETTINGS_JSON" ] && ! grep -q "check-ask-lang" "$SETTINGS_JSON"; then
    pass "T24r1: settings.json does not register check-ask-lang.js (removal regression)"
else
    fail "T24r1: settings.json still references check-ask-lang — removal regression"
fi

# T24r2: hooks/lib/lang-config.js does NOT contain ASK_LANG reference (removed in #645)
if ! grep -q "ASK_LANG" "$AGENTS_DIR/hooks/lib/lang-config.js"; then
    pass "T24r2: lang-config.js has no ASK_LANG reference (removal regression)"
else
    fail "T24r2: lang-config.js still references ASK_LANG — removal regression"
fi

# T24r3: hooks/check-ask-lang.js does NOT exist (removed in #645)
if [ ! -f "$AGENTS_DIR/hooks/check-ask-lang.js" ]; then
    pass "T24r3: hooks/check-ask-lang.js is absent (removal regression)"
else
    fail "T24r3: hooks/check-ask-lang.js still exists — removal regression"
fi

# T24r4/T24r5: the SHIPPED .env.example and skills/update-docs/SKILL.md must name
# the consolidated keys and none of the four retired ones. The loader keeps
# reading a retired key only to warn about it, so nothing else in this suite
# fails when a shipped file still advertises one — a user copying .env.example
# would land straight on the deprecation warning.
_g5_docs_lang_new="DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE"
_g5_docs_lang_retired="DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE"

g5_key_report() {
    local file="$1" key
    for key in $_g5_docs_lang_new $_g5_docs_lang_retired; do
        if grep -q "$key" "$file" 2>/dev/null; then echo "$key present"; else echo "$key absent"; fi
    done
}

_g5_expected_keys="DOCS_LANG_PUBLIC present
DOCS_LANG_PRIVATE present
DOCS_LANG_HISTORY_PUBLIC absent
DOCS_LANG_HISTORY_PRIVATE absent
DOCS_LANG_CHANGELOG_PUBLIC absent
DOCS_LANG_CHANGELOG_PRIVATE absent"

for _g5_file in ".env.example" "skills/update-docs/SKILL.md"; do
    _g5_path="$AGENTS_DIR/$_g5_file"
    if [ ! -f "$_g5_path" ]; then
        fail "T24r4: $_g5_file not found at $_g5_path"
        continue
    fi
    _g5_got="$(g5_key_report "$_g5_path")"
    if [ "$_g5_got" = "$_g5_expected_keys" ]; then
        pass "T24r4: $_g5_file names both consolidated DOCS_LANG keys and no retired one"
    else
        fail "T24r4: $_g5_file key inventory mismatch. expected:
$_g5_expected_keys
got:
$_g5_got"
    fi
done

# ============================================================================
# Group 6 — detect-cjk.js hasCJK SSOT
# ============================================================================

echo ""
echo "=== Group 6: detect-cjk.js — hasCJK SSOT ==="

DETECT_CJK_LIB="$AGENTS_DIR/hooks/lib/detect-cjk.js"
if [ "$(src_present "$DETECT_CJK_LIB")" != "ok" ]; then
    echo "SKIP G6: hooks/lib/detect-cjk.js not yet implemented (RED phase)"
else
    _g6_out="$(node -e "
      const { hasCJK } = require('$_AGENTS_DIR_NODE/hooks/lib/detect-cjk');
      if (!hasCJK('日本語テスト')) { process.stderr.write('T26 fail\n'); process.exit(1); }
      if (hasCJK('안녕하세요 World')) { process.stderr.write('T26b fail\n'); process.exit(1); }
      if (hasCJK('plain english')) { process.stderr.write('T26c fail\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T26/T26b/T26c: hasCJK Japanese=true, Hangul=false, ASCII=false"
    else
        fail "T26/T26b/T26c: $_g6_out"
    fi
fi

# ============================================================================
# Group 7 — REMOVED (docs-lang-config.js shim deleted in #619)
# ============================================================================
# G7 previously tested the docs-lang-config.js compatibility shim. After #619
# the shim is deleted; all callers import hooks/lib/lang-config.js directly.

LANG_CONFIG_LIB="$AGENTS_DIR/hooks/lib/lang-config.js"
