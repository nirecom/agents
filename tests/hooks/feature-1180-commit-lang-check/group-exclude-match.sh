# tests/feature-1180-commit-lang-check/group-exclude-match.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/lib/path-coverage-match.js, hooks/lib/glob-match.js
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X — A/B: matching semantics, multi-entry lists and awkward path shapes.
# Cases X1..X9, X21, X22, X25. Sourced by group-exclude.sh after
# group-exclude-lib.sh (fixtures, _x_expand, _x_verdict, assert_eq).

# ---------------------------------------------------------------------------
# A/B — matching semantics and multi-entry lists (unit, table-driven)
# ---------------------------------------------------------------------------
if require_sut "Group X (X1..X9, X21..X22)" "$LINT_LIB"; then
    while IFS='|' read -r _xname _xspec _xwant; do
        _xname="${_xname//[[:space:]]/}"
        _xwant="${_xwant//[[:space:]]/}"
        [ -z "$_xname" ] && continue
        case "$_xname" in \#*) continue ;; esac
        # The VALUE keeps the table's padding verbatim (X7 asserts that
        # parseExcludePatterns trims it); only the display label is tidied.
        _xval="$(_x_expand "$_xspec")"
        _xlabel="${_xspec#"${_xspec%%[![:space:]]*}"}"
        _xlabel="${_xlabel%"${_xlabel##*[![:space:]]}"}"
        _xgot="$(_x_verdict "$_xval")"
        assert_eq "$_xname (CODE_LANG_EXCLUDE='$_xlabel')" "$_xwant" "$_xgot"
    done <<'TABLE'
X1  | @ROOT@                                   | empty
X2  | @MISSA@                                  | nonempty
X3  | @ROOTGLOB@                               | empty
X4  | @PARENT@                                 | empty
X4b | @SIBLING@                                | nonempty
X5  | ;;; ;                                    | nonempty
X6  | @MISSA@;@MISSB@;@ROOT@                   | empty
X7  |   ;  @ROOT@  ;;                          | empty
X8  | @MISSA@;@MISSB@;@PARENTGLOB@             | empty
X9  | @MISSA@;@MISSB@;@MISSC@                  | nonempty
X21 | @DUPES@                                  | empty
X22 | @LONGLIST@                               | empty
TABLE
fi

# ---------------------------------------------------------------------------
# B2 — legitimate repo path containing a space and a non-ASCII segment (X25)
# ---------------------------------------------------------------------------
# Distinct from X7 (whitespace AROUND entries, trimmed by parseExcludePatterns)
# and from X24 (a hostile value that must NOT match): here the space and the
# Unicode characters are part of a REAL directory name that must match normally.
# A regression that quotes the value badly, splits on whitespace, or mangles the
# encoding would break exclusion for ordinary users on such a path.
# The fixture directory is created by make_git_repo with a name carrying both a
# space and CJK characters, so the repo root itself needs careful quoting all
# the way through parseExcludePatterns → normalizeCwd → path.resolve.
_x25_repo="$(make_git_repo "x25 スペース 名前")"
printf 'const msg = "日本語テスト";\n' > "$_x25_repo/test.js"
git -C "$_x25_repo" add test.js
_x25_root="$(git -C "$_x25_repo" rev-parse --show-toplevel)"

if require_sut "X25a" "$LINT_LIB"; then
    _x25a_got="$(run_check_node "$_x25_repo" "english" "$_x25_root" | _x_classify)"
    assert_eq "X25a: repo path with a space + Unicode is excludable (matching entry → violations empty)" \
        "empty" "$_x25a_got"
    # Control: without it the same fixture DOES violate, so "empty" above cannot
    # be a false green from a fixture that never had anything to report.
    _x25b_got="$(run_check_node "$_x25_repo" "english" "$_X_MISS_A" | _x_classify)"
    assert_eq "X25b (control): space + Unicode repo path, non-matching entry → violations non-empty" \
        "nonempty" "$_x25b_got"
fi

# X25c: same fixture through hooks/pre-commit — proves the value survives the
# bash layer's quoting as well, not just Node's. "skipped absent" rules out a
# fail-open (e.g. a quoting error crashing the module) masquerading as success.
_x25c_out="$(run_precommit "$_x25_repo" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
    "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x25_root")"
_x25c_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x25c_v="rc:nonzero"; [ "$_x25c_rc" -eq 0 ] && _x25c_v="rc:zero"
_x25c_block="absent"; printf '%s' "$_x25c_out" | grep -qF "$LANG_BLOCK_MARKER" && _x25c_block="present"
_x25c_skip="absent"; printf '%s' "$_x25c_out" | grep -q 'lint-commit-lang skipped' && _x25c_skip="present"
assert_eq "X25c: space + Unicode repo path excluded via pre-commit → allows (real skip, not fail-open)" \
    "rc:zero block:absent skipped:absent" \
    "$_x25c_v block:$_x25c_block skipped:$_x25c_skip"
