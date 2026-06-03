#!/bin/bash
# tests/feature-issue-528-lang-enforce.sh
# Tests: bin/compose-doc-append-entry, hooks/check-ask-lang.js, hooks/check-plan-lang.js, hooks/check-worktree-notes-lang.js, hooks/lib, hooks/lib/, hooks/lib/detect-cjk, hooks/lib/detect-cjk.js, hooks/lib/lang-config, hooks/lib/lang-config.js, hooks/lib/lint-plan-lang, hooks/lib/lint-plan-lang.js, hooks/lib/lint-worktree-notes-lang.js
# Tags: worktree, docs, append, history, compose
#
# Test suite for issue #528 — WORKTREE_NOTES.md language enforcement.
# Updated for issue #619: fenced-block parser removed; .env-only configuration.
#
# Source files under test (TDD — may not exist yet at run time):
#   - hooks/lib/lang-config.js              (.env-only loader)
#   - hooks/lib/lint-worktree-notes-lang.js (CJK linter)
#   - hooks/check-worktree-notes-lang.js    (PostToolUse hook)
#   - bin/compose-doc-append-entry          (MODIFIED to run language lint)
#
# Groups:
#   G1' (T_new_1-4) lang-config.js loadDocsLangConfig() .env-only unit tests
#   G2 (T8-T15)     lint-worktree-notes-lang.js unit tests
#   G3 (T16-T19)    check-worktree-notes-lang.js hook integration
#   G4 (T20-T23)    compose-doc-append-entry integration
#   G5 (T24, T24r1-3) settings.json static check + removal regression (#645)
#   G6 (T26)        detect-cjk.js hasCJK SSOT
#   G7              REMOVED (docs-lang-config.js shim deleted in #619)
#   G8 (T28, T30b)  loadLangConfig independent .env routing
#   G9-G12          plan lang hooks + arbitrary-language hint tier
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CONFIG_LIB="$AGENTS_DIR/hooks/lib/lang-config.js"
LINT_LIB="$AGENTS_DIR/hooks/lib/lint-worktree-notes-lang.js"
HOOK="$AGENTS_DIR/hooks/check-worktree-notes-lang.js"
CLI="$AGENTS_DIR/bin/compose-doc-append-entry"
SETTINGS_JSON="$AGENTS_DIR/settings.json"

if command -v cygpath >/dev/null 2>&1; then
    CONFIG_LIB_NODE="$(cygpath -m "$CONFIG_LIB")"
    LINT_LIB_NODE="$(cygpath -m "$LINT_LIB")"
else
    CONFIG_LIB_NODE="$CONFIG_LIB"
    LINT_LIB_NODE="$LINT_LIB"
fi

PASS=0
FAIL=0
TEST_TMPS=()

