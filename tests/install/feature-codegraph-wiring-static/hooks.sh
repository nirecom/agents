# shellcheck shell=bash
# Tests: hooks/post-checkout, hooks/post-merge
# Tags: codegraph, wiring, static, hook-registration, table-driven, TL2, pwsh-not-required, scope:issue-specific
# W4 — git hooks; five properties per hook (CPR-ORTH: post-checkout and post-merge
# are symmetric members and get identical treatment). W4-a ORDER is the highest-value
# assertion here: the existing settings-assembly guard `exit 0`s for every repo
# except the agents main worktree, while a CodeGraph index must be refreshed wherever
# it exists — above all in linked worktrees. Put the sync block after that guard and
# it never runs again, with no error anywhere: the feature dies silently.

echo "=== W4: hook block placement, gate shape, symmetry, and block count ==="

HOOK_GUARD='"$_repo_top" = "$_cfg_dir"'
HOOK_MARKER='BEGIN codegraph sync'
HOOK_END_MARKER='END codegraph sync'
HOOK_GATE='-s "$_repo_top/.codegraph/codegraph.db"'
HOOK_DIRFORM='[ -d "$_repo_top/.codegraph" ]'
DUP_WHY="a second marked block is a second sync execution on every checkout; a mechanical re-apply of ST-16/ST-17 produces exactly this and every presence assertion stays green"

while IFS='|' read -r name rel; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    rel="$(trim "$rel")"
    abs="$AGENTS_DIR/$rel"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "both hooks are edited, not created, by this feature"
        continue
    fi

    m_line="$(first_line_of "$abs" "$HOOK_MARKER")"
    g_line="$(first_line_of "$abs" "$HOOK_GUARD")"
    if [ -z "$m_line" ]; then
        fail "$name-a: $rel has no '$HOOK_MARKER' marker" "the sync block is missing entirely"
    elif [ -z "$g_line" ]; then
        fail "$name-a: $rel has no settings-assembly guard line to order against" "expected a line containing $HOOK_GUARD"
    elif [ "$m_line" -lt "$g_line" ]; then
        pass "$name-a: '$HOOK_MARKER' (L$m_line) precedes the assembly guard (L$g_line) in $rel"
    else
        fail "$name-a: $rel places the sync block at L$m_line, at or after the assembly guard at L$g_line" \
             "that guard exits for every repo but the agents main worktree, so the sync would never run in a linked worktree"
    fi

    if grep -qF -e "$HOOK_GATE" "$abs"; then
        pass "$name-b: $rel gates on a non-empty $HOOK_GATE"
    else
        fail "$name-b: $rel does not gate on $HOOK_GATE" \
             "the cheap -s pre-gate is what keeps Node out of every branch switch in every repo on this machine"
    fi

    if grep -qF -e "$HOOK_DIRFORM" "$abs"; then
        fail "$name-c: $rel gates on the directory form $HOOK_DIRFORM" \
             "an empty .codegraph/ holding only .gitignore would start Node on every checkout; test the db file with -s instead"
    else
        pass "$name-c: $rel does not use the directory-only form $HOOK_DIRFORM"
    fi

    assert_count "$name-d" "$rel" "$HOOK_MARKER" 1 "$DUP_WHY"
    assert_count "$name-e" "$rel" "$HOOK_END_MARKER" 1 "an unbalanced or duplicated END marker breaks the W4-03 block extraction as well as the block itself"
done <<'W4_TABLE'
W4-01 | hooks/post-checkout
W4-02 | hooks/post-merge
W4_TABLE

# W4-03 — symmetry. Extract each hook's marked block and diff them. Per ST-17 the two
# blocks are identical except that post-checkout additionally requires $3 = 1 (branch
# switch); post-merge takes no positional arguments.
extract_block() { sed -n '/BEGIN codegraph sync/,/END codegraph sync/p' "$1" 2>/dev/null; }

PC="$AGENTS_DIR/hooks/post-checkout"
PM="$AGENTS_DIR/hooks/post-merge"
if [ ! -f "$PC" ] || [ ! -f "$PM" ]; then
    fail "W4-03: one or both hooks are absent" "cannot compare the two blocks"
else
    extract_block "$PC" > "$TMPDIR_LOCAL/pc.block"
    extract_block "$PM" > "$TMPDIR_LOCAL/pm.block"
    if [ ! -s "$TMPDIR_LOCAL/pc.block" ] || [ ! -s "$TMPDIR_LOCAL/pm.block" ]; then
        fail "W4-03: at least one hook has no BEGIN/END codegraph sync block" \
             "post-checkout=$(wc -l < "$TMPDIR_LOCAL/pc.block") line(s), post-merge=$(wc -l < "$TMPDIR_LOCAL/pm.block") line(s)"
    else
        DIFF_OUT="$(diff "$TMPDIR_LOCAL/pc.block" "$TMPDIR_LOCAL/pm.block" 2>/dev/null || true)"
        LEFT="$(printf '%s\n' "$DIFF_OUT" | grep -c '^< ' || true)"
        RIGHT="$(printf '%s\n' "$DIFF_OUT" | grep -c '^> ' || true)"
        assert_eq "W4-03a: exactly one differing line on the post-checkout side" "1" "${LEFT:-0}"
        assert_eq "W4-03b: exactly one differing line on the post-merge side" "1" "${RIGHT:-0}"
        L_TXT="$(printf '%s\n' "$DIFF_OUT" | grep -m1 '^< ' || true)"
        R_TXT="$(printf '%s\n' "$DIFF_OUT" | grep -m1 '^> ' || true)"
        if printf '%s' "$L_TXT" | grep -qF -e '${3:-0}'; then
            pass "W4-03c: the post-checkout-only difference is the \$3 branch-switch condition"
        else
            fail "W4-03c: the post-checkout side of the difference is not the \$3 condition" "got: $(trim "${L_TXT#< }")"
        fi
        if [ -n "$R_TXT" ] && ! printf '%s' "$R_TXT" | grep -qF -e '${3:-0}'; then
            pass "W4-03d: the post-merge counterpart carries no \$3 condition"
        else
            fail "W4-03d: the post-merge side still references \$3, or has no counterpart line" "got: $(trim "${R_TXT#> }")"
        fi
    fi
fi
