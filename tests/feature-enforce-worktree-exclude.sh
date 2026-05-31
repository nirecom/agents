#!/bin/bash
# tests/feature-enforce-worktree-exclude.sh
# Tests: hooks/lib/glob-match.js, hooks/pre-commit
# Tags: enforce-worktree-exclude
#
# Integration tests for hooks/pre-commit ENFORCE_WORKTREE_EXCLUDE bypass.
#
# Each test sets up a throwaway main worktree with `core.hooksPath` pointing
# at the agents-repo `hooks/` directory, stages files, and runs `git commit`
# (or invokes `hooks/pre-commit` directly) with various EXCLUDE values.
#
# Skips gracefully when the EXCLUDE feature is not yet implemented in
# hooks/pre-commit (detected by grepping for ENFORCE_WORKTREE_EXCLUDE).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
PRE_COMMIT="${AGENTS_DIR}/hooks/pre-commit"
GLOB_JS="${_AGENTS_DIR_NODE}/hooks/lib/glob-match.js"

if [ ! -f "$PRE_COMMIT" ]; then
    echo "SKIP: hooks/pre-commit not present"
    exit 0
fi

if ! grep -q 'ENFORCE_WORKTREE_EXCLUDE' "$PRE_COMMIT" 2>/dev/null; then
    echo "SKIP: ENFORCE_WORKTREE_EXCLUDE not yet implemented in hooks/pre-commit"
    exit 0
fi

if [ ! -f "$GLOB_JS" ]; then
    echo "SKIP: hooks/lib/glob-match.js not yet implemented"
    exit 0
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'enforce-exclude-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Create a throwaway main worktree (no linked worktree).
# Mirrors the helper used by tests/fix-enforce-worktree-gh-whitelist.sh.
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    # Use the agents-repo pre-commit so we exercise the real hook.
    git -C "$repo" config core.hooksPath "${AGENTS_DIR}/hooks"
    echo "init" > "$repo/README.md"
    # Bootstrap commit must bypass our hook (otherwise main-checkout block fires).
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "initial" >/dev/null 2>&1
    # Switch to a feature branch so the protected-branch block does not fire;
    # the main-checkout block is what we want to exercise (and bypass via
    # EXCLUDE). This mirrors the design where EXCLUDE wraps the same _enforce
    # gate that covers BOTH main-checkout and protected-branch.
    # However, for some test cases we need to remain on main to test the
    # protected-branch path. Default = stay on main; tests opt out as needed.
    echo "$repo"
}

# Run the pre-commit hook directly with the given env vars set.
# Args: cwd [env-VAR=val ...]
# Returns the exit code; stdout+stderr captured into RUN_OUT.
RUN_OUT=""
run_pre_commit() {
    local cwd="$1"; shift
    local rc=0
    RUN_OUT="$(cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 env "$@" bash "$PRE_COMMIT" 2>&1)" || rc=$?
    return $rc
}

# Stage one or more files in the given repo with given content.
# Usage: stage_file <repo> <relpath> <content>
stage_file() {
    local repo="$1" rel="$2" content="$3"
    local full="$repo/$rel"
    mkdir -p "$(dirname "$full")"
    printf '%s\n' "$content" > "$full"
    git -C "$repo" -c core.hooksPath=/dev/null add "$rel" >/dev/null 2>&1
}

# Stage a deletion: remove an existing tracked file and stage the deletion.
stage_deletion() {
    local repo="$1" rel="$2"
    rm -f "$repo/$rel"
    git -C "$repo" -c core.hooksPath=/dev/null add -A "$rel" >/dev/null 2>&1
}

