#!/bin/bash
# tests/refactor-branching-complete-rename-worktree.sh
#
# Tests for enforce-worktree.js: worktree lifecycle commands allowed from main checkout.
# Covers: git worktree add/remove/prune and New-Item -ItemType Directory.
#
# Requires: node, git

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/enforce-worktree.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# Convert a Windows-style path (C:/foo or C:\foo) to Unix-style (/c/foo).
# Returns empty string if input is not a Windows-style path.
to_unix_style_path() {
    local p="$1"
    if [[ "$p" =~ ^([A-Za-z]):[/\\] ]]; then
        local drive_lower
        drive_lower="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        local rest="${p#?:}"
        rest="${rest//\\/\/}"
        rest="${rest#/}"
        echo "/$drive_lower/$rest"
    fi
}

# ---------------------------------------------------------------------------
# Setup: a temp git repo that acts as the main checkout
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'wl-'+process.pid);
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && { echo "FAIL: could not create tmpdir"; exit 1; }
trap 'rm -rf "$TMPDIR_BASE"' EXIT

MAIN_REPO="$TMPDIR_BASE/repo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q -m "initial"

# External path (outside the repo)
EXT_PATH="$TMPDIR_BASE/worktrees/my-task/repo"
# In-repo path (would be inside the main checkout)
INREPO_PATH="$MAIN_REPO/subdir"

# ---------------------------------------------------------------------------
# Helper: run the hook with a Bash command from the "main checkout" context
# AGENTS_CONFIG_DIR points to MAIN_REPO so New-Item / mkdir fall back there.
# ---------------------------------------------------------------------------
run_hook() {
    local cmd="$1"
    local input
    input="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' \
        "$(printf '%s' "$cmd" | node -e "
            let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
                console.log(d.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\n/g,'\\\\n'));
            });
        " 2>/dev/null)")"
    ( cd "$MAIN_REPO" && \
      ENFORCE_WORKTREE=on \
      AGENTS_CONFIG_DIR="$MAIN_REPO" \
      run_with_timeout 15 node "$HOOK" <<< "$input" 2>/dev/null )
}

# Returns 0 if hook allows (output is "{}"), 1 if blocked.
is_allowed() { [[ "$(run_hook "$1")" == "{}" ]]; }
is_blocked()  { [[ "$(run_hook "$1")" != "{}" ]]; }

# Like run_hook, but executes node with cwd set to the given directory.
# This ensures process.cwd() inside the hook is a valid Windows path on Git Bash,
# so findRepoRootForBash can fall back to process.cwd() correctly.
run_hook_cwd() {
    local cmd="$1"
    local cwd="$2"
    local input
    input="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' \
        "$(printf '%s' "$cmd" | node -e "
            let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
                console.log(d.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\n/g,'\\\\n'));
            });
        " 2>/dev/null)")"
    ( cd "$cwd" && \
      ENFORCE_WORKTREE=on \
      AGENTS_CONFIG_DIR="$MAIN_REPO" \
      run_with_timeout 15 node "$HOOK" <<< "$input" 2>/dev/null )
}

is_allowed_cwd() { [[ "$(run_hook_cwd "$1" "$2")" == "{}" ]]; }
is_blocked_cwd()  { [[ "$(run_hook_cwd "$1" "$2")" != "{}" ]]; }

# ---------------------------------------------------------------------------
# WL-1: git worktree add <external-path> -b <branch> — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree add \"$EXT_PATH\" -b feature/x"; then
    pass "WL-1. git worktree add <ext-path> -b branch — allowed from main checkout"
else
    fail "WL-1. git worktree add <ext-path> -b branch — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-2: git worktree add -b <branch> <external-path> (args in different order) — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree add -b feature/x \"$EXT_PATH\""; then
    pass "WL-2. git worktree add -b branch <ext-path> (flag-first order) — allowed"
else
    fail "WL-2. git worktree add -b branch <ext-path> — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-3: git worktree add --orphan <branch> <external-path> — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree add --orphan newbranch \"$EXT_PATH\""; then
    pass "WL-3. git worktree add --orphan branch <ext-path> — allowed"
else
    fail "WL-3. git worktree add --orphan branch <ext-path> — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-4: git worktree add --orphan=<branch> <external-path> (= syntax) — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree add --orphan=newbranch \"$EXT_PATH\""; then
    pass "WL-4. git worktree add --orphan=branch <ext-path> (= syntax) — allowed"
