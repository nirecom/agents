#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Section L - H-1: the marker guard must be LOCATION-INDEPENDENT.
#
# Why this is the highest-value section: enforce-worktree.js is a worktree-
# LOCATION guard. Its tail approves every write that originates from a linked
# worktree on a feature branch, which is the normal working mode for this repo.
# A marker gate that lives only there is therefore inert exactly where real work
# happens: `echo x > <wf>/<sid>.workflow-off` from the linked worktree would forge
# a full-clearance marker with no gate at all. Everything below runs with the
# process CWD inside a REAL linked worktree on a REAL feature branch.
#
# The kind list is DERIVED from hooks/lib/protected-basenames.js at runtime, so a
# marker kind added later is automatically covered here instead of silently
# escaping this matrix (CPR-SSOT).

# run_L_marker_matrix: every marker kind x {bare, .tmp} x {Edit, Write, MultiEdit, Bash}
run_L_marker_matrix() {
    local kind suffix p label

    for kind in $MARKER_KINDS; do
        for suffix in "" ".tmp"; do
            p="$WFDIR/$SID.$kind$suffix"
            label="L1 [$kind$suffix]"

            # Edit / Write: the two everyday file-writing tool shapes.
            assert_block "$label Edit"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Edit "$LINKED_WT" file_path "$p")")"
            assert_block "$label Write" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"
            # MultiEdit via the per-edit shape: the edits[] array is the only
            # place the real target appears (M-1's sibling in this matrix).
            assert_block "$label MultiEdit(edits[])" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_edits_input MultiEdit "$LINKED_WT" file_path "$p")")"
            # Bash: same forgery with no file tool involved at all.
            assert_block "$label Bash-redirect" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
        done
    done

    # The .tmp half above is M-3's marker side: write-then-rename is how the
    # sanctioned writer creates a marker, so an unguarded `.tmp` is a forgery
    # path that only needs a follow-up `mv` the guard never sees.
    pass "L1 marker matrix covered kinds: [$MARKER_KINDS] x {bare,.tmp} x {Edit,Write,MultiEdit,Bash}"
}

# run_L_location_invariance: identical payload, three different process CWDs.
# linked worktree / main worktree / plain non-repo directory must all agree.
# Any divergence here means the verdict is being derived from LOCATION rather
# than from the target path - the exact shape of H-1.
run_L_location_invariance() {
    local p="$WFDIR/$SID.workflow-off"
    local tokp="$WFDIR/$SID.off-clea""rance"
    local where name raw got first=""

    for where in "$LINKED_WT" "$MAIN_WT" "$NONREPO"; do
        case "$where" in
            "$LINKED_WT") name="linked-worktree" ;;
            "$MAIN_WT")   name="main-worktree" ;;
            *)            name="non-repo-dir" ;;
        esac
        assert_block "L2 marker Write from $name"    "$(run_hook_cwd "$where" "$WFDIR" "$(mk_tool_input Write "$where" file_path "$p")")"
        assert_block "L2 marker Bash from $name"     "$(run_hook_cwd "$where" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$where")")"
        assert_block "L2 token Write from $name"     "$(run_hook_cwd "$where" "$WFDIR" "$(mk_tool_input Write "$where" file_path "$tokp")")"

        raw="$(run_hook_cwd "$where" "$WFDIR" "$(mk_tool_input Write "$where" file_path "$p")")"
        got="$(classify "$raw")"
        if [ -z "$first" ]; then first="$got"; else assert_eq "L2 verdict invariant across CWD ($name == first)" "$first" "$got"; fi
    done
}

# run_L_token_suffixes: the OFF-clearance token side of the same matrix, derived
# from OFF_CLEARANCE_TOKEN_SUFFIXES rather than hardcoded (CPR-SSOT). Kept to
# Write + Bash because Edit/MultiEdit share the classifier call proven above.
run_L_token_suffixes() {
    local sfx p
    for sfx in $TOKEN_SUFFIXES; do
        p="$WFDIR/$SID$sfx"
        assert_block "L3 token [$sfx] Write" "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_tool_input Write "$LINKED_WT" file_path "$p")")"
        assert_block "L3 token [$sfx] Bash"  "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "printf 'x' > $p" "$LINKED_WT")")"
    done
    pass "L3 token matrix covered suffixes: [$TOKEN_SUFFIXES]"
}
