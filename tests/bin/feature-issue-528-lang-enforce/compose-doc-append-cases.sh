#!/bin/bash
# tests/feature-issue-528-lang-enforce/compose-doc-append-cases.sh
# Tests: bin/compose-doc-append-entry
# Tags: worktree, docs, append, history, compose, scope:issue-specific
# Sourced by ../feature-issue-528-lang-enforce.sh — helpers come from there.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for CJK-detection tests

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
            'DOCS_LANG_PUBLIC=english' \
            'DOCS_LANG_PRIVATE=english' > "$tmp/.env"
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
            unset DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE
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

    # ---- T25/T26: the CLI's OWN env isolation, not the harness's ----
    # T20-T23 unset DOCS_LANG_* in the harness before invoking, so they pass even
    # if the production `env -u DOCS_LANG_PUBLIC -u DOCS_LANG_PRIVATE` in
    # compose-doc-append-entry were dropped. These two leave an ambient value
    # DELIBERATELY exported and let the script's own unset list be the thing that
    # decides — a leak is observable because load-env.js lets process.env win
    # over .env.
    run_cli_leaky() {
        local repo="$1" agents_dir="$2" ambient="$3"; shift 3
        (
            cd "$repo"
            export COMPOSE_DOC_APPEND_SKILL=1
            export AGENTS_CONFIG_DIR="$agents_dir"
            export DOCS_LANG_PUBLIC="$ambient"
            run_with_timeout 30 bash "$CLI" "$@"
        )
    }

    # A second config dir whose public policy is OFF, for the T26 direction.
    setup_g4_agents_dir_any() {
        local tmp; tmp=$(mktemp -d)
        TEST_TMPS+=("$tmp")
        mkdir -p "$tmp/hooks/lib" "$tmp/bin"
        cp "$AGENTS_DIR"/hooks/lib/*.js "$tmp/hooks/lib/"
        cp "$AGENTS_DIR/bin/workflow-plans-dir" "$tmp/bin/"
        printf '%s\n' 'DOCS_LANG_PUBLIC=any' 'DOCS_LANG_PRIVATE=any' > "$tmp/.env"
        cygpath -m "$tmp" 2>/dev/null || echo "$tmp"
    }
    _g4_agents_dir_any="$(setup_g4_agents_dir_any)"

    # T25: .env says english, the shell says japanese, the bullet is Japanese.
    # A leaked ambient value would relax the policy and exit 0.
    _t25_repo="$(setup_repo)"
    _t25_notes="$(make_notes_inline "- 日本語のバグ修正" "- (none)")"
    run_cli_leaky "$_t25_repo" "$_g4_agents_dir" japanese --notes "$_t25_notes" --branch "feat/2153" --pr "2153" --background "T25 bg"
    _t25_exit=$?
    if [ "$_t25_exit" -ne 0 ]; then
        pass "T25: an ambient DOCS_LANG_PUBLIC cannot relax the .env policy (CLI's own env -u)"
    else
        fail "T25: ambient DOCS_LANG_PUBLIC=japanese leaked past the CLI's unset list — exit was 0"
    fi

    # T26: the mirror. .env says any (enforcement off), the shell says english,
    # the bullet is Japanese. A leaked ambient value would TIGHTEN the policy.
    # --dry-run never changes the exit code (T23), so the assertion is on the
    # lint's own diagnostic, which dry-run still prints.
    _t26_repo="$(setup_repo)"
    _t26_notes="$(make_notes_inline "- 日本語のバグ修正" "- (none)")"
    _t26_out="$(run_cli_leaky "$_t26_repo" "$_g4_agents_dir_any" english --notes "$_t26_notes" --branch "feat/2153" --pr "2153" --background "T26 bg" --dry-run 2>&1)"
    if ! echo "$_t26_out" | grep -q 'language lint failed'; then
        pass "T26: an ambient DOCS_LANG_PUBLIC cannot tighten a .env policy of 'any'"
    else
        fail "T26: ambient DOCS_LANG_PUBLIC=english leaked past the CLI's unset list — lint fired under DOCS_LANG_PUBLIC=any: $_t26_out"
    fi

    # T26b: false-green guard for T26 — the same fixture with the .env policy
    # actually set to english MUST produce that diagnostic, so T26's "absent"
    # cannot be an artifact of the message never appearing at all.
    _t26b_repo="$(setup_repo)"
    _t26b_notes="$(make_notes_inline "- 日本語のバグ修正" "- (none)")"
    _t26b_out="$(run_cli_leaky "$_t26b_repo" "$_g4_agents_dir" english --notes "$_t26b_notes" --branch "feat/2153" --pr "2153" --background "T26b bg" --dry-run 2>&1)"
    if echo "$_t26b_out" | grep -q 'language lint failed'; then
        pass "T26b: the same run under .env DOCS_LANG_PUBLIC=english does emit the lint diagnostic"
    else
        fail "T26b: expected a 'language lint failed' diagnostic, got: $_t26b_out"
    fi
fi
