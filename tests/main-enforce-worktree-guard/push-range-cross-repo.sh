# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, git, cross-repo, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-enforce-worktree-push-fix-range.sh (cross-repo cases, #653).
# Cases: the `Fix 1 (cross-repo): …` family. Same-repo: push-range-basic.sh.

# Same function as push-range-basic.sh, different caller shape: CWD is repo A
# and the command is `git -C <B> push`. The range must be evaluated against B,
# not A — a resolver that silently falls back to CWD would let B's src commits
# through.

# Every case sets ENFORCE_WORKTREE_ADDITIONAL_REPOS=<B>. Without it B is outside
# sessionRoots, the hook early-allows at the `git -C` scope check, and the BLOCK
# cases would pass for the wrong reason.

# Fragment-local helpers carry an `xr_` prefix: fragments share one shell.

XR_EXCLUDE="ENFORCE_WORKTREE_EXCLUDE=**/docs/**"

# A is the cwd side (agents role), B the push target (my-specs-repo role).
# Echoes "<A-raw>\t<B-raw>".
xr_setup_pair() {
    local name="$1" b_mode="${2:-}"
    local a b
    a="$(setup_repo_with_remote "${name}-A")"
    b="$(setup_repo_with_remote "${name}-B" $b_mode)"
    printf '%s\t%s\n' "$a" "$b"
}

xr_commit() {
    local repo="$1" path="$2" msg="$3"
    mkdir -p "$(dirname "$repo/$path")"
    echo "x" > "$repo/$path"
    git -C "$repo" add "$path"
    git -C "$repo" commit -q -m "$msg"
}

xr_run() {
    local a="$1" b="$2" cmd="$3"
    local b_node; b_node="$(to_node_path "$b")"
    run_bash_guard "$cmd" "$a" ENFORCE_WORKTREE=on "$XR_EXCLUDE" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$b_node"
}

echo "=== Fix 1 (cross-repo): git -C <B> push ==="

IFS=$'\t' read -r xr_a xr_b <<< "$(xr_setup_pair "xr-bare")"
xr_commit "$xr_b" "docs/a.md" "doc a"
xr_out="$(xr_run "$xr_a" "$xr_b" "git -C \"$(to_node_path "$xr_b")\" push")"
assert_decision allow "$xr_out" \
    "Fix 1 (cross-repo): 'git -C <B> push' docs-only allows" \
    "Fix 1 (cross-repo): 'git -C <B> push' docs-only should allow"

IFS=$'\t' read -r xr_a xr_b <<< "$(xr_setup_pair "xr-explicit")"
xr_commit "$xr_b" "docs/a.md" "doc a"
xr_out="$(xr_run "$xr_a" "$xr_b" "git -C \"$(to_node_path "$xr_b")\" push origin main")"
assert_decision allow "$xr_out" \
    "Fix 1 (cross-repo): 'git -C <B> push origin main' docs-only allows" \
    "Fix 1 (cross-repo): 'git -C <B> push origin main' docs-only should allow"

IFS=$'\t' read -r xr_a xr_b <<< "$(xr_setup_pair "xr-mixed")"
xr_commit "$xr_b" "docs/a.md" "doc a"
xr_commit "$xr_b" "src/main.js" "src code"
xr_out="$(xr_run "$xr_a" "$xr_b" "git -C \"$(to_node_path "$xr_b")\" push")"
assert_decision block "$xr_out" \
    "Fix 1 (cross-repo): mixed docs+src commits blocks" \
    "Fix 1 (cross-repo): mixed docs+src commits should block"

# B has a remote but no tracking ref — the range is unresolvable, so fail-closed
# must fire on the cross-repo path too, not only the same-repo one.
IFS=$'\t' read -r xr_a xr_b <<< "$(xr_setup_pair "xr-noup" --no-upstream)"
xr_commit "$xr_b" "docs/a.md" "doc a"
xr_out="$(xr_run "$xr_a" "$xr_b" "git -C \"$(to_node_path "$xr_b")\" push")"
assert_decision block "$xr_out" \
    "Fix 1 (cross-repo): no-upstream push blocks (fail-closed)" \
    "Fix 1 (cross-repo): no-upstream push should block"
