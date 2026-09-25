#!/bin/bash
# tests/feature-issue-528-lang-enforce/lang-config-routing-cases.sh
# Tests: hooks/lib/lang-config.js
# Tags: worktree, docs, lang-config, routing, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh after
# settings-and-detect-cjk-cases.sh — it reads LANG_CONFIG_LIB from there.

# ============================================================================
# Group 8 — loadLangConfig independent .env key routing
# ============================================================================

echo ""
echo "=== Group 8: loadLangConfig — independent .env key routing ==="

if [ "$(src_present "$LANG_CONFIG_LIB")" != "ok" ]; then
    echo "SKIP G8: hooks/lib/lang-config.js not yet implemented (RED phase)"
else
    # T28: PLAN_LANG from .env
    _t28_tmp=$(mktemp -d); TEST_TMPS+=("$_t28_tmp")
    printf 'PLAN_LANG=english\n' > "$_t28_tmp/.env"
    _t28_dir="$(cygpath -m "$_t28_tmp" 2>/dev/null || echo "$_t28_tmp")"
    _t28_result="$(env -u PLAN_LANG AGENTS_CONFIG_DIR="$_t28_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('plan');
      if (v !== 'english') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T28: PLAN_LANG=english from .env"
    else
        fail "T28: $_t28_result"
    fi

    # T30a REMOVED (#619): fenced-block fallback no longer exists.
    # loadLangConfig('history', ...) now reads ONLY from .env via loadDocsLangConfig().

    # T30b: .env DOCS_LANG_PUBLIC drives the public surface (post-#619 .env-only)
    # Setup hoisted from old T30a body (now self-contained).
    _t30b_tmp=$(mktemp -d); TEST_TMPS+=("$_t30b_tmp")
    _t30b_dir="$(cygpath -m "$_t30b_tmp" 2>/dev/null || echo "$_t30b_tmp")"
    printf 'DOCS_LANG_PUBLIC=english\n' > "$_t30b_tmp/.env"
    _t30b_result="$(env -u DOCS_LANG_PUBLIC -u DOCS_LANG_PRIVATE -u DOCS_LANG_HISTORY_PUBLIC -u DOCS_LANG_HISTORY_PRIVATE -u DOCS_LANG_CHANGELOG_PUBLIC -u DOCS_LANG_CHANGELOG_PRIVATE AGENTS_CONFIG_DIR="$_t30b_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('history', { isPrivateRepo: false });
      if (v !== 'english') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T30b: DOCS_LANG_PUBLIC=english in .env → history surface returns 'english'"
    else
        fail "T30b: $_t30b_result"
    fi
fi
