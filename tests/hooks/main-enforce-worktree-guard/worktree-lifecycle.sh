# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, windows, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/refactor-branching-complete-rename-worktree.sh (all cases).
# Cases: WL-1..WL-14, NI-1..NI-7.
# Worktree lifecycle commands are the one write-shaped family the guard must
# ALLOW from the main checkout — creating the linked worktree is how a session
# escapes it. The allow is target-scoped: pointing outside the repo passes,
# inside does not, and any shell chaining voids it. Assertions compare stdout to
# exactly `{}` so an approve-with-extras reply cannot green it by another path.

WL_REPO="$(setup_main_checkout "wl-repo")"
WL_EXT_PATH="$TMPDIR_BASE/wl-worktrees/my-task/repo"
WL_INREPO_PATH="$WL_REPO/subdir"

# AGENTS_CONFIG_DIR points at the fixture repo so New-Item / mkdir targets
# resolve against it rather than the real agents checkout.
wl_run_hook() {
    run_bash_guard "$1" "${2:-$WL_REPO}" ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=$WL_REPO"
}
wl_is_allowed() { [ "$(wl_run_hook "$1" "${2:-}")" = "{}" ]; }
wl_is_blocked() { [ "$(wl_run_hook "$1" "${2:-}")" != "{}" ]; }

# Windows-style path (C:/foo, C:\foo) → Git Bash style (/c/foo). Empty when the
# input is not drive-rooted.
wl_to_unix_style_path() {
    local p="$1"
    if [[ "$p" =~ ^([A-Za-z]):[/\\] ]]; then
        local drive_lower rest
        drive_lower="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        rest="${p#?:}"; rest="${rest//\\/\/}"; rest="${rest#/}"
        echo "/$drive_lower/$rest"
    fi
}

echo "=== Worktree lifecycle (git worktree / New-Item) ==="

if wl_is_allowed "git -C \"$WL_REPO\" worktree add \"$WL_EXT_PATH\" -b feature/x"; then
    pass "WL-1. git worktree add <ext-path> -b branch — allowed from main worktree"
else
    fail "WL-1. git worktree add <ext-path> -b branch — should be allowed"
fi

if wl_is_allowed "git -C \"$WL_REPO\" worktree add -b feature/x \"$WL_EXT_PATH\""; then
    pass "WL-2. git worktree add -b branch <ext-path> (flag-first order) — allowed"
else
    fail "WL-2. git worktree add -b branch <ext-path> — should be allowed"
fi

if wl_is_allowed "git -C \"$WL_REPO\" worktree add --orphan newbranch \"$WL_EXT_PATH\""; then
    pass "WL-3. git worktree add --orphan branch <ext-path> — allowed"
else
    fail "WL-3. git worktree add --orphan branch <ext-path> — should be allowed"
fi

if wl_is_allowed "git -C \"$WL_REPO\" worktree add --orphan=newbranch \"$WL_EXT_PATH\""; then
    pass "WL-4. git worktree add --orphan=branch <ext-path> (= syntax) — allowed"
else
    fail "WL-4. git worktree add --orphan=branch <ext-path> — should be allowed"
fi

if wl_is_allowed "git -C \"$WL_REPO\" worktree add -- \"$WL_EXT_PATH\""; then
    pass "WL-5. git worktree add -- <ext-path> (end-of-options) — allowed"
else
    fail "WL-5. git worktree add -- <ext-path> — should be allowed"
fi

if wl_is_blocked "git -C \"$WL_REPO\" worktree add \"$WL_INREPO_PATH\" -b feature/x"; then
    pass "WL-6. git worktree add <in-repo-path> — blocked (target inside main repo)"
else
    fail "WL-6. git worktree add <in-repo-path> — should be blocked"
fi

if wl_is_allowed "git -C \"$WL_REPO\" worktree remove \"$WL_EXT_PATH\""; then
    pass "WL-7. git worktree remove <path> — allowed from main worktree"
else
    fail "WL-7. git worktree remove — should be allowed"
fi

if wl_is_allowed "git -C \"$WL_REPO\" worktree prune"; then
    pass "WL-8. git worktree prune — allowed from main worktree"
else
    fail "WL-8. git worktree prune — should be allowed"
fi

if wl_is_blocked "git -C \"$WL_REPO\" worktree add \"$WL_EXT_PATH\" -b feature/x && git commit -m x"; then
    pass "WL-9. git worktree add ... && git commit — blocked (shell chaining)"
else
    fail "WL-9. chained command should be blocked"
fi

if wl_is_blocked "git -C \"$WL_REPO\" worktree add \"$WL_EXT_PATH\"; rm -rf /"; then
    pass "WL-10. git worktree add ...; rm -rf — blocked (semicolon chaining)"
else
    fail "WL-10. semicolon-chained command should be blocked"
fi

# WL-11 pairs with WL-10: a semicolon that survives quote-stripping is chaining,
# one that does not is just an odd path.
WL_QUOTED_PATH="$TMPDIR_BASE/wl-wt-safe"
if wl_is_allowed "git -C \"$WL_REPO\" worktree add \"$WL_QUOTED_PATH\" -b feature/y"; then
    pass "WL-11. Quoted external path — allowed (not chaining)"
else
    fail "WL-11. Quoted external path should be allowed"
fi

# Regression guard: `list` must not be swept up by the worktree-write pattern.
if wl_is_allowed "git -C \"$WL_REPO\" worktree list --porcelain"; then
    pass "WL-12. git worktree list — allowed (read-only, not blocked by enforce-worktree)"
else
    fail "WL-12. git worktree list should be allowed (read-only)"
fi

# WL-13/WL-14 are Git-Bash-only: without normalizeCwd, path.resolve("/c/git/foo")
# on Windows misresolves to C:\c\git\foo and the comparison silently inverts.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        WL_UNIX_REPO="$(wl_to_unix_style_path "$WL_REPO")"
        WL_UNIX_EXT="$(wl_to_unix_style_path "$WL_EXT_PATH")"
        WL_UNIX_INREPO="$(wl_to_unix_style_path "$WL_INREPO_PATH")"

        if [ -n "$WL_UNIX_REPO" ] && [ -n "$WL_UNIX_EXT" ]; then
            if wl_is_allowed "git -C \"$WL_UNIX_REPO\" worktree add \"$WL_UNIX_EXT\" -b feature/x" "$WL_REPO"; then
                pass "WL-13. git worktree add with POSIX-drive paths (ext) — allowed"
            else
                fail "WL-13. POSIX-drive external path should be allowed"
            fi
        else
            skip "WL-13. skipped (could not derive POSIX paths)"
        fi

        if [ -n "$WL_UNIX_REPO" ] && [ -n "$WL_UNIX_INREPO" ]; then
            if wl_is_blocked "git -C \"$WL_UNIX_REPO\" worktree add \"$WL_UNIX_INREPO\" -b feature/x" "$WL_REPO"; then
                pass "WL-14. git worktree add with POSIX-drive in-repo path — blocked"
            else
                fail "WL-14. POSIX-drive in-repo path should be blocked (pre-fix bug)"
            fi
        else
            skip "WL-14. skipped (could not derive POSIX paths)"
        fi
        ;;
    *)
        skip "WL-13. skipped on non-Windows (POSIX drive paths are Git Bash-specific)"
        skip "WL-14. skipped on non-Windows (POSIX drive paths are Git Bash-specific)"
        ;;