cleanup_tmps() {
    for d in "${TEST_TMPS[@]}"; do
        [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup_tmps EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Echo "ok" or "missing" for a source file (helps mark RED-phase skips).
src_present() {
    if [ -f "$1" ]; then echo "ok"; else echo "missing"; fi
}

# Write a .env file in a fresh temp AGENTS_CONFIG_DIR and load the docs-lang
# config via the zero-arg loadDocsLangConfig() (post-#619 .env-only API).
# Args: $1=.env body (as written verbatim; may be empty for default)
#       $2 (optional)="no_env" to omit creating .env at all (missing-file case)
# Prints config JSON to stdout.
load_config_json_env() {
    local env_body="$1" mode="${2:-write}"
    local _iso; _iso=$(mktemp -d); TEST_TMPS+=("$_iso")
    if [ "$mode" != "no_env" ]; then
        printf '%s' "$env_body" > "$_iso/.env"
    fi
    local _iso_node; _iso_node="$(cygpath -m "$_iso" 2>/dev/null || echo "$_iso")"
    run_with_timeout 15 env \
        -u DOCS_LANG_HISTORY_PUBLIC -u DOCS_LANG_HISTORY_PRIVATE \
        -u DOCS_LANG_CHANGELOG_PUBLIC -u DOCS_LANG_CHANGELOG_PRIVATE \
        AGENTS_CONFIG_DIR="$_iso_node" \
        node -e "
        const m = require('$CONFIG_LIB_NODE');
        const cfg = m.loadDocsLangConfig();
        process.stdout.write(JSON.stringify(cfg));
    " 2>/dev/null
}

# Run lint via node; print number of violations on stdout.
# Args: $1=content_file, $2=config_json, $3=options_json
lint_count() {
    local content_file="$1" cfg_json="$2" opts_json="$3"
    if command -v cygpath >/dev/null 2>&1; then
        content_file="$(cygpath -m "$content_file")"
    fi
    run_with_timeout 15 node -e "
        const fs = require('fs');
        const m = require('$LINT_LIB_NODE');
        const content = fs.readFileSync('$content_file', 'utf8');
        const cfg = $cfg_json;
        const opts = $opts_json;
        const v = m.lintWorktreeNotesLang(content, cfg, opts);
        process.stdout.write(String(Array.isArray(v) ? v.length : 0));
    " 2>/dev/null
}

# Run lint; print full violations JSON.
lint_json() {
    local content_file="$1" cfg_json="$2" opts_json="$3"
    if command -v cygpath >/dev/null 2>&1; then
        content_file="$(cygpath -m "$content_file")"
    fi
    run_with_timeout 15 node -e "
        const fs = require('fs');
        const m = require('$LINT_LIB_NODE');
        const content = fs.readFileSync('$content_file', 'utf8');
        const cfg = $cfg_json;
        const opts = $opts_json;
        const v = m.lintWorktreeNotesLang(content, cfg, opts);
        process.stdout.write(JSON.stringify(v));
    " 2>/dev/null
}

# Run the hook with a JSON input; print stdout.
# Args: $1=json, $2=optional AGENTS_CONFIG_DIR override
run_hook() {
    local json="$1" agents_dir="${2:-$AGENTS_CONFIG_DIR}"
    # Prevent shell DOCS_LANG_* leakage (#619 .env-only). Use a subshell with
    # unset so run_with_timeout (a bash function) remains in scope.
    (
        unset DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE
        unset DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE
        export AGENTS_CONFIG_DIR="$agents_dir"
        echo "$json" | run_with_timeout 15 node "$HOOK" 2>/dev/null
    )
}

# Write a file and return its path; ensures parent dir.
write_tmp_file() {
    local tmp; tmp=$(mktemp -d)
    TEST_TMPS+=("$tmp")
    local f="$tmp/$1"
    mkdir -p "$(dirname "$f")"
    cat > "$f"
    echo "$f"
}

# ============================================================================
# Group 1' — lang-config.js loadDocsLangConfig() .env-only loader (post-#619)
# ============================================================================
# Replaces the old fenced-block parser tests. After #619, loadDocsLangConfig()
# is zero-arg and reads ONLY from $AGENTS_CONFIG_DIR/.env via loadDefaultEnv().

echo "=== Group 1': lang-config.js loadDocsLangConfig() .env-only ==="

if [ "$(src_present "$CONFIG_LIB")" != "ok" ]; then
    echo "SKIP G1': hooks/lib/lang-config.js not yet implemented (RED phase)"
else
    # T_new_1: all four DOCS_LANG_ keys in .env → loaded correctly
    _tnew1_env=$'DOCS_LANG_HISTORY_PUBLIC=english\nDOCS_LANG_HISTORY_PRIVATE=english\nDOCS_LANG_CHANGELOG_PUBLIC=english\nDOCS_LANG_CHANGELOG_PRIVATE=any\n'
    _tnew1_json="$(load_config_json_env "$_tnew1_env")"
    if echo "$_tnew1_json" | grep -q '"historyPublic":"english"' && \
       echo "$_tnew1_json" | grep -q '"historyPrivate":"english"' && \
       echo "$_tnew1_json" | grep -q '"changelogPublic":"english"' && \
       echo "$_tnew1_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T_new_1: all four DOCS_LANG_ keys in .env → loaded correctly"
    else
        fail "T_new_1: expected all four keys from .env, got: $_tnew1_json"
    fi

    # T_new_2: partial .env (only DOCS_LANG_HISTORY_PUBLIC set) → others default to 'any'
    _tnew2_env=$'DOCS_LANG_HISTORY_PUBLIC=english\n'
    _tnew2_json="$(load_config_json_env "$_tnew2_env")"
    if echo "$_tnew2_json" | grep -q '"historyPublic":"english"' && \
       echo "$_tnew2_json" | grep -q '"historyPrivate":"any"' && \
       echo "$_tnew2_json" | grep -q '"changelogPublic":"any"' && \
       echo "$_tnew2_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T_new_2: partial .env → set key honored, others default to 'any'"
    else
        fail "T_new_2: expected partial load with defaults, got: $_tnew2_json"
    fi

    # T_new_3: missing .env → all 'any' (fail-open)
    _tnew3_json="$(load_config_json_env "" "no_env")"
    if echo "$_tnew3_json" | grep -q '"historyPublic":"any"' && \
       echo "$_tnew3_json" | grep -q '"historyPrivate":"any"' && \
       echo "$_tnew3_json" | grep -q '"changelogPublic":"any"' && \
       echo "$_tnew3_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T_new_3: missing .env → all 'any' (fail-open)"
    else
        fail "T_new_3: expected all 'any' for missing .env, got: $_tnew3_json"
    fi

    # T_new_4: .env with empty value → treated as empty/default ('any')
    _tnew4_env=$'DOCS_LANG_HISTORY_PUBLIC=\n'
    _tnew4_json="$(load_config_json_env "$_tnew4_env")"
    if echo "$_tnew4_json" | grep -q '"historyPublic":"any"'; then
        pass "T_new_4: empty value in .env → default ('any')"
    else
        fail "T_new_4: expected 'any' for empty value, got: $_tnew4_json"
    fi
fi

# ============================================================================
# Group 2 — lint-worktree-notes-lang.js unit tests
# ============================================================================

echo ""
echo "=== Group 2: lint-worktree-notes-lang.js ==="

if [ "$(src_present "$LINT_LIB")" != "ok" ]; then
    echo "SKIP G2: hooks/lib/lint-worktree-notes-lang.js not yet implemented (RED phase)"
else
    CFG_HIST_EN='{"historyPublic":"english","historyPrivate":"english","changelogPublic":"english","changelogPrivate":"any"}'
    CFG_HIST_JA='{"historyPublic":"japanese","historyPrivate":"japanese","changelogPublic":"english","changelogPrivate":"any"}'

    # T8: no CJK in History Notes (english config) → empty violations
    _t8_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- English bullet
- Another English bullet

## Changelog Notes
- (none)
EOF
)"
    _t8_count="$(lint_count "$_t8_file" "$CFG_HIST_EN" '{}')"
    if [ "$_t8_count" = "0" ]; then
        pass "T8: no CJK in History (english) → 0 violations"
    else
        fail "T8: expected 0 violations, got: $_t8_count"
    fi

    # T9: Japanese in History Notes (english config) → violation
    _t9_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- 日本語のバグ修正

## Changelog Notes
- (none)
EOF
)"
    _t9_count="$(lint_count "$_t9_file" "$CFG_HIST_EN" '{}')"
    if [ -n "$_t9_count" ] && [ "$_t9_count" -ge 1 ]; then
        pass "T9: Japanese in History (english) → violation detected"
    else
        fail "T9: expected >=1 violation, got: $_t9_count"
    fi

    # T10: Japanese in History Notes (japanese config) → no violation
    _t10_count="$(lint_count "$_t9_file" "$CFG_HIST_JA" '{}')"
    if [ "$_t10_count" = "0" ]; then
        pass "T10: Japanese in History (japanese config) → no violation"
    else
        fail "T10: expected 0 violations, got: $_t10_count"
    fi

    # T11: Japanese in Changelog Notes (changelogPublic=english) → violation
    _t11_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- (none)