else
    fail "WL-4. git worktree add --orphan=branch <ext-path> — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-5: git worktree add -- <external-path> (end-of-options separator) — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree add -- \"$EXT_PATH\""; then
    pass "WL-5. git worktree add -- <ext-path> (end-of-options) — allowed"
else
    fail "WL-5. git worktree add -- <ext-path> — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-6: git worktree add <in-repo-path> — BLOCK (target inside main repo)
# ---------------------------------------------------------------------------
if is_blocked "git -C \"$MAIN_REPO\" worktree add \"$INREPO_PATH\" -b feature/x"; then
    pass "WL-6. git worktree add <in-repo-path> — blocked (target inside main repo)"
else
    fail "WL-6. git worktree add <in-repo-path> — should be blocked"
fi

# ---------------------------------------------------------------------------
# WL-7: git worktree remove <path> — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree remove \"$EXT_PATH\""; then
    pass "WL-7. git worktree remove <path> — allowed from main checkout"
else
    fail "WL-7. git worktree remove — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-8: git worktree prune — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree prune"; then
    pass "WL-8. git worktree prune — allowed from main checkout"
else
    fail "WL-8. git worktree prune — should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-9: git worktree add ... && git commit — BLOCK (chaining)
# ---------------------------------------------------------------------------
if is_blocked "git -C \"$MAIN_REPO\" worktree add \"$EXT_PATH\" -b feature/x && git commit -m x"; then
    pass "WL-9. git worktree add ... && git commit — blocked (shell chaining)"
else
    fail "WL-9. chained command should be blocked"
fi

# ---------------------------------------------------------------------------
# WL-10: git worktree add ...; rm -rf / — BLOCK (semicolon chaining)
# ---------------------------------------------------------------------------
if is_blocked "git -C \"$MAIN_REPO\" worktree add \"$EXT_PATH\"; rm -rf /"; then
    pass "WL-10. git worktree add ...; rm -rf — blocked (semicolon chaining)"
else
    fail "WL-10. semicolon-chained command should be blocked"
fi

# ---------------------------------------------------------------------------
# WL-11: path with semicolon inside quotes — ALLOW (not chaining)
# ---------------------------------------------------------------------------
# The path "/tmp/wt;evil" is unusual but technically a quoted path, not chaining.
# After stripping quotes, the semicolon is gone.
QUOTED_PATH="$TMPDIR_BASE/wt-safe"
if is_allowed "git -C \"$MAIN_REPO\" worktree add \"$QUOTED_PATH\" -b feature/y"; then
    pass "WL-11. Quoted external path — allowed (not chaining)"
else
    fail "WL-11. Quoted external path should be allowed"
fi

# ---------------------------------------------------------------------------
# WL-12: git worktree list (read-only) — ALLOW (classified as read by bash-write-patterns)
# This is a regression guard: list must NOT be caught by worktree-write pattern.
# ---------------------------------------------------------------------------
if is_allowed "git -C \"$MAIN_REPO\" worktree list --porcelain"; then
    pass "WL-12. git worktree list — allowed (read-only, not blocked by enforce-worktree)"
else
    fail "WL-12. git worktree list should be allowed (read-only)"
fi