esac

# The New-Item branch only resolves a target against the repo root when the
# path is drive-rooted AND fully backslashed — the origin got that for free by
# keeping TMPDIR_BASE in raw Windows form. The shared base is slash-form
# because the other fragments feed it into JSON payloads, so convert here.
WL_WIN_BASE="${TMPDIR_BASE//\//\\}"
WL_WIN_REPO="${WL_REPO//\//\\}"

WL_NI_EXT="$WL_WIN_BASE\\wl-worktrees\\my-task"
if wl_is_allowed "New-Item -ItemType Directory -Force -Path \"$WL_NI_EXT\""; then
    pass "NI-1. New-Item -ItemType Directory -Path <ext> — allowed"
else
    fail "NI-1. New-Item -ItemType Directory -Path <ext> — should be allowed"
fi

WL_NI_INREPO="${WL_WIN_REPO}\\subdir"
if wl_is_blocked "New-Item -ItemType Directory -Path \"$WL_NI_INREPO\""; then
    pass "NI-2. New-Item -ItemType Directory -Path <in-repo-path> — blocked"
else
    fail "NI-2. New-Item with in-repo path should be blocked"
fi

if wl_is_allowed "New-Item -ItemType Directory \"$TMPDIR_BASE/wl-positional\""; then
    pass "NI-3. New-Item -ItemType Directory <positional ext-path> — allowed"
else
    fail "NI-3. New-Item positional external path should be allowed"
fi

if wl_is_blocked "New-Item -ItemType Directory \"$WL_REPO/evil\""; then
    pass "NI-4. New-Item -ItemType Directory <positional in-repo-path> — blocked"
else
    fail "NI-4. New-Item positional in-repo path should be blocked"
fi

# Only Directory is in the lifecycle allow — File is an ordinary write.
if wl_is_blocked "New-Item -ItemType File -Path \"$WL_NI_EXT\\file.txt\""; then
    pass "NI-5. New-Item -ItemType File — blocked (only Directory is allowed)"
else
    fail "NI-5. New-Item -ItemType File should be blocked"
fi

if wl_is_blocked "New-Item -ItemType Directory"; then
    pass "NI-6. New-Item -ItemType Directory (no path) — blocked (fail-closed)"
else
    fail "NI-6. New-Item with no path should be blocked (fail-closed)"
fi

if wl_is_blocked "New-Item -ItemType Directory -Path \"$WL_NI_EXT\"; Remove-Item -Recurse \"$WL_REPO\""; then
    pass "NI-7. New-Item chained with Remove-Item — blocked"
else
    fail "NI-7. Chained New-Item should be blocked"
fi

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "worktree-lifecycle.sh"
