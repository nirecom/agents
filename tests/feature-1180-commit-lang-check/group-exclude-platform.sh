# tests/feature-1180-commit-lang-check/group-exclude-platform.sh
# Tests: hooks/lib/path-coverage-match.js, hooks/lib/glob-match.js, hooks/lib/lint-commit-lang.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X — Windows-specific absolute-path input forms: X15, X16, X23.
# Every case here is skipped on non-win32. Sourced by group-exclude.sh after
# group-exclude-lib.sh.

# X15 (Windows-only): plain entry supplied in native backslash form.
if [ "$_X_PLATFORM" != "win32" ]; then
    echo "SKIP: X15: Skipped-Because: backslash drive-letter entries are a Windows-only input form (platform=$_X_PLATFORM)"
else
    _x15_repo="$(make_git_repo x15)"
    printf 'const msg = "日本語テスト";\n' > "$_x15_repo/test.js"
    git -C "$_x15_repo" add test.js
    _x15_root="$(git -C "$_x15_repo" rev-parse --show-toplevel)"
    _x15_bs="$(printf '%s' "$_x15_root" | tr '/' '\\')"
    _x15_out="$(run_precommit "$_x15_repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x15_bs")"
    _x15_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x15_v="rc:nonzero"; [ "$_x15_rc" -eq 0 ] && _x15_v="rc:zero"
    _x15_block="absent"; printf '%s' "$_x15_out" | grep -qF "$LANG_BLOCK_MARKER" && _x15_block="present"
    _x15_skip="absent"; printf '%s' "$_x15_out" | grep -q 'lint-commit-lang skipped' && _x15_skip="present"
    assert_eq "X15: Windows backslash plain entry matches repo root → pre-commit allows" \
        "rc:zero block:absent skipped:absent" \
        "$_x15_v block:$_x15_block skipped:$_x15_skip"
fi

# X16 (Windows-only, CHARACTERIZATION): glob entries take a different code path
# in hooks/lib/path-coverage-match.js than plain entries — pathMatchesGlob() only
# lowercases and flips backslashes, it never runs normalizeCwd()/path.resolve().
#   (a) native-form glob  (C:\...\**)  MATCHES.
#   (b) Git-Bash-form glob (/c/.../**) does NOT match.
# (b) is a KNOWN GAP in the shared matcher, deliberately locked in here rather
# than fixed: the same Git-Bash form DOES work for plain entries. If the shared
# matcher's glob path ever gains normalizeCwd()/path.resolve(), update case (b)
# to expect a match. Do not "fix" it in this feature.
if [ "$_X_PLATFORM" != "win32" ]; then
    echo "SKIP: X16: Skipped-Because: drive-letter glob forms (native vs Git-Bash) exist only on Windows (platform=$_X_PLATFORM)"
else
    _x16_repo="$(make_git_repo x16)"
    printf 'const msg = "日本語テスト";\n' > "$_x16_repo/test.js"
    git -C "$_x16_repo" add test.js
    _x16_root="$(git -C "$_x16_repo" rev-parse --show-toplevel)"
    _x16_parent="$(dirname "$_x16_root")"

    # (a) native backslash subtree glob anchored at the parent
    _x16_a="$(printf '%s' "$_x16_parent" | tr '/' '\\')\\**"
    _x16a_out="$(run_precommit "$_x16_repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x16_a")"
    _x16a_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x16a_v="rc:nonzero"; [ "$_x16a_rc" -eq 0 ] && _x16a_v="rc:zero"
    _x16a_block="absent"; printf '%s' "$_x16a_out" | grep -qF "$LANG_BLOCK_MARKER" && _x16a_block="present"
    _x16a_skip="absent"; printf '%s' "$_x16a_out" | grep -q 'lint-commit-lang skipped' && _x16a_skip="present"
    assert_eq "X16a: Windows native-form glob (C:\\...\\**) matches → pre-commit allows" \
        "rc:zero block:absent skipped:absent" \
        "$_x16a_v block:$_x16a_block skipped:$_x16a_skip"

    # (b) Git-Bash drive form of the SAME directory — expected NOT to match.
    _x16_drive="$(printf '%s' "${_x16_parent%%:*}" | tr 'A-Z' 'a-z')"
    _x16_b="/$_x16_drive${_x16_parent#*:}/**"
    _x16b_out="$(run_precommit "$_x16_repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x16_b")"
    _x16b_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x16b_v="rc:zero"; [ "$_x16b_rc" -ne 0 ] && _x16b_v="rc:nonzero"
    _x16b_block="absent"; printf '%s' "$_x16b_out" | grep -qF "$LANG_BLOCK_MARKER" && _x16b_block="present"
    assert_eq "X16b: Windows Git-Bash-form glob (/c/.../**) does NOT match → pre-commit still blocks (known matcher gap)" \
        "rc:nonzero block:present" \
        "$_x16b_v block:$_x16b_block"
fi

# ---------------------------------------------------------------------------
# G — Git-Bash drive form, PLAIN entry (X23)
# ---------------------------------------------------------------------------
# Counterpart to X16b. Plain (non-glob) entries take the _canon() path in
# hooks/lib/path-coverage-match.js, which runs normalizeCwd() + path.resolve() and
# therefore DOES fold the Git-Bash drive form (/c/foo) onto the native form
# (C:\foo). Glob entries skip that normalization — hence X16b's opposite verdict.
# Pinning both directions is what makes X16b readable as a deliberate asymmetry
# rather than an untested corner. Do NOT "align" the two: X16b stays as-is.
if [ "$_X_PLATFORM" != "win32" ]; then
    echo "SKIP: X23: Skipped-Because: the Git-Bash drive form (/c/...) of an absolute path exists only on Windows (platform=$_X_PLATFORM)"
else
    _x23_repo="$(make_git_repo x23)"
    printf 'const msg = "日本語テスト";\n' > "$_x23_repo/test.js"
    git -C "$_x23_repo" add test.js
    _x23_root="$(git -C "$_x23_repo" rev-parse --show-toplevel)"
    _x23_drive="$(printf '%s' "${_x23_root%%:*}" | tr 'A-Z' 'a-z')"
    _x23_gb="/$_x23_drive${_x23_root#*:}"
    _x23_out="$(run_precommit "$_x23_repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x23_gb")"
    _x23_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x23_v="rc:nonzero"; [ "$_x23_rc" -eq 0 ] && _x23_v="rc:zero"
    _x23_block="absent"; printf '%s' "$_x23_out" | grep -qF "$LANG_BLOCK_MARKER" && _x23_block="present"
    _x23_skip="absent"; printf '%s' "$_x23_out" | grep -q 'lint-commit-lang skipped' && _x23_skip="present"
    assert_eq "X23: Windows Git-Bash-form PLAIN entry (/c/...) matches repo root → pre-commit allows (real skip, not fail-open)" \
        "rc:zero block:absent skipped:absent" \
        "$_x23_v block:$_x23_block skipped:$_x23_skip"
fi