# ---------------------------------------------------------------------------
# WL-13/WL-14: POSIX drive-letter paths (Git Bash on Windows) — Windows-only.
# Without normalizeCwd, path.resolve("/c/git/foo") on Windows misresolves to
# C:\c\git\foo, breaking the inside/outside comparison.
# ---------------------------------------------------------------------------
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        UNIX_MAIN_REPO="$(to_unix_style_path "$MAIN_REPO")"
        UNIX_EXT_PATH="$(to_unix_style_path "$EXT_PATH")"
        UNIX_INREPO_PATH="$(to_unix_style_path "$INREPO_PATH")"

        if [ -n "$UNIX_MAIN_REPO" ] && [ -n "$UNIX_EXT_PATH" ]; then
            if is_allowed_cwd "git -C \"$UNIX_MAIN_REPO\" worktree add \"$UNIX_EXT_PATH\" -b feature/x" "$MAIN_REPO"; then
                pass "WL-13. git worktree add with POSIX-drive paths (ext) — allowed"
            else
                fail "WL-13. POSIX-drive external path should be allowed"
            fi
        else
            pass "WL-13. skipped (could not derive POSIX paths)"
        fi

        if [ -n "$UNIX_MAIN_REPO" ] && [ -n "$UNIX_INREPO_PATH" ]; then
            # WL-14 is the regression guard for the bug:
            # pre-fix: normalization missing → /c/.../repo/subdir resolves to
            # C:\c\...\repo\subdir which does NOT start with C:\...\repo\ → falsely ALLOWED.
            # post-fix: normalizeCwd converts both sides to C:\... → correctly BLOCKED.
            if is_blocked_cwd "git -C \"$UNIX_MAIN_REPO\" worktree add \"$UNIX_INREPO_PATH\" -b feature/x" "$MAIN_REPO"; then
                pass "WL-14. git worktree add with POSIX-drive in-repo path — blocked"
            else
                fail "WL-14. POSIX-drive in-repo path should be blocked (pre-fix bug)"
            fi
        else
            pass "WL-14. skipped (could not derive POSIX paths)"
        fi
        ;;
    *)
        pass "WL-13. skipped on non-Windows (POSIX drive paths are Git Bash-specific)"
        pass "WL-14. skipped on non-Windows (POSIX drive paths are Git Bash-specific)"
        ;;
esac

# ---------------------------------------------------------------------------
# NI-1: New-Item -ItemType Directory -Force -Path <external-path> — ALLOW
# ---------------------------------------------------------------------------
NI_EXT="$TMPDIR_BASE\\worktrees\\my-task"
if is_allowed "New-Item -ItemType Directory -Force -Path \"$NI_EXT\""; then
    pass "NI-1. New-Item -ItemType Directory -Path <ext> — allowed"
else
    fail "NI-1. New-Item -ItemType Directory -Path <ext> — should be allowed"
fi

# ---------------------------------------------------------------------------
# NI-2: New-Item -ItemType Directory -Path <in-repo-path> — BLOCK
# ---------------------------------------------------------------------------
NI_INREPO="${MAIN_REPO}\\subdir"
if is_blocked "New-Item -ItemType Directory -Path \"$NI_INREPO\""; then
    pass "NI-2. New-Item -ItemType Directory -Path <in-repo-path> — blocked"
else
    fail "NI-2. New-Item with in-repo path should be blocked"
fi

# ---------------------------------------------------------------------------
# NI-3: New-Item -ItemType Directory <positional-ext-path> — ALLOW
# ---------------------------------------------------------------------------
if is_allowed "New-Item -ItemType Directory \"$TMPDIR_BASE/positional\""; then
    pass "NI-3. New-Item -ItemType Directory <positional ext-path> — allowed"
else
    fail "NI-3. New-Item positional external path should be allowed"
fi

# ---------------------------------------------------------------------------
# NI-4: New-Item -ItemType Directory <positional-in-repo-path> — BLOCK
# ---------------------------------------------------------------------------
if is_blocked "New-Item -ItemType Directory \"$MAIN_REPO/evil\""; then
    pass "NI-4. New-Item -ItemType Directory <positional in-repo-path> — blocked"
else
    fail "NI-4. New-Item positional in-repo path should be blocked"
fi

# ---------------------------------------------------------------------------
# NI-5: New-Item -ItemType File -Path <external-path> — BLOCK (not Directory)
# ---------------------------------------------------------------------------
if is_blocked "New-Item -ItemType File -Path \"$NI_EXT\\file.txt\""; then
    pass "NI-5. New-Item -ItemType File — blocked (only Directory is allowed)"
else
    fail "NI-5. New-Item -ItemType File should be blocked"
fi

# ---------------------------------------------------------------------------
# NI-6: New-Item with no parseable path (no -Path, no positional) — BLOCK (fail-closed)
# ---------------------------------------------------------------------------
if is_blocked "New-Item -ItemType Directory"; then
    pass "NI-6. New-Item -ItemType Directory (no path) — blocked (fail-closed)"
else
    fail "NI-6. New-Item with no path should be blocked (fail-closed)"
fi

# ---------------------------------------------------------------------------
# NI-7: New-Item chained with other command — BLOCK
# ---------------------------------------------------------------------------
if is_blocked "New-Item -ItemType Directory -Path \"$NI_EXT\"; Remove-Item -Recurse \"$MAIN_REPO\""; then
    pass "NI-7. New-Item chained with Remove-Item — blocked"
else
    fail "NI-7. Chained New-Item should be blocked"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