## Changelog Notes
- 公開向けの変更点
EOF
)"
    # Use public-context options (caller passes which changelog config applies)
    _t11_cfg='{"historyPublic":"english","historyPrivate":"english","changelogPublic":"english","changelogPrivate":"any"}'
    _t11_count="$(lint_count "$_t11_file" "$_t11_cfg" '{"isPrivateRepo":false}')"
    if [ -n "$_t11_count" ] && [ "$_t11_count" -ge 1 ]; then
        pass "T11: Japanese in Changelog (changelogPublic=english, public) → violation"
    else
        fail "T11: expected >=1 violation, got: $_t11_count"
    fi

    # T12: ### History Notes (3-level heading) → NOT matched, no violation
    _t12_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
### History Notes
- 日本語の説明

## Changelog Notes
- (none)
EOF
)"
    _t12_count="$(lint_count "$_t12_file" "$CFG_HIST_EN" '{}')"
    if [ "$_t12_count" = "0" ]; then
        pass "T12: ### History Notes (3-level) → not matched, 0 violations"
    else
        fail "T12: expected 0 violations for 3-level heading, got: $_t12_count"
    fi

    # T13: mixed bullet `- Fix the バグ` → violation (single CJK char)
    _t13_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- Fix the バグ

## Changelog Notes
- (none)
EOF
)"
    _t13_count="$(lint_count "$_t13_file" "$CFG_HIST_EN" '{}')"
    if [ -n "$_t13_count" ] && [ "$_t13_count" -ge 1 ]; then
        pass "T13: mixed bullet w/ single CJK → violation"
    else
        fail "T13: expected >=1 violation, got: $_t13_count"
    fi

    # T15: error message trims leading "- " from bullet text
    _t15_json="$(lint_json "$_t13_file" "$CFG_HIST_EN" '{}')"
    # The violation object should contain a representation of the bullet text
    # without a leading "- ". We check that "Fix the" appears and that the
    # serialized JSON does not contain "- Fix the" prefix on the bullet field.
    if echo "$_t15_json" | grep -q "Fix the" && \
       ! echo "$_t15_json" | grep -q '"- Fix the'; then
        pass "T15: violation text trims leading '- '"
    else
        fail "T15: expected trimmed bullet, got: $_t15_json"
    fi
fi

# ============================================================================
# Group 3 — check-worktree-notes-lang.js PostToolUse hook integration
# ============================================================================

