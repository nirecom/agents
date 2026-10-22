# tests/bin/fix-2025-safe-state-path/drift-tag-load.sh
# #2529 T8-7 (load half): bin/lib/concern-ledger.sh sources the drift-tag module
# between core.sh (whose cl_reject calls it) and reduce.sh, with the same
# fail-closed source block as its siblings. A tree whose drift-tag.sh is missing
# or will not parse refuses to run half-loaded. Sourced by fix-2025-safe-state-path.sh.

DT_LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
dt_line() { grep -n -F -- "source \"\$CL_LIB_DIR/$1\"" "$DT_LIB" 2>/dev/null | head -n1 | cut -d: -f1; }
DT_CORE="$(dt_line core.sh)"; DT_DRIFT="$(dt_line drift-tag.sh)"; DT_REDUCE="$(dt_line reduce.sh)"
if [ -n "$DT_DRIFT" ] && [ -n "$DT_CORE" ] && [ -n "$DT_REDUCE" ] \
    && [ "$DT_CORE" -lt "$DT_DRIFT" ] && [ "$DT_DRIFT" -lt "$DT_REDUCE" ]; then
    pass "drift-tag: sourced after core.sh and before reduce.sh"
else
    fail "drift-tag: sourced after core.sh and before reduce.sh (core=$DT_CORE drift=$DT_DRIFT reduce=$DT_REDUCE)"
fi
assert_eq "drift-tag: the source line sits in an if-not fail-closed block" "yes" \
    "$(grep -qF -- 'if ! source "$CL_LIB_DIR/drift-tag.sh"; then' "$DT_LIB" && printf yes || printf no)"

# dt_tree <name> — a working copy of bin/ and hooks/ (the CLI resolves sessions through hooks/).
dt_tree() {
    local d="$TMPDIR_BASE/$1"
    rm -rf "$d"
    mkdir -p "$d/rules" "$d/skills/review-code-security"
    cp -r "$AGENTS_ROOT/skills/review-code-security/scripts" "$d/skills/review-code-security/scripts"
    cp -r "$AGENTS_ROOT/bin" "$d/bin"
    cp -r "$AGENTS_ROOT/hooks" "$d/hooks"
    echo "# core principles stub" > "$d/rules/core-principles.md"
    printf '%s' "$d"
}
# dt_run <tree> — tally on an empty plans dir; sets DT_RC / DT_OUT / DT_ERR.
dt_run() {
    local p="$TMPDIR_BASE/dt-plans"
    mkdir -p "$p"
    DT_RC=0
    run_with_timeout 120 bash "$1/bin/concern-ledger" tally --plans-dir "$p" --session-id s1 --format detail-plan \
        >"$TMPDIR_BASE/.dt-out" 2>"$TMPDIR_BASE/.dt-err" || DT_RC=$?
    DT_OUT="$(cat "$TMPDIR_BASE/.dt-out")"; DT_ERR="$(cat "$TMPDIR_BASE/.dt-err")"
}

for mode in hidden broken; do
    d="$(dt_tree "dt-$mode")"
    m="$d/bin/lib/concern-ledger/drift-tag.sh"
    if [ "$mode" = hidden ]; then
        if [ -f "$m" ]; then mv "$m" "$m.hidden"; else fail "drift-tag ($mode): the module exists to be removed"; fi
    else
        printf 'this is( not ) valid shell {{{\n' > "$m"
    fi
    dt_run "$d"
    assert_eq "drift-tag ($mode): the CLI reports it could not produce an artifact" "5" "$DT_RC"
    assert_eq "drift-tag ($mode): names the module" "yes" \
        "$(printf '%s' "$DT_ERR" | grep -qF 'concern-ledger/drift-tag.sh — refusing' && printf yes || printf no)"
    assert_eq "drift-tag ($mode): refuses to run half-loaded" "yes" \
        "$(printf '%s' "$DT_ERR" | grep -qF 'refusing to run half-loaded' && printf yes || printf no)"
    assert_eq "drift-tag ($mode): nothing on stdout" "" "$DT_OUT"
    rm -rf "$d"
done