# Add a file to a prior commit (so we can test deletions later).
seed_committed_file() {
    local repo="$1" rel="$2" content="$3"
    local full="$repo/$rel"
    mkdir -p "$(dirname "$full")"
    printf '%s\n' "$content" > "$full"
    git -C "$repo" -c core.hooksPath=/dev/null add "$rel" >/dev/null 2>&1
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null \
        commit -q -m "seed $rel" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Normal: EXCLUDE matches all staged → commit allowed from main
# ─────────────────────────────────────────────────────────────────────────────

test_normal_exclude_matches_all_allows_from_main() {
    local repo; repo="$(setup_main_checkout "ex-allow")"
    stage_file "$repo" "docs/todo.md" "todo entry"
    local pat
    if command -v cygpath >/dev/null 2>&1; then
        pat="$(cygpath -m "$repo")/**/*.md"
    else
        pat="$repo/**/*.md"
    fi
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat"; then
        pass "EXCLUDE matches all staged → pre-commit exits 0 from main"
    else
        fail "EXCLUDE should bypass main-checkout block (out: $RUN_OUT)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Normal: ** glob covers files in subdirs
# ─────────────────────────────────────────────────────────────────────────────

test_normal_globstar_covers_subdirs() {
    local repo; repo="$(setup_main_checkout "ex-globstar")"
    stage_file "$repo" "docs/sub/a.md" "deep"
    stage_file "$repo" "docs/b.md" "shallow"
    local pat
    if command -v cygpath >/dev/null 2>&1; then
        pat="$(cygpath -m "$repo")/**/*.md"
    else
        pat="$repo/**/*.md"
    fi
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat"; then
        pass "** glob covers subdir files → allowed"
    else
        fail "** glob should cover subdir files (out: $RUN_OUT)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Error: partial match (1 of 2 files) → blocked
# ─────────────────────────────────────────────────────────────────────────────

test_error_partial_match_blocks() {
    local repo; repo="$(setup_main_checkout "ex-partial")"
    stage_file "$repo" "docs/todo.md" "ok"
    stage_file "$repo" "src/x.py" "not excluded"
    local pat
    if command -v cygpath >/dev/null 2>&1; then
        pat="$(cygpath -m "$repo")/**/*.md"
    else
        pat="$repo/**/*.md"
    fi
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat"; then
        fail "partial match should block but pre-commit exited 0 (out: $RUN_OUT)"
    else
        pass "partial match (1 of 2 files) → blocked"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Critical: deletion of a non-excluded file is NOT hidden
# (validates the no-`--diff-filter` design — uses ALL staged paths, including
#  deletions, when checking whether EXCLUDE covers everything.)
# ─────────────────────────────────────────────────────────────────────────────

test_critical_deletion_of_non_excluded_blocks() {
    local repo; repo="$(setup_main_checkout "ex-deletion")"
    # Seed a non-excluded file so we can stage its deletion.
    seed_committed_file "$repo" "src/x.py" "must not be silently bypassed"
    # Stage: modify excluded doc + delete non-excluded src file.
    stage_file "$repo" "docs/todo.md" "modified excluded file"
    stage_deletion "$repo" "src/x.py"
    local pat
    if command -v cygpath >/dev/null 2>&1; then
        pat="$(cygpath -m "$repo")/**/*.md"
    else
        pat="$repo/**/*.md"
    fi
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat"; then
        fail "deletion of non-excluded file must NOT be hidden — should block (out: $RUN_OUT)"
    else
        pass "deletion of non-excluded file blocks commit (no --diff-filter bypass)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Edge: EXCLUDE unset → existing behavior unchanged (commit blocked from main)
# ─────────────────────────────────────────────────────────────────────────────

test_edge_exclude_unset_blocks_from_main() {
    local repo; repo="$(setup_main_checkout "ex-unset")"
    stage_file "$repo" "docs/todo.md" "anything"
    if run_pre_commit "$repo" ENFORCE_WORKTREE=on; then
        fail "EXCLUDE unset: main worktree commit should block (out: $RUN_OUT)"
    else
        pass "EXCLUDE unset: existing main-checkout block still fires"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Edge: ENFORCE_WORKTREE=off → EXCLUDE irrelevant (no gate)
# ─────────────────────────────────────────────────────────────────────────────

test_edge_off_mode_no_gate() {
    local repo; repo="$(setup_main_checkout "ex-off")"
    stage_file "$repo" "src/x.py" "anything"
    # EXCLUDE pattern matches NOTHING; with ENFORCE_WORKTREE=off, the gate is
    # disabled entirely, so commit must succeed.
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=off "ENFORCE_WORKTREE_EXCLUDE=/totally/unrelated/**"; then
        pass "ENFORCE_WORKTREE=off: EXCLUDE irrelevant, commit proceeds"
    else
        # Note: pre-commit may still run other checks (private-info scanner).
        # Detect whether the failure is from those checks rather than the
        # ENFORCE_WORKTREE gate by looking at the output.
        if echo "$RUN_OUT" | grep -q "ENFORCE_WORKTREE"; then
            fail "off mode should not trigger ENFORCE_WORKTREE block (out: $RUN_OUT)"
        else
            pass "ENFORCE_WORKTREE=off: gate disabled (other checks may still apply)"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Edge: node missing → fails safely (commit blocked, fail-safe)
# ─────────────────────────────────────────────────────────────────────────────

test_edge_node_missing_fail_safe() {
    local repo; repo="$(setup_main_checkout "ex-no-node")"
    stage_file "$repo" "docs/todo.md" "anything"
    # Construct a PATH that has no `node`. We use an empty dir for PATH so
    # `node` cannot be resolved; the hook itself uses /bin/bash via shebang.
    local empty_dir="$TMPDIR_BASE/empty-path-$$"
    mkdir -p "$empty_dir"
    # Keep a minimal set of system bin dirs for git/grep/etc but exclude any
    # that contain node. Easier: prepend an empty dir and then deliberately
    # break `node` by setting a no-op shim.
    local shim_dir="$TMPDIR_BASE/no-node-shim-$$"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/node" <<'EOF'
#!/bin/sh
echo "node: simulated missing" >&2
exit 127
EOF
    chmod +x "$shim_dir/node"
    local shim_dir_path="$shim_dir"
    if command -v cygpath >/dev/null 2>&1; then
        shim_dir_path="$(cygpath -u "$shim_dir")"
    fi
    local pat
    if command -v cygpath >/dev/null 2>&1; then
        pat="$(cygpath -m "$repo")/**/*.md"
    else
        pat="$repo/**/*.md"
    fi
    # Force shim to be discovered first.
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat" \
        "PATH=$shim_dir_path:$PATH"; then
        fail "node missing: pre-commit must NOT silently bypass (out: $RUN_OUT)"
    else
        pass "node missing: fail-safe — main-checkout block stays in effect"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Security: EXCLUDE with shell metacharacters passed via env, not exec'd
# ─────────────────────────────────────────────────────────────────────────────

test_security_metacharacters_not_exec() {
    local repo; repo="$(setup_main_checkout "ex-sec")"
    stage_file "$repo" "docs/todo.md" "anything"
    local sentinel="$TMPDIR_BASE/exclude-injected-$$"
    rm -rf "$sentinel" 2>/dev/null
    # Shell metacharacters in the EXCLUDE value. If pre-commit passes the
    # value via -e or otherwise eval's it, the sentinel directory will be
    # created.
    local payloads=(
        "/tmp/a;mkdir $sentinel"
        "/tmp/a\$(mkdir $sentinel)"
        "/tmp/a|mkdir $sentinel"
        "/tmp/a\`mkdir $sentinel\`"
    )
    local p
    local saw_any_failure=0
    for p in "${payloads[@]}"; do
        rm -rf "$sentinel" 2>/dev/null
        run_pre_commit "$repo" \
            ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$p" || true
        if [ -e "$sentinel" ]; then
            fail "SECURITY: EXCLUDE metachar '$p' executed"
            saw_any_failure=1
            rm -rf "$sentinel" 2>/dev/null
        fi
    done
    if [ "$saw_any_failure" = "0" ]; then
        pass "EXCLUDE metacharacters never executed (env-passed, not eval'd)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency: same EXCLUDE + staged files → same outcome
# ─────────────────────────────────────────────────────────────────────────────

test_idempotency_same_inputs_same_outcome() {
    local repo; repo="$(setup_main_checkout "ex-idem")"
    stage_file "$repo" "docs/todo.md" "ok"
    local pat
    if command -v cygpath >/dev/null 2>&1; then
        pat="$(cygpath -m "$repo")/**/*.md"
    else
        pat="$repo/**/*.md"
    fi
    local rc1=0 rc2=0
    run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat" || rc1=$?
    local out1="$RUN_OUT"
    run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$pat" || rc2=$?
    local out2="$RUN_OUT"
    if [ "$rc1" = "$rc2" ] && [ "$out1" = "$out2" ]; then
        pass "idempotent: rc and output identical across runs"
    else
        fail "non-idempotent: rc1=$rc1 rc2=$rc2; out diff:\n--1--\n$out1\n--2--\n$out2"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all (overall timeout 120s)
# ─────────────────────────────────────────────────────────────────────────────

run_all() {
    test_normal_exclude_matches_all_allows_from_main
    test_normal_globstar_covers_subdirs
    test_error_partial_match_blocks
    test_critical_deletion_of_non_excluded_blocks
    test_edge_exclude_unset_blocks_from_main
    test_edge_off_mode_no_gate
    test_edge_node_missing_fail_safe
    test_security_metacharacters_not_exec
    test_idempotency_same_inputs_same_outcome
}

if command -v timeout >/dev/null 2>&1; then
    # Re-exec self under a 120s wall-clock timeout when the helper is
    # available. The inner invocation sets a sentinel env var to avoid
    # infinite recursion.
    if [ -z "${_EXCLUDE_TEST_INNER:-}" ]; then
        _EXCLUDE_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