echo ""
echo "=== Group 3: check-worktree-notes-lang.js PostToolUse hook ==="

if [ "$(src_present "$HOOK")" != "ok" ]; then
    echo "SKIP G3: hooks/check-worktree-notes-lang.js not yet implemented (RED phase)"
else
    # Build a test AGENTS_CONFIG_DIR with .env-based config (post-#619 .env-only).
    _g3_agents_tmp="$(mktemp -d)"; TEST_TMPS+=("$_g3_agents_tmp")
    mkdir -p "$_g3_agents_tmp/hooks/lib"
    cp "$AGENTS_DIR"/hooks/lib/*.js "$_g3_agents_tmp/hooks/lib/"
    printf '%s\n' \
        'DOCS_LANG_HISTORY_PUBLIC=english' \
        'DOCS_LANG_HISTORY_PRIVATE=english' \
        'DOCS_LANG_CHANGELOG_PUBLIC=english' \
        'DOCS_LANG_CHANGELOG_PRIVATE=any' > "$_g3_agents_tmp/.env"
    _g3_agents_dir="$(cygpath -m "$_g3_agents_tmp" 2>/dev/null || echo "$_g3_agents_tmp")"

    # Build a real WORKTREE_NOTES.md on disk; the hook should re-read it.
    _g3_tmp="$(mktemp -d)"
    TEST_TMPS+=("$_g3_tmp")
    _g3_ja="$_g3_tmp/WORKTREE_NOTES.md"
    cat > "$_g3_ja" <<'EOF'
## History Notes
- 日本語のバグ修正

## Changelog Notes
- (none)
EOF
    _g3_en="$_g3_tmp/WORKTREE_NOTES_EN.md"
    cat > "$_g3_en" <<'EOF'
## History Notes
- English bullet only

## Changelog Notes
- (none)
EOF
    _g3_readme="$_g3_tmp/README.md"
    cat > "$_g3_readme" <<'EOF'
## History Notes
- 日本語のバグ修正
EOF
    # Rename EN file copy to WORKTREE_NOTES.md for T17 (basename check)
    _g3_en_dir="$(mktemp -d)"
    TEST_TMPS+=("$_g3_en_dir")
    _g3_en_named="$_g3_en_dir/WORKTREE_NOTES.md"
    cp "$_g3_en" "$_g3_en_named"

    if command -v cygpath >/dev/null 2>&1; then
        _g3_ja_p="$(cygpath -m "$_g3_ja")"
        _g3_en_named_p="$(cygpath -m "$_g3_en_named")"
        _g3_readme_p="$(cygpath -m "$_g3_readme")"
    else
        _g3_ja_p="$_g3_ja"
        _g3_en_named_p="$_g3_en_named"
        _g3_readme_p="$_g3_readme"
    fi

    # T16: Write to WORKTREE_NOTES.md w/ Japanese in History → block
    _t16_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_g3_ja_p\"},\"tool_response\":{}}"
    _t16_out="$(run_hook "$_t16_json" "$_g3_agents_dir")"
    if echo "$_t16_out" | grep -q '"block"'; then
        pass "T16: Write WORKTREE_NOTES.md w/ Japanese History → block"
    else
        fail "T16: expected block, got: $_t16_out"
    fi

    # T17: Write to WORKTREE_NOTES.md English-only → no block
    _t17_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_g3_en_named_p\"},\"tool_response\":{}}"
    _t17_out="$(run_hook "$_t17_json" "$_g3_agents_dir")"
    if ! echo "$_t17_out" | grep -q '"block"'; then
        pass "T17: Write WORKTREE_NOTES.md English only → no block"
    else
        fail "T17: expected no block, got: $_t17_out"
    fi

    # T18: Write to README.md (different basename) → no block (not targeted)
    _t18_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_g3_readme_p\"},\"tool_response\":{}}"
    _t18_out="$(run_hook "$_t18_json" "$_g3_agents_dir")"
    if ! echo "$_t18_out" | grep -q '"block"'; then
        pass "T18: Write README.md (not WORKTREE_NOTES.md) → no block"
    else
        fail "T18: expected no block for README.md, got: $_t18_out"
    fi

    # T19: Edit tool event w/ WORKTREE_NOTES.md → block (same as Write on CJK)
    _t19_json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_g3_ja_p\"},\"tool_response\":{}}"
    _t19_out="$(run_hook "$_t19_json" "$_g3_agents_dir")"
    if echo "$_t19_out" | grep -q '"block"'; then
        pass "T19: Edit WORKTREE_NOTES.md w/ Japanese → block"
    else
        fail "T19: expected block for Edit, got: $_t19_out"
    fi
fi

# ============================================================================
# Group 4 — compose-doc-append-entry integration
# ============================================================================

echo ""
echo "=== Group 4: compose-doc-append-entry integration ==="

if [ "$(src_present "$CLI")" != "ok" ]; then
    echo "SKIP G4: bin/compose-doc-append-entry not present"
elif ! command -v doc-append >/dev/null 2>&1; then
    echo "SKIP G4: doc-append not in PATH"
else
    # Reuse the repo-setup pattern from feature-436.
    setup_repo() {
        local tmp; tmp=$(mktemp -d)
        TEST_TMPS+=("$tmp")
        local upstream="$tmp/upstream.git"
        local work="$tmp/work"
        git init --bare --initial-branch=main "$upstream" >/dev/null
        git init --initial-branch=main "$work" >/dev/null
        git -C "$work" config core.hooksPath /dev/null
        git -C "$work" config user.email "test@example.com"
        git -C "$work" config user.name "Test"
        (cd "$work"
            git remote add origin "$upstream"
            mkdir -p docs/history
            printf "# History\n" > docs/history.md
            printf "# Changelog\n" > CHANGELOG.md
            git add docs/history.md CHANGELOG.md
            git commit --no-verify -m "init" >/dev/null
            git push -u origin main >/dev/null 2>&1
            git remote set-head origin main >/dev/null 2>&1
        )
        echo "$work"
    }

    make_notes_inline() {
        # Args: $1=history_body, $2=changelog_body
        local tmp; tmp=$(mktemp)
        TEST_TMPS+=("$tmp")
        cat > "$tmp" <<EOF
## History Notes
$1

## Changelog Notes
$2
EOF
        # Node.js on Windows cannot read POSIX paths from mktemp; convert to mixed.
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -m "$tmp"
        else
            echo "$tmp"
        fi
    }

    # Build a self-contained AGENTS_CONFIG_DIR for G4 so the language lint can
    # find its libs and a .env with enforcement enabled — without depending on
    # the user's real my-private-repo .env being present.
    # Post-#619: configuration lives in .env (DOCS_LANG_*), not rules/language.md.
    setup_g4_agents_dir() {
        local tmp; tmp=$(mktemp -d)
        TEST_TMPS+=("$tmp")
        mkdir -p "$tmp/hooks/lib" "$tmp/bin"
        # Copy all lib files — is-private-repo.js has transitive deps (parse-git-args, etc.)
        cp "$AGENTS_DIR"/hooks/lib/*.js "$tmp/hooks/lib/"
        # workflow-plans-dir is required by compose-doc-append-entry for staging dir setup.
        cp "$AGENTS_DIR/bin/workflow-plans-dir" "$tmp/bin/"
        printf '%s\n' \
            'DOCS_LANG_HISTORY_PUBLIC=english' \
            'DOCS_LANG_HISTORY_PRIVATE=english' \
            'DOCS_LANG_CHANGELOG_PUBLIC=english' \
            'DOCS_LANG_CHANGELOG_PRIVATE=any' > "$tmp/.env"
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -m "$tmp"
        else
            echo "$tmp"
        fi
    }
    _g4_agents_dir="$(setup_g4_agents_dir)"

    run_cli_in() {
        local repo="$1"; shift
        (
            cd "$repo"
            export COMPOSE_DOC_APPEND_SKILL=1
            export AGENTS_CONFIG_DIR="$_g4_agents_dir"
            # Unset DOCS_LANG_* in subshell env to prevent shell leakage (#619 .env-only).
            # Must unset via shell builtin (not `env -u`) so run_with_timeout (a bash
            # function) is still in scope.
            unset DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE
            unset DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE
            run_with_timeout 30 bash "$CLI" "$@"
        )
    }

    # T20: WORKTREE_NOTES.md History w/ Japanese → CLI exits non-zero
    _t20_repo="$(setup_repo)"
    _t20_notes="$(make_notes_inline "- 日本語のバグ修正" "- (none)")"
    run_cli_in "$_t20_repo" --notes "$_t20_notes" --branch "feat/528" --pr "528" --background "T20 bg"
    _t20_exit=$?
    if [ "$_t20_exit" -ne 0 ]; then
        pass "T20: WORKTREE_NOTES.md History Japanese → compose-doc-append-entry exits non-zero"
    else
        fail "T20: expected non-zero exit, got: $_t20_exit"
    fi

    # T21: English-only History → CLI exits 0 (dry-run: no GitHub auth needed)
    _t21_repo="$(setup_repo)"
    _t21_notes="$(make_notes_inline "- English-only history bullet" "- (none)")"
    run_cli_in "$_t21_repo" --notes "$_t21_notes" --branch "feat/528" --pr "528" --background "T21 bg" --dry-run
    _t21_exit=$?
    if [ "$_t21_exit" -eq 0 ]; then
        pass "T21: English-only History → compose-doc-append-entry exits 0 (dry-run)"
    else
        fail "T21: expected exit 0, got: $_t21_exit"
    fi

    # T23: --dry-run + Japanese in History → exit 0 (dry-run does not hard-exit)
    _t23_repo="$(setup_repo)"
    _t23_notes="$(make_notes_inline "- 日本語の履歴" "- (none)")"
    run_cli_in "$_t23_repo" --notes "$_t23_notes" --branch "feat/528" --pr "528" --background "T23 bg" --dry-run
    _t23_exit=$?
    if [ "$_t23_exit" -eq 0 ]; then
        pass "T23: --dry-run + Japanese in History → exits 0 (dry-run does not hard-exit)"
    else
        fail "T23: expected exit 0 in --dry-run, got: $_t23_exit"
    fi
fi

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

    # T30b: .env DOCS_LANG_HISTORY_PUBLIC drives historyPublic (post-#619 .env-only)
    # Setup hoisted from old T30a body (now self-contained).
    _t30b_tmp=$(mktemp -d); TEST_TMPS+=("$_t30b_tmp")
    _t30b_dir="$(cygpath -m "$_t30b_tmp" 2>/dev/null || echo "$_t30b_tmp")"
    printf 'DOCS_LANG_HISTORY_PUBLIC=english\n' > "$_t30b_tmp/.env"
    _t30b_result="$(env -u DOCS_LANG_HISTORY_PUBLIC -u DOCS_LANG_HISTORY_PRIVATE -u DOCS_LANG_CHANGELOG_PUBLIC -u DOCS_LANG_CHANGELOG_PRIVATE AGENTS_CONFIG_DIR="$_t30b_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('history', { isPrivateRepo: false });
      if (v !== 'english') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T30b: DOCS_LANG_HISTORY_PUBLIC=english in .env → history surface returns 'english'"
    else
        fail "T30b: $_t30b_result"
    fi
fi

# ============================================================================
# Group 9 — lint-plan-lang.js unit tests
# ============================================================================

echo ""
echo "=== Group 9: lint-plan-lang.js unit tests ==="

LINT_PLAN_LIB="$AGENTS_DIR/hooks/lib/lint-plan-lang.js"
if [ "$(src_present "$LINT_PLAN_LIB")" != "ok" ]; then
    echo "SKIP G9: hooks/lib/lint-plan-lang.js not yet implemented (RED phase)"
else
    # T31: blank line → 0 violations
    _t31_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('', 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T31: blank line → 0 violations"; else fail "T31: $_t31_out"; fi

    # T32: heading exempt
    _t32_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('# Heading', 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T32: heading exempt → 0 violations"; else fail "T32: $_t32_out"; fi

    # T33: CJK + english → 1
    _t33_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('日本語テスト', 'english');
      if (v.length !== 1) { process.stderr.write('expected 1, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T33: CJK + english policy → 1 violation"; else fail "T33: $_t33_out"; fi

    # T34: CJK + any → 0
    _t34_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('日本語テスト', 'any');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T34: CJK + any policy → 0 violations"; else fail "T34: $_t34_out"; fi

    # T35: 3 words + japanese → 0 (under threshold)
    _t35_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('Use the API', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T35: 3-word ASCII + japanese → 0 (under threshold)"; else fail "T35: $_t35_out"; fi

    # T36: 5 words + japanese → 1
    _t36_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('Use the new PR API', 'japanese');
      if (v.length !== 1) { process.stderr.write('expected 1, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T36: 5-word ASCII + japanese → 1 violation"; else fail "T36: $_t36_out"; fi

    # T37: fenced CJK stripped
    _t37_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const content = '\`\`\`\n日本語テスト\n\`\`\`';
      const v = lintPlanLang(content, 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T37: CJK inside fenced block → stripped, 0 violations"; else fail "T37: $_t37_out"; fi

    # T38: inline backtick CJK stripped
    _t38_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('use \`日本語\` here', 'english');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T38: CJK inside inline backtick → stripped, 0 violations"; else fail "T38: $_t38_out"; fi

    # T54: issue title prefix stripped → 0 violations (japanese policy, 4-word title)
    _t54_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('- #629: check-plan-lang issue title excluded', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T54: issue ref line - #N: title → 0 violations (japanese)"; else fail "T54: $_t54_out"; fi

    # T55: issue title prefix stripped → 0 violations (japanese policy, 7-word title)
    _t55_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('- #100: auto-resolve Projects v2 config from git remote', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T55: issue ref line - #N: long title → 0 violations (japanese)"; else fail "T55: $_t55_out"; fi

    # T56: issue ref with no title → 0 violations (japanese policy, edge case)
    _t56_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const v = lintPlanLang('- #629:', 'japanese');
      if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T56: issue ref line - #N: (empty title) → 0 violations (japanese)"; else fail "T56: $_t56_out"; fi
fi

# ============================================================================
# Group 10 — check-plan-lang.js hook integration
# ============================================================================

echo ""
echo "=== Group 10: check-plan-lang.js integration ==="

CHECK_PLAN_HOOK="$AGENTS_DIR/hooks/check-plan-lang.js"
if [ "$(src_present "$CHECK_PLAN_HOOK")" != "ok" ]; then
    echo "SKIP G10: hooks/check-plan-lang.js not yet implemented (RED phase)"
else
    _g10_plans_tmp=$(mktemp -d); TEST_TMPS+=("$_g10_plans_tmp")
    _g10_agents_tmp=$(mktemp -d); TEST_TMPS+=("$_g10_agents_tmp")
    printf 'PLAN_LANG=english\n' > "$_g10_agents_tmp/.env"

    _g10_plans_dir="$(cygpath -m "$_g10_plans_tmp" 2>/dev/null || echo "$_g10_plans_tmp")"
    _g10_agents_dir="$(cygpath -m "$_g10_agents_tmp" 2>/dev/null || echo "$_g10_agents_tmp")"

    run_plan_hook() {
        local json="$1"
        (export WORKFLOW_PLANS_DIR="$_g10_plans_dir"
         export AGENTS_CONFIG_DIR="$_g10_agents_dir"
         echo "$json" | run_with_timeout 10 node "$AGENTS_DIR/hooks/check-plan-lang.js" 2>/dev/null)
    }

    # T39: CJK content in intent.md → block
    _t39_file="$_g10_plans_dir/20260526-223459-intent.md"
    _t39_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t39_file\",\"content\":\"## Planning\n日本語テスト\"},\"tool_response\":{}}"
    _t39_out="$(run_plan_hook "$_t39_json")"
    if echo "$_t39_out" | grep -q '"block"'; then
        pass "T39: CJK in intent.md with PLAN_LANG=english → block"
    else
        fail "T39: expected block, got: $_t39_out"
    fi

    # T40: drafts/ file → approved
    mkdir -p "$_g10_plans_tmp/drafts"
    _t40_file="$_g10_plans_dir/drafts/20260526-223459-detail-draft.md"
    _t40_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t40_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t40_out="$(run_plan_hook "$_t40_json")"
    if ! echo "$_t40_out" | grep -q '"block"'; then
        pass "T40: drafts/...-detail-draft.md → approve (excluded)"
    else
        fail "T40: expected approve for draft, got: $_t40_out"
    fi

    # T41: file outside PLANS_DIR → approved
    _t41_tmp=$(mktemp); TEST_TMPS+=("$_t41_tmp")
    _t41_file="$(cygpath -m "$_t41_tmp" 2>/dev/null || echo "$_t41_tmp")"
    _t41_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t41_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t41_out="$(run_plan_hook "$_t41_json")"
    if ! echo "$_t41_out" | grep -q '"block"'; then
        pass "T41: file outside PLANS_DIR → approve"
    else
        fail "T41: expected approve for outside-PLANS_DIR, got: $_t41_out"
    fi

    # T42: wrong basename in PLANS_DIR → approved
    _t42_file="$_g10_plans_dir/notes.md"
    _t42_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t42_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t42_out="$(run_plan_hook "$_t42_json")"
    if ! echo "$_t42_out" | grep -q '"block"'; then
        pass "T42: non-artifact basename in PLANS_DIR → approve"
    else
        fail "T42: expected approve for non-artifact name, got: $_t42_out"
    fi

    # T43: editFiles tool → blocked
    _t43_file="$_g10_plans_dir/20260526-223459-outline.md"
    _t43_json="{\"tool_name\":\"editFiles\",\"tool_input\":{\"file_path\":\"$_t43_file\",\"content\":\"日本語テスト\"},\"tool_response\":{}}"
    _t43_out="$(run_plan_hook "$_t43_json")"
    if echo "$_t43_out" | grep -q '"block"'; then
        pass "T43: editFiles tool + CJK content → block"
    else
        fail "T43: expected block for editFiles, got: $_t43_out"
    fi
fi

# ============================================================================
# Group 12 — arbitrary-language hint tier
# ============================================================================

echo ""
echo "=== Group 12: arbitrary-language hint tier ==="

if [ "$(src_present "$LANG_CONFIG_LIB")" != "ok" ] || [ "$(src_present "$CHECK_PLAN_HOOK")" != "ok" ]; then
    echo "SKIP G12: lang-config / check-plan not yet implemented"
else
    # T47: PLAN_LANG=french preserved verbatim by loadLangConfig
    _t47_tmp=$(mktemp -d); TEST_TMPS+=("$_t47_tmp")
    printf 'PLAN_LANG=french\n' > "$_t47_tmp/.env"
    _t47_dir="$(cygpath -m "$_t47_tmp" 2>/dev/null || echo "$_t47_tmp")"
    _t47_out="$(env -u PLAN_LANG AGENTS_CONFIG_DIR="$_t47_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('plan');
      if (v !== 'french') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T47: PLAN_LANG=french preserved verbatim"; else fail "T47: $_t47_out"; fi

    # T48: empty PLAN_LANG → 'any' (fail-open)
    printf 'PLAN_LANG=\n' > "$_t47_tmp/.env"
    _t48_out="$(env -u PLAN_LANG AGENTS_CONFIG_DIR="$_t47_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('plan');
      if (v !== 'any') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T48: empty PLAN_LANG → 'any' (fail-open)"; else fail "T48: $_t48_out"; fi

    # T49: lintPlanLang hint-tier vs strict-tier symmetry
    _t49_out="$(node -e "
      const { lintPlanLang } = require('$_AGENTS_DIR_NODE/hooks/lib/lint-plan-lang');
      const content = 'plain english long sentence here please';
      const hintViolations = lintPlanLang(content, 'french');
      const strictViolations = lintPlanLang(content, 'japanese');
      if (hintViolations.length !== 0) {
        process.stderr.write('hint-tier produced violations: ' + JSON.stringify(hintViolations) + '\n');
        process.exit(1);
      }
      if (strictViolations.length === 0) {
        process.stderr.write('strict-tier should have flagged English-run content\n');
        process.exit(2);
      }
    " 2>&1)"
    if [ $? -eq 0 ]; then pass "T49: hint-tier (french) → 0 violations; same content under 'japanese' → violation (classifier gates)"; else fail "T49: $_t49_out"; fi

    # T50: check-plan-lang.js PLAN_LANG=french → approve + additionalContext
    _t50_plans_tmp=$(mktemp -d); TEST_TMPS+=("$_t50_plans_tmp")
    _t50_agents_tmp=$(mktemp -d); TEST_TMPS+=("$_t50_agents_tmp")
    printf 'PLAN_LANG=french\n' > "$_t50_agents_tmp/.env"
    _t50_plans_dir="$(cygpath -m "$_t50_plans_tmp" 2>/dev/null || echo "$_t50_plans_tmp")"
    _t50_agents_dir="$(cygpath -m "$_t50_agents_tmp" 2>/dev/null || echo "$_t50_agents_tmp")"
    _t50_file="$_t50_plans_dir/20260526-223459-intent.md"
    _t50_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_t50_file\",\"content\":\"日本語\"},\"tool_response\":{}}"
    _t50_out="$(export WORKFLOW_PLANS_DIR="$_t50_plans_dir"; export AGENTS_CONFIG_DIR="$_t50_agents_dir"; echo "$_t50_json" | run_with_timeout 10 node "$CHECK_PLAN_HOOK" 2>/dev/null)"
    _t50_ok=1
    echo "$_t50_out" | grep -q '"approve"' || _t50_ok=0
    echo "$_t50_out" | grep -q 'PLAN_LANG=french' || _t50_ok=0
    echo "$_t50_out" | grep -q 'additionalContext' || _t50_ok=0
    if [ "$_t50_ok" -eq 1 ]; then
        pass "T50: PLAN_LANG=french + CJK content → approve + additionalContext (hint)"
    else
        fail "T50: expected approve+hint, got: $_t50_out"
    fi

    # T52a: lintWorktreeNotesLang historyPublic=french + CJK → 0 violations (hint tier)
    _t52a_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- 日本語のバグ修正

## Changelog Notes
- (none)
EOF
)"
    _t52a_cfg='{"historyPublic":"french","historyPrivate":"french","changelogPublic":"any","changelogPrivate":"any"}'
    _t52a_count="$(lint_count "$_t52a_file" "$_t52a_cfg" '{"isPrivateRepo":false}')"
    if [ "$_t52a_count" = "0" ]; then
        pass "T52a: historyPublic=french + CJK History bullet → 0 violations (hint tier)"
    else
        fail "T52a: expected 0, got: $_t52a_count"
    fi

    # T52b: changelogPublic=french + CJK Changelog bullet → 0 violations (hint tier symmetry)
    _t52b_file="$(write_tmp_file WORKTREE_NOTES.md <<'EOF'
## History Notes
- (none)

## Changelog Notes
- 日本語の変更点
EOF
)"
    _t52b_cfg='{"historyPublic":"any","historyPrivate":"any","changelogPublic":"french","changelogPrivate":"french"}'
    _t52b_count="$(lint_count "$_t52b_file" "$_t52b_cfg" '{"isPrivateRepo":false}')"
    if [ "$_t52b_count" = "0" ]; then
        pass "T52b: changelogPublic=french + CJK Changelog bullet → 0 violations (hint tier symmetry)"
    else
        fail "T52b: expected 0, got: $_t52b_count"
    fi

    # T53 REMOVED (#619): legacy DOCS_LANG_HISTORY ignore-test is moot — the
    # fenced-block parser itself is gone, so legacy keys cannot reach the config.
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
