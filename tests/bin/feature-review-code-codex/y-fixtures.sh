# Part of the feature-review-code-codex entrypoints (sourced, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, merge-base, base-state, boundary, fixture, scope:issue-specific, pwsh-not-required, TL2
# The Y-series helpers and the exact-size repos Y_AT_REPO / Y_OVER_REPO, moved verbatim out of base-state-scope.sh (#2723) so that -path-priority can reuse them without running the Y rows.

Y_CAPTURE="$TMPDIR_BASE/captured-scope-prompt.txt"

# A mock codex that records the prompt it was handed. Written fresh here because the parent's
# mock is overwritten several times and the rows below must not depend on which one is current.
y_install_capturing_mock() {
    cat > "$MOCK_BIN/codex" <<MOCK_EOF
#!/usr/bin/env bash
cat > "$Y_CAPTURE"
echo "HIGH: Something looks risky."
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

y_install_quiet_mock() {
    cat > "$MOCK_BIN/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "No findings."
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

y_run() { # <repo> [args...] ; prints stdout
    local repo="$1"
    shift
    # C2 (#1976 review gap): unset first, inside the subshell only, so a CODEX_REVIEW_MAX_DIFF_LINES
    # the developer's or CI's shell happens to export cannot silently swap out the default/pinned
    # budget these rows assume — process env otherwise wins over .env per hooks/lib/load-env.js.
    (cd "$repo" && unset CODEX_REVIEW_MAX_DIFF_LINES && PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" "$@" 2>/dev/null) || true
}

# A repository whose `git diff main...HEAD` is EXACTLY <target> lines by `wc -l` — the same
# measurement the script performs. The per-file diff overhead (the `diff --git`, mode, index,
# ---/+++ and @@ lines) is measured from a probe commit rather than hard-coded, because it
# varies with git version and config, and then the file is amended to the required length.
y_make_exact_repo() { # <name> <target-lines> ; prints the repo path, or "" on failure
    local name="$1" target="$2" repo probe overhead k actual
    repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$repo/.git/no-such-hooks"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    git -C "$repo" checkout -q -b "feature-$name"

    awk 'BEGIN { for (i = 0; i < 100; i++) print "generated line " i }' > "$repo/exact.txt"
    git -C "$repo" add exact.txt
    git -C "$repo" commit -q -m "probe"
    probe="$(git -C "$repo" diff "main...HEAD" | wc -l | tr -d '[:space:]')"
    overhead=$((probe - 100))
    k=$((target - overhead))
    if [ "$k" -lt 1 ]; then printf '%s' ""; return 0; fi
    awk -v n="$k" 'BEGIN { for (i = 0; i < n; i++) print "generated line " i }' > "$repo/exact.txt"
    git -C "$repo" add exact.txt
    git -C "$repo" commit -q --amend -m "exact $target"
    actual="$(git -C "$repo" diff "main...HEAD" | wc -l | tr -d '[:space:]')"
    if [ "$actual" != "$target" ]; then printf '%s' ""; return 0; fi
    printf '%s' "$repo"
}

# --- Y1/Y2: the cap is 5000 lines. AT the cap is not over it; one line past it is.
y_install_quiet_mock
Y_AT_REPO="$(y_make_exact_repo exact-5000 5000)"
Y_OVER_REPO="$(y_make_exact_repo exact-5001 5001)"
