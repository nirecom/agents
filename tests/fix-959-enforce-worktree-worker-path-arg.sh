#!/bin/bash
# tests/fix-959-enforce-worktree-worker-path-arg.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/standard.js
# Tags: worktree, enforce, hook, security, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
#   - Real worker agent sessions where AGENTS_CONFIG_DIR contains actual agent scripts
#   - Cross-platform path normalization edge cases in live Claude Code sessions
#   - Hook invocation ordering when multiple allow predicates contest the same command
# Closest-to-action mitigation: gap is covered at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Class 3 (#959): worker scripts (bash "<acd>/bin/check-unstaged-tracked.sh" ...)
# launched from main-worktree CWD with log redirects to a linked worktree are
# false-blocked because the hook sees the write target and applies main-worktree
# enforcement. The fix adds isAllowedWorkerScriptInvocation(cmd, repoRoot)
# recognizing sanctioned worker scripts via `bash "<double-quoted-path>"` identity
# matching + collectBashWriteTargets() + worktree registry validation.
#
# Drive surface (full hook):
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && AGENTS_CONFIG_DIR=<fake-acd> node hooks/enforce-worktree.js)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

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

# Tempdir base, cleaned up at exit. Node gives a POSIX-style path on Windows.
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix959-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Existence gate.
if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_bash_payload() {
    local cmd="$1"
    local q; q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

# Run the guard with cwd set to <main-worktree>.
# Returns: 0 = ALLOW, 1 = BLOCK, 2 = CRASH.
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1"; shift
    local main_wt="$1"; shift
    # Remaining args are extra env vars (KEY=VAL form), e.g. AGENTS_CONFIG_DIR=...
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        -C "$main_wt" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$main_wt" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        return 2
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# `env -C` is a GNU coreutils extension (>=8.28). Fallback: subshell `cd` + env.
if ! env -C "$TMPDIR_BASE" true 2>/dev/null; then
    run_guard() {
        local payload="$1"; shift
        local main_wt="$1"; shift
        GUARD_RC=0
        GUARD_OUT="$(cd "$main_wt" && printf '%s' "$payload" | run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE \
            "ENFORCE_WORKTREE=on" \
            "ENFORCE_WORKTREE_EXTRA_REPOS=$main_wt" \
            "$@" \
            node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
        if [ "$GUARD_RC" -ne 0 ]; then
            return 2
        fi
        if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
            return 1
        fi
        return 0
    }
fi

assert_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; out: $GUARD_OUT)" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

# ----------------------------------------------------------------------------
# Fixture builders
# ----------------------------------------------------------------------------

# Initialize a minimal main worktree. Echoes cygpath-normalized path.
setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    mkdir -p "$repo/docs/history"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Add a linked worktree under <main-worktree>/.wt/<name>. Echoes its path.
add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt_path"
    else
        echo "$wt_path"
    fi
}

# Create a fake AGENTS_CONFIG_DIR with all sanctioned worker scripts as empty
# files. Echoes the cygpath-normalized path.
setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues"
    touch "$d/bin/check-unstaged-tracked.sh"
    touch "$d/bin/probe-remote-bootstrap.sh"
    touch "$d/bin/issue-close-gate.sh"
    touch "$d/bin/github-issues/issue-close-stage-triage.sh"
    touch "$d/bin/github-issues/parent-body-update.sh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# ============================================================================
# F959 series — isAllowedWorkerScriptInvocation (Class 3)
#
# Setup contract: every case registers BOTH the main worktree and the linked
# worktree in session scope (ENFORCE_WORKTREE_EXTRA_REPOS="$repo;$linked"). This
# is what reproduces the #959 false-block: with the linked worktree in scope, a
# log-redirect target inside it resolves in-scope, and because the command runs
# from the main-worktree CWD the main-checkout guard fires. Without the linked
# worktree in scope the target would resolve out-of-scope and be allowed by the
# universal-target rule — never exercising the new predicate at all.
# ============================================================================

# Case 1 — ALLOW: sanctioned script + log redirect to registered linked worktree.
# RED before Class 3 fix (currently BLOCKed by the main-checkout guard).
test_F959_1_allow_sanctioned_linked_log() {
    local repo; repo="$(setup_main_worktree "f959-1")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw1" "feature/f959-lw1")"
    local fake_acd; fake_acd="$(setup_fake_acd "1")"
    mkdir -p "$linked/artifacts"
    local log_path="$linked/artifacts/test.log"
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_allow "F959-1: sanctioned script + linked-wt log → ALLOW (fix #959 Class 3)" "$rc"
}

# Case 2 — ALLOW: sanctioned script + no redirect (no write targets extracted).
# A worker invocation that writes nothing has no in-scope write target, so the
# command is already allowed (no-target → allow). GREEN before AND after fix —
# pins that the fix does not regress the zero-write-target happy path.
test_F959_2_allow_sanctioned_no_redirect() {
    local repo; repo="$(setup_main_worktree "f959-2")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw2" "feature/f959-lw2")"
    local fake_acd; fake_acd="$(setup_fake_acd "2")"
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_allow "F959-2: sanctioned script + no redirect (targets=null) → ALLOW (fix #959 Class 3)" "$rc"
}

