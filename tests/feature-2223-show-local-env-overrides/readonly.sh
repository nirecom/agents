#!/usr/bin/env bash
# tests/feature-2223-show-local-env-overrides/readonly.sh
# Tests: bin/show-local-env-overrides, hooks/lib/load-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, idempotency, cli, pwsh-not-required
# Case file for tests/feature-2223-show-local-env-overrides.sh — sourced from it,
# never run standalone (it uses that file's helpers, fixtures and counters).
# Holds the read-only contract: idempotency means "same result WITHOUT side
# effects", and this tool runs inside a repository the machine did not
# necessarily author and spawns git there.
# TL3 gap: same as the parent's.
SHOW_LOCAL_ENV_READONLY_CASES_LOADED=1

# tree_digest <dir> — content-and-inventory digest. Every path under the dir plus
# a checksum of every regular file, so a rewritten byte and a created or deleted
# entry both show up. .git internals are excluded: git's own index refresh is not
# a side effect of this CLI, and `git status --porcelain` covers that half.
tree_digest() {
    local root="$1"
    [ -d "$root/.git" ] && printf 'GIT-ENTRY present\n'
    (
        cd "$root" 2>/dev/null || exit 0
        find . -path ./.git -prune -o -print 2>/dev/null | LC_ALL=C sort |
        while IFS= read -r p; do
            if [ -f "$p" ]; then printf '%s F %s\n' "$p" "$(cksum < "$p")"
            elif [ -d "$p" ]; then printf '%s D\n' "$p"
            else printf '%s O\n' "$p"; fi
        done
    )
}

if ! command -v git >/dev/null 2>&1; then
    fail "T2223S-readonly — git unavailable; the spawn whose side effects this pins cannot run"
else
    new_git_case readonly 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' \
      'PROJECT_NFR=SENT2223-readonly-nfr-3d8b47@NL@ENFORCE_WORKTREE=SENT2223-readonly-blocked-ac9152'
    READONLY_ADD_RC=0
    git -C "$CASE_ROOT" add -- "$LOCAL_ENV_BASENAME" >/dev/null 2>&1 || READONLY_ADD_RC=$?
    assert_eq "T2223S-readonly-fixture-staged" "0" "$READONLY_ADD_RC"

    RO_ROOT_BEFORE="$(tree_digest "$CASE_ROOT")"
    RO_CFG_BEFORE="$(tree_digest "$CASE_CFG")"
    RO_STATUS_BEFORE="$(git -C "$CASE_ROOT" status --porcelain 2>/dev/null)"
    # A digest that came back empty would make all three comparisons vacuous.
    if [ -n "$RO_ROOT_BEFORE" ] && [ -n "$RO_CFG_BEFORE" ] && [ -n "$RO_STATUS_BEFORE" ]; then
        pass "T2223S-readonly-baseline-non-empty"
    else
        fail "T2223S-readonly-baseline-non-empty — an empty baseline proves nothing"
    fi

    run_cli --repo-root "$CASE_ROOT_NODE"
    RO_FIRST_OUT="$CLI_OUT"
    RO_FIRST_ERR="$CLI_ERR"
    assert_eq "T2223S-readonly-first-run-exit-0" "0" "$CLI_RC"
    run_cli --repo-root "$CASE_ROOT_NODE"
    assert_eq "T2223S-readonly-second-run-exit-0" "0" "$CLI_RC"

    assert_eq "T2223S-readonly-stdout-stable-across-runs" "$RO_FIRST_OUT" "$CLI_OUT"
    # The stderr counterpart of T2223S-sorted-stable-across-runs: the tracked
    # warning is a second output path and it must repeat identically.
    assert_eq "T2223S-readonly-stderr-stable-across-runs" "$RO_FIRST_ERR" "$CLI_ERR"
    assert_contains "T2223S-readonly-stderr-non-empty" "$RO_FIRST_ERR" "$WARN_TEXT"

    assert_eq "T2223S-readonly-project-tree-unchanged" \
      "$RO_ROOT_BEFORE" "$(tree_digest "$CASE_ROOT")"
    assert_eq "T2223S-readonly-git-status-unchanged" \
      "$RO_STATUS_BEFORE" "$(git -C "$CASE_ROOT" status --porcelain 2>/dev/null)"
    # The global .env is read, never rewritten.
    assert_eq "T2223S-readonly-config-dir-unchanged" \
      "$RO_CFG_BEFORE" "$(tree_digest "$CASE_CFG")"
fi
