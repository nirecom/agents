#!/bin/bash
# tests/feature-issue-528-lang-enforce.sh
#
# Test suite for issue #528 — WORKTREE_NOTES.md language enforcement.
#
# Source files under test (TDD — may not exist yet at run time):
#   - hooks/lib/docs-lang-config.js         (parses docs-lang fenced block)
#   - hooks/lib/lint-worktree-notes-lang.js (CJK linter)
#   - hooks/check-worktree-notes-lang.js    (PostToolUse hook)
#   - bin/compose-doc-append-entry          (MODIFIED to run language lint)
#
# Groups:
#   G1 (T1-T7)   docs-lang-config.js parser unit tests
#   G2 (T8-T15)  lint-worktree-notes-lang.js unit tests
#   G3 (T16-T19) check-worktree-notes-lang.js hook integration
#   G4 (T20-T23) compose-doc-append-entry integration
#   G5 (T24)     settings.json static check
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CONFIG_LIB="$AGENTS_DIR/hooks/lib/docs-lang-config.js"
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

# Make a temp language.md with a docs-lang fenced block.
# Args: $1=history, $2=changelogPublic, $3=changelogPrivate
make_lang_file() {
    local tmp; tmp=$(mktemp -d)
    TEST_TMPS+=("$tmp")
    local f="$tmp/language.md"
    cat > "$f" <<EOF
# Language Policy

Some prose here.

\`\`\`docs-lang
DOCS_LANG_HISTORY=$1
DOCS_LANG_CHANGELOG_PUBLIC=$2
DOCS_LANG_CHANGELOG_PRIVATE=$3
\`\`\`

More prose.
EOF
    echo "$f"
}

# Make a temp language.md with no docs-lang block.
make_lang_file_no_block() {
    local tmp; tmp=$(mktemp -d)
    TEST_TMPS+=("$tmp")
    local f="$tmp/language.md"
    cat > "$f" <<EOF
# Language Policy

No docs-lang block here.
EOF
    echo "$f"
}

# Make a temp language.md with arbitrary body (caller supplies via stdin).
make_lang_file_raw() {
    local tmp; tmp=$(mktemp -d)
    TEST_TMPS+=("$tmp")
    local f="$tmp/language.md"
    cat > "$f"
    echo "$f"
}

# Echo "ok" or "missing" for a source file (helps mark RED-phase skips).
src_present() {
    if [ -f "$1" ]; then echo "ok"; else echo "missing"; fi
}

# Run a node one-liner that loads docs-lang-config and prints JSON.
# Args: $1=language.md path (or "MISSING" for nonexistent)
load_config_json() {
    local langpath="$1"
    if command -v cygpath >/dev/null 2>&1 && [ "$langpath" != "MISSING" ]; then
        langpath="$(cygpath -m "$langpath")"
    fi
    run_with_timeout 15 node -e "
        const m = require('$CONFIG_LIB_NODE');
        const cfg = m.loadDocsLangConfig('$langpath');
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
run_hook() {
    local json="$1"
    echo "$json" | run_with_timeout 15 node "$HOOK" 2>/dev/null
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
# Group 1 — docs-lang-config.js parser unit tests
# ============================================================================

echo "=== Group 1: docs-lang-config.js parser ==="

if [ "$(src_present "$CONFIG_LIB")" != "ok" ]; then
    echo "SKIP G1: hooks/lib/docs-lang-config.js not yet implemented (RED phase)"
else
    # T1: valid block with all keys
    _t1_lang="$(make_lang_file english english any)"
    _t1_json="$(load_config_json "$_t1_lang")"
    if echo "$_t1_json" | grep -q '"history":"english"' && \
       echo "$_t1_json" | grep -q '"changelogPublic":"english"' && \
       echo "$_t1_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T1: valid docs-lang block parsed → {history:english, changelogPublic:english, changelogPrivate:any}"
    else
        fail "T1: valid block parse, got: $_t1_json"
    fi

    # T2: DOCS_LANG_HISTORY=japanese
    _t2_lang="$(make_lang_file japanese any any)"
    _t2_json="$(load_config_json "$_t2_lang")"
    if echo "$_t2_json" | grep -q '"history":"japanese"'; then
        pass "T2: DOCS_LANG_HISTORY=japanese → {history:japanese}"
    else
        fail "T2: japanese parse, got: $_t2_json"
    fi

    # T3: DOCS_LANG_HISTORY=any
    _t3_lang="$(make_lang_file any any any)"
    _t3_json="$(load_config_json "$_t3_lang")"
    if echo "$_t3_json" | grep -q '"history":"any"'; then
        pass "T3: DOCS_LANG_HISTORY=any → {history:any}"
    else
        fail "T3: any parse, got: $_t3_json"
    fi

    # T4: file missing → all "any" (fail-open)
    _t4_json="$(load_config_json "/nonexistent/language.md")"
    if echo "$_t4_json" | grep -q '"history":"any"' && \
       echo "$_t4_json" | grep -q '"changelogPublic":"any"' && \
       echo "$_t4_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T4: file missing → all any (fail-open)"
    else
        fail "T4: missing-file fail-open, got: $_t4_json"
    fi

    # T5: file exists but no docs-lang block → all "any"
    _t5_lang="$(make_lang_file_no_block)"
    _t5_json="$(load_config_json "$_t5_lang")"
    if echo "$_t5_json" | grep -q '"history":"any"' && \
       echo "$_t5_json" | grep -q '"changelogPublic":"any"' && \
       echo "$_t5_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T5: file w/o docs-lang block → all any"
    else
        fail "T5: no-block fail-open, got: $_t5_json"
    fi

    # T6: unknown value → that key defaults to "any"
    _t6_lang="$(make_lang_file french any any)"
    _t6_json="$(load_config_json "$_t6_lang")"
    if echo "$_t6_json" | grep -q '"history":"any"'; then
        pass "T6: unknown value (french) → history:any"
    else
        fail "T6: unknown-value defaults to any, got: $_t6_json"
    fi

    # T7: only DOCS_LANG_HISTORY present, others missing → missing keys are "any"
    _t7_lang="$(make_lang_file_raw <<'EOF'
# Language Policy
```docs-lang
DOCS_LANG_HISTORY=english
```
EOF
)"
    _t7_json="$(load_config_json "$_t7_lang")"
    if echo "$_t7_json" | grep -q '"history":"english"' && \
       echo "$_t7_json" | grep -q '"changelogPublic":"any"' && \
       echo "$_t7_json" | grep -q '"changelogPrivate":"any"'; then
        pass "T7: only DOCS_LANG_HISTORY present → others default to any"
    else
        fail "T7: partial-keys default, got: $_t7_json"
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
    CFG_HIST_EN='{"history":"english","changelogPublic":"english","changelogPrivate":"any"}'
    CFG_HIST_JA='{"history":"japanese","changelogPublic":"english","changelogPrivate":"any"}'

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
    _t11_cfg='{"history":"english","changelogPublic":"english","changelogPrivate":"any"}'
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

    # T14: options.skipHistory=true → History skipped, no violation for History CJK
    _t14_count="$(lint_count "$_t9_file" "$CFG_HIST_EN" '{"skipHistory":true}')"
    if [ "$_t14_count" = "0" ]; then
        pass "T14: skipHistory=true → History CJK skipped, 0 violations"
    else
        fail "T14: expected 0 violations with skipHistory, got: $_t14_count"
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
    _t16_out="$(run_hook "$_t16_json")"
    if echo "$_t16_out" | grep -q '"block"'; then
        pass "T16: Write WORKTREE_NOTES.md w/ Japanese History → block"
    else
        fail "T16: expected block, got: $_t16_out"
    fi

    # T17: Write to WORKTREE_NOTES.md English-only → no block
    _t17_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_g3_en_named_p\"},\"tool_response\":{}}"
    _t17_out="$(run_hook "$_t17_json")"
    if ! echo "$_t17_out" | grep -q '"block"'; then
        pass "T17: Write WORKTREE_NOTES.md English only → no block"
    else
        fail "T17: expected no block, got: $_t17_out"
    fi

    # T18: Write to README.md (different basename) → no block (not targeted)
    _t18_json="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$_g3_readme_p\"},\"tool_response\":{}}"
    _t18_out="$(run_hook "$_t18_json")"
    if ! echo "$_t18_out" | grep -q '"block"'; then
        pass "T18: Write README.md (not WORKTREE_NOTES.md) → no block"
    else
        fail "T18: expected no block for README.md, got: $_t18_out"
    fi

    # T19: Edit tool event w/ WORKTREE_NOTES.md → block (same as Write on CJK)
    _t19_json="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_g3_ja_p\"},\"tool_response\":{}}"
    _t19_out="$(run_hook "$_t19_json")"
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
    # find its libs and a rules/language.md with enforcement enabled — without
    # depending on the user's real my-private-repo language.md being present.
    setup_g4_agents_dir() {
        local tmp; tmp=$(mktemp -d)
        TEST_TMPS+=("$tmp")
        mkdir -p "$tmp/hooks/lib" "$tmp/rules"
        # Copy all lib files — is-private-repo.js has transitive deps (parse-git-args, etc.)
        cp "$AGENTS_DIR"/hooks/lib/*.js "$tmp/hooks/lib/"
        printf '%s\n' '```docs-lang' \
            'DOCS_LANG_HISTORY=english' \
            'DOCS_LANG_CHANGELOG_PUBLIC=english' \
            'DOCS_LANG_CHANGELOG_PRIVATE=any' \
            '```' > "$tmp/rules/language.md"
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

    # T21: English-only History → CLI exits 0
    _t21_repo="$(setup_repo)"
    _t21_notes="$(make_notes_inline "- English-only history bullet" "- (none)")"
    run_cli_in "$_t21_repo" --notes "$_t21_notes" --branch "feat/528" --pr "528" --background "T21 bg"
    _t21_exit=$?
    if [ "$_t21_exit" -eq 0 ]; then
        pass "T21: English-only History → compose-doc-append-entry exits 0"
    else
        fail "T21: expected exit 0, got: $_t21_exit"
    fi

    # T22: --skip-history + Japanese in History + no Changelog violations → exit 0
    _t22_repo="$(setup_repo)"
    _t22_notes="$(make_notes_inline "- 日本語の履歴 (should be skipped)" "- English changelog only")"
    run_cli_in "$_t22_repo" --notes "$_t22_notes" --branch "feat/528" --pr "528" --background "T22 bg" --skip-history
    _t22_exit=$?
    if [ "$_t22_exit" -eq 0 ]; then
        pass "T22: --skip-history + Japanese in History → lint skips History, exits 0"
    else
        fail "T22: expected exit 0 with --skip-history, got: $_t22_exit"
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
# Group 7 — docs-lang-config.js shim regression
# ============================================================================

echo ""
echo "=== Group 7: docs-lang-config.js shim regression ==="

LANG_CONFIG_LIB="$AGENTS_DIR/hooks/lib/lang-config.js"
DOCS_LANG_SHIM="$AGENTS_DIR/hooks/lib/docs-lang-config.js"
if [ "$(src_present "$LANG_CONFIG_LIB")" != "ok" ] || [ "$(src_present "$DOCS_LANG_SHIM")" != "ok" ]; then
    echo "SKIP G7: hooks/lib/lang-config.js or hooks/lib/docs-lang-config.js not yet implemented (RED phase)"
else
    # T27a: relative require
    _t27a_out="$(node -e "
      const mod = require('$_AGENTS_DIR_NODE/hooks/lib/docs-lang-config');
      const assert = require('assert');
      assert.strictEqual(typeof mod.loadDocsLangConfig, 'function');
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T27a: docs-lang-config shim exposes loadDocsLangConfig (relative require)"
    else
        fail "T27a: $_t27a_out"
    fi

    # T27b: absolute-path require
    _t27b_out="$(node -e "
      const path = require('path');
      const absPath = path.join('$_AGENTS_DIR_NODE', 'hooks/lib/docs-lang-config.js');
      const mod = require(absPath);
      const assert = require('assert');
      assert.strictEqual(typeof mod.loadDocsLangConfig, 'function');
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T27b: docs-lang-config shim exposes loadDocsLangConfig (absolute require)"
    else
        fail "T27b: $_t27b_out"
    fi
fi

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
      const v = loadLangConfig('plan', undefined);
      if (v !== 'english') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T28: PLAN_LANG=english from .env"
    else
        fail "T28: $_t28_result"
    fi

    # T29: ASK_LANG from .env
    _t29_tmp=$(mktemp -d); TEST_TMPS+=("$_t29_tmp")
    printf 'ASK_LANG=japanese\n' > "$_t29_tmp/.env"
    _t29_dir="$(cygpath -m "$_t29_tmp" 2>/dev/null || echo "$_t29_tmp")"
    _t29_result="$(env -u ASK_LANG AGENTS_CONFIG_DIR="$_t29_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('ask', undefined);
      if (v !== 'japanese') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T29: ASK_LANG=japanese from .env"
    else
        fail "T29: $_t29_result"
    fi

    # T30a: history surface — docs-lang fenced block fallback
    _t30_tmp=$(mktemp -d); TEST_TMPS+=("$_t30_tmp")
    _t30_lang="$(make_lang_file japanese english any)"
    printf '' > "$_t30_tmp/.env"
    _t30_dir="$(cygpath -m "$_t30_tmp" 2>/dev/null || echo "$_t30_tmp")"
    _t30_lang_node="$(cygpath -m "$_t30_lang" 2>/dev/null || echo "$_t30_lang")"
    _t30a_result="$(env -u DOCS_LANG_HISTORY AGENTS_CONFIG_DIR="$_t30_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('history', '$_t30_lang_node');
      if (v !== 'japanese') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T30a: history surface falls back to fenced block (japanese)"
    else
        fail "T30a: $_t30a_result"
    fi

    # T30b: .env DOCS_LANG_HISTORY wins over fenced block
    printf 'DOCS_LANG_HISTORY=english\n' > "$_t30_tmp/.env"
    _t30b_result="$(env -u DOCS_LANG_HISTORY AGENTS_CONFIG_DIR="$_t30_dir" node -e "
      const { loadLangConfig } = require('$_AGENTS_DIR_NODE/hooks/lib/lang-config');
      const v = loadLangConfig('history', '$_t30_lang_node');
      if (v !== 'english') { process.stderr.write('got: ' + v + '\n'); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
        pass "T30b: .env DOCS_LANG_HISTORY=english wins over fenced block"
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
# Group 11 — check-ask-lang.js integration
# ============================================================================

echo ""
echo "=== Group 11: check-ask-lang.js integration ==="

CHECK_ASK_HOOK="$AGENTS_DIR/hooks/check-ask-lang.js"
if [ "$(src_present "$CHECK_ASK_HOOK")" != "ok" ]; then
    echo "SKIP G11: hooks/check-ask-lang.js not yet implemented (RED phase)"
else
    _g11_agents_tmp=$(mktemp -d); TEST_TMPS+=("$_g11_agents_tmp")
    printf 'ASK_LANG=english\n' > "$_g11_agents_tmp/.env"
    _g11_agents_dir="$(cygpath -m "$_g11_agents_tmp" 2>/dev/null || echo "$_g11_agents_tmp")"

    run_ask_hook() {
        local json="$1"
        (export AGENTS_CONFIG_DIR="$_g11_agents_dir"
         echo "$json" | run_with_timeout 10 node "$AGENTS_DIR/hooks/check-ask-lang.js" 2>/dev/null)
    }

    # T44: CJK in question → approve + additionalContext
    _t44_json="{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"日本語のテスト\",\"type\":\"select\",\"choices\":[]},\"tool_response\":{}}"
    _t44_out="$(run_ask_hook "$_t44_json")"
    _t44_ok=1
    echo "$_t44_out" | grep -q '"approve"' || _t44_ok=0
    echo "$_t44_out" | grep -q 'additionalContext' || _t44_ok=0
    if [ "$_t44_ok" -eq 1 ]; then
        pass "T44: CJK in question → approve + additionalContext"
    else
        fail "T44: expected approve+additionalContext, got: $_t44_out"
    fi

    # T45: CJK in choices → additionalContext
    _t45_json="{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"question\":\"Please choose\",\"type\":\"select\",\"choices\":[\"日本語の選択肢\",\"OK\"]},\"tool_response\":{}}"
    _t45_out="$(run_ask_hook "$_t45_json")"
    if echo "$_t45_out" | grep -q 'additionalContext'; then
        pass "T45: CJK in choices → additionalContext present"
    else
        fail "T45: expected additionalContext for CJK choices, got: $_t45_out"
    fi

    # T46: malformed input → approve
    _t46_json="{\"tool_name\":\"AskUserQuestion\",\"tool_response\":{}}"
    _t46_out="$(run_ask_hook "$_t46_json")"
    if echo "$_t46_out" | grep -q '"approve"'; then
        pass "T46: malformed input → approve (fail-open)"
    else
        fail "T46: expected approve for malformed input, got: $_t46_out"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