# Case 3 — BLOCK: sanctioned script + log redirect to the MAIN worktree.
# A log target under the main worktree resolves to the main repo root (in scope)
# and must stay blocked — the fix allows only registered-linked-worktree targets.
# GREEN before AND after fix (main-wt write target, fail-closed).
test_F959_3_block_sanctioned_main_log() {
    local repo; repo="$(setup_main_worktree "f959-3")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw3" "feature/f959-lw3")"
    local fake_acd; fake_acd="$(setup_fake_acd "3")"
    local log_path="$repo/bad.log"
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_block "F959-3: sanctioned script + main-wt log → BLOCK (main-wt write target, Class 3 fail-closed)" "$rc"
}

# Case 4 — BLOCK: sanctioned script + log under an unregistered `.wt/ghost` dir.
# A path under the main worktree tree that was never `git worktree add`-ed
# resolves to the MAIN repo root (git treats it as part of the main worktree),
# so it is in scope but NOT a registered linked worktree. The predicate's
# registry validation must reject it. GREEN before AND after fix.
test_F959_4_block_unregistered_log() {
    local repo; repo="$(setup_main_worktree "f959-4")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw4" "feature/f959-lw4")"
    local fake_acd; fake_acd="$(setup_fake_acd "4")"
    mkdir -p "$repo/.wt/ghost"   # looks like a worktree path but is unregistered
    local log_path="$repo/.wt/ghost/test.log"
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_block "F959-4: sanctioned script + unregistered .wt/ghost log → BLOCK (registry mismatch, Class 3 fail-closed)" "$rc"
}

# Case 5 — BLOCK: non-sanctioned script (identity gate rejects).
# GREEN before AND after fix (no allow path for an unknown script).
test_F959_5_block_non_sanctioned_script() {
    local repo; repo="$(setup_main_worktree "f959-5")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw5" "feature/f959-lw5")"
    local fake_acd; fake_acd="$(setup_fake_acd "5")"
    mkdir -p "$fake_acd/bin"
    touch "$fake_acd/bin/some-other.sh"  # not in sanctioned set
    mkdir -p "$linked/artifacts"
    local log_path="$linked/artifacts/test.log"
    local cmd; cmd="bash \"$fake_acd/bin/some-other.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_block "F959-5: non-sanctioned script + linked-wt log → BLOCK (identity gate rejects, Class 3)" "$rc"
}

# Case 6 — BLOCK: log-basename-only match (no `bash <script>` identity).
# Proves the predicate anchors on script identity, not on the log filename.
# GREEN before AND after fix.
test_F959_6_block_log_basename_only() {
    local repo; repo="$(setup_main_worktree "f959-6")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw6" "feature/f959-lw6")"
    local fake_acd; fake_acd="$(setup_fake_acd "6")"
    local log_path="$linked/20260620-202454-commit-push-worker.log"
    local cmd="echo done > \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_block "F959-6: echo to *-worker.log (no bash identity) → BLOCK (identity anchor test, Class 3)" "$rc"
}

# Case 7 — BLOCK: sanctioned script + linked-wt log + trailing && (chaining).
# GREEN before AND after fix (chaining gate catches &&).
test_F959_7_block_trailing_chaining() {
    local repo; repo="$(setup_main_worktree "f959-7")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw7" "feature/f959-lw7")"
    local fake_acd; fake_acd="$(setup_fake_acd "7")"
    mkdir -p "$linked/artifacts"
    local log_path="$linked/artifacts/test.log"
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\" &> \"$log_path\" && rm -rf /"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_block "F959-7: sanctioned script + linked-wt log + && chaining → BLOCK (argTail chaining gate, Class 3)" "$rc"
}

# Case 8 — BLOCK: sanctioned script + bare & backgrounding (write-classified, no redirect).
# Security pin: `bash "<sanctioned>" "$repo" & git push origin main` backgrounds
# the sanctioned script and runs `git push` in the foreground — no file redirect
# so collectBashWriteTargets returns targets: null. Before the fix the bare `&`
# passed the argTail scan and `targets === null` caused `return true` (ALLOW).
# The fix adds `/&(?!>)/` rejection: &> / &>> redirect forms remain allowed.
# `git push` is used because (a) classify() returns "write" for it so the hook
# processes the command, and (b) collectBashWriteTargets returns targets: null
# for it (no file redirect), exposing the targets=null→allow gap.
# GREEN only after the bare-& fix (added by security review).
test_F959_8_block_bare_ampersand_background() {
    local repo; repo="$(setup_main_worktree "f959-8")"
    local linked; linked="$(add_linked_worktree "$repo" "f959-lw8" "feature/f959-lw8")"
    local fake_acd; fake_acd="$(setup_fake_acd "8")"
    # No redirect target: git push is write-classified but has no file write target.
    local cmd; cmd="bash \"$fake_acd/bin/check-unstaged-tracked.sh\" \"$repo\" & git push origin main"
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_EXTRA_REPOS=$repo;$linked" || rc=$?
    assert_block "F959-8: sanctioned script + bare & git push → BLOCK (bare-& security pin, Class 3)" "$rc"
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    test_F959_1_allow_sanctioned_linked_log
    test_F959_2_allow_sanctioned_no_redirect
    test_F959_3_block_sanctioned_main_log
    test_F959_4_block_unregistered_log
    test_F959_5_block_non_sanctioned_script
    test_F959_6_block_log_basename_only
    test_F959_7_block_trailing_chaining
    test_F959_8_block_bare_ampersand_background
}

# 180s outer timeout so a stuck git op cannot wedge the suite.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX959_TEST_INNER:-}" ]; then
        _FIX959_TEST_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
