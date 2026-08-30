#!/bin/bash
# tests/feature-issue-528-lang-enforce/worktree-notes-hook-cases.sh
# Tests: hooks/check-worktree-notes-lang.js
# Tags: worktree, docs, hook, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

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
        'DOCS_LANG_PUBLIC=english' \
        'DOCS_LANG_PRIVATE=english' > "$_g3_agents_tmp/.env"
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

    # ========================================================================
    # Group 3b — visibility routing through the REAL hook subprocess
    # ========================================================================
    # G3 above pins one policy for both visibilities, so it cannot tell which of
    # DOCS_LANG_PUBLIC / DOCS_LANG_PRIVATE the hook actually read. Here the two
    # keys hold OPPOSITE policies and the answer comes from the hook's own
    # safeIsPrivateRepo(process.cwd()) — the library-level routing test in
    # lang-config-routing-cases.sh passes isPrivateRepo in by hand and never
    # exercises that resolution.
    echo ""
    echo "=== Group 3b: visibility routing end-to-end (hook subprocess) ==="

    _g3b_agents_tmp="$(mktemp -d)"; TEST_TMPS+=("$_g3b_agents_tmp")
    printf '%s\n' \
        'DOCS_LANG_PUBLIC=english' \
        'DOCS_LANG_PRIVATE=japanese' > "$_g3b_agents_tmp/.env"
    _g3b_agents_dir="$(cygpath -m "$_g3b_agents_tmp" 2>/dev/null || echo "$_g3b_agents_tmp")"

    # A git repo whose origin host is NOT github.com — is-private-repo.js treats
    # every non-GitHub forge as private without consulting `gh`, so the private
    # branch is reachable offline and without credentials.
    make_repo_visibility() {
        local remote="$1" tmp
        tmp="$(mktemp -d)"; TEST_TMPS+=("$tmp")
        git -C "$tmp" init -q
        git -C "$tmp" config core.hooksPath /dev/null
        [ -n "$remote" ] && git -C "$tmp" remote add origin "$remote"
        echo "$tmp"
    }

    # Same as run_hook, but the hook runs WITH the fixture repo as its cwd —
    # which is the only input deciding public vs private.
    run_hook_in_repo() {
        local json="$1" agents_dir="$2" repo="$3"
        (
            cd "$repo" || exit 1
            unset DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE
            unset DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE
            unset DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE
            export AGENTS_CONFIG_DIR="$agents_dir"
            echo "$json" | run_with_timeout 20 node "$HOOK" 2>/dev/null
        )
    }

    _g3b_priv_repo="$(make_repo_visibility 'https://gitlab.example.com/acme/thing.git')"
    _g3b_pub_repo="$(make_repo_visibility '')"

    # One notes file per (repo, language). The English bullet is 4+ words so the
    # japanese policy's ENGLISH_RUN_RE actually fires.
    write_g3b_notes() {
        local repo="$1" bullet="$2"
        printf '%s\n' '## History Notes' "- $bullet" '' '## Changelog Notes' '- (none)' \
            > "$repo/WORKTREE_NOTES.md"
        cygpath -m "$repo/WORKTREE_NOTES.md" 2>/dev/null || echo "$repo/WORKTREE_NOTES.md"
    }

    g3b_hook_decision() {
        local repo="$1" bullet="$2" p out
        p="$(write_g3b_notes "$repo" "$bullet")"
        out="$(run_hook_in_repo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$p\"},\"tool_response\":{}}" "$_g3b_agents_dir" "$repo")"
        if echo "$out" | grep -q '"block"'; then echo "block"; else echo "allow"; fi
    }

    _g3b_en='This is an English only history bullet'
    _g3b_ja='日本語の履歴エントリ'

    # Row: <repo> <bullet> <expected decision> <label>
    _g3b_report=""
    _g3b_report+="private+english=$(g3b_hook_decision "$_g3b_priv_repo" "$_g3b_en")"$'\n'
    _g3b_report+="private+japanese=$(g3b_hook_decision "$_g3b_priv_repo" "$_g3b_ja")"$'\n'
    _g3b_report+="public+english=$(g3b_hook_decision "$_g3b_pub_repo" "$_g3b_en")"$'\n'
    _g3b_report+="public+japanese=$(g3b_hook_decision "$_g3b_pub_repo" "$_g3b_ja")"
    _g3b_expected="private+english=block
private+japanese=allow
public+english=allow
public+japanese=block"

    if [ "$_g3b_report" = "$_g3b_expected" ]; then
        pass "T19b: hook routes DOCS_LANG_PRIVATE to a private-origin repo and DOCS_LANG_PUBLIC to a public one (all 4 rows)"
    else
        fail "T19b: visibility routing mismatch. expected:
$_g3b_expected
got:
$_g3b_report"
    fi
fi
