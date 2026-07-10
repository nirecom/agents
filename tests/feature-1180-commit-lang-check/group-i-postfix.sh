# tests/feature-1180-commit-lang-check/group-i-postfix.sh
# Group I (continued) — staged-path robustness (post-fix): CL-I8, CL-I9.
# Sourced by the dispatcher after lib.sh.

# ============================================================================
# Group I (continued) — staged-path robustness (post-fix)
# ============================================================================

# CL-I8 (post-fix): staged filename with embedded space — file is scanned and
# violation is reported AT that path. Space in filename is cross-platform safe
# (git for Windows handles it fine). This exercises the NUL-split fix for
# stagedFiles(): the old \r?\n split also handles spaces correctly, so this case
# is GREEN against both old and new source — it is included to lock in the
# space-path contract.
#
# Skipped-Because (Linux-only): TRUE newline-in-filename (e.g. "my\nfile.js")
# is not creatable on Windows/msys git. The NUL-split fix is specifically
# designed to handle that case, but the executable test can only use a space.
#
# L3 gap: newline-in-filename test requires a native Linux git environment.
# The stagedFiles() fix (--diff-filter=ACMR -z split on NUL) is the targeted
# fix for that gap. A Linux CI runner with a test creating a newline-in-path
# fixture would be the closest-to-action verification.
_i8_repo="$(make_git_repo i8)"
printf 'const msg = "日本語テスト";\n' > "$_i8_repo/my file.js"
git -C "$_i8_repo" add "$_i8_repo/my file.js"
_i8_out="$(run_precommit "$_i8_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
# The violation path may be quoted by git on some platforms (e.g. "my file.js")
# so we match loosely for the filename fragment.
if [ "$PC_RC" -ne 0 ] && echo "$_i8_out" | grep -qF "$LANG_BLOCK_MARKER" && echo "$_i8_out" | grep -q 'my file'; then
    pass "CL-I8: space-in-filename staged path → file scanned, violation reported at correct path"
else
    fail "CL-I8: expected block+marker+path 'my file', rc=$PC_RC: $_i8_out"
fi

# CL-I9 (post-fix, Linux-only active): staged filename with an embedded TAB byte —
# file is scanned and a violation is reported. This is the C6 special-char gap
# beyond a plain space: git QUOTES paths containing special bytes in --name-only
# output (emits the literal "tab\tname.js" with quotes + escape). The current
# \r?\n split then feeds that mismatched quoted token to `git show :"tab\tname.js"`,
# which fails, so the file is silently SKIPPED and the real violation is MISSED.
# The -z fix (--diff-filter=ACMR -z, split on NUL) emits the raw unquoted path so
# `git show :path` succeeds and the file is scanned.
#   RED  (current source): quoted-path mismatch → file skipped → no violation.
#   GREEN (after -z fix):   tab-named file scanned → violation reported.
#
# Skipped-Because (Linux-only): a TAB (or newline) in a filename is not creatable
# / not stageable on Windows/msys git — `git add` cannot match a pathspec that
# contains a raw TAB byte. So the active assertion runs only on Linux (uname
# == Linux); on Windows/msys it SKIPs (no fabricated pass).
#
# L3 gap: tab/newline-in-filename is Linux-only; the -z fix's correctness on such
# paths is only observable on a native Linux git environment. A Linux CI runner
# that stages a TAB-named fixture and asserts the violation is the closest-to-action
# verification for the stagedFiles() -z fix.
_i9_uname="$(uname 2>/dev/null || echo unknown)"
if [ "$_i9_uname" = "Linux" ]; then
    _i9_repo="$(make_git_repo i9)"
    _i9_name="$(printf 'tab\tname.js')"
    if printf 'const msg = "日本語テスト";\n' > "$_i9_repo/$_i9_name" 2>/dev/null \
        && git -C "$_i9_repo" add "$_i9_name" 2>/dev/null; then
        _i9_out="$(run_precommit "$_i9_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
        PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
        # Match loosely on the 'name.js' fragment; git may quote/escape the path.
        if [ "$PC_RC" -ne 0 ] && echo "$_i9_out" | grep -qF "$LANG_BLOCK_MARKER" && echo "$_i9_out" | grep -q 'name\.js'; then
            pass "CL-I9: tab-in-filename staged path → file scanned, violation reported (GREEN after -z fix)"
        else
            fail "CL-I9: expected block+marker for tab-named path, rc=$PC_RC: $_i9_out (RED pending source fix: stagedFiles() must split on NUL via -z)"
        fi
    else
        echo "SKIP: CL-I9: tab-in-filename not stageable on this git (Skipped-Because: Linux-only fixture)"
    fi
else
    echo "SKIP: CL-I9: tab-in-filename is Linux-only (uname=$_i9_uname); Skipped-Because Windows/msys git cannot stage a TAB-named path — see L3 gap note"
fi

# CL-I10: CODE_LANG delivered via .env file (not direct env var)
# The pre-commit hook sources $AGENTS_CONFIG_DIR/.env early via _load_env_file().
# This case verifies that the .env sourcing path works end-to-end: when CODE_LANG
# is NOT in the environment but IS present in .env, the hook picks it up and applies
# the policy. AGENTS_CONFIG_DIR points to a temp dir containing both .env and the
# hook modules (node require() resolves them from AGENTS_CONFIG_DIR/hooks/lib/).
_i10_cfg="$TMPDIR_BASE/cfg-i10"
mkdir -p "$_i10_cfg/hooks/lib"
# Write stub .env — CODE_LANG=english only (no other vars needed)
printf 'CODE_LANG=english\n' > "$_i10_cfg/.env"
# Copy all required hook modules (node resolves relative requires from the file location)
cp "$AGENTS_DIR/hooks/lib/lint-commit-lang.js" "$_i10_cfg/hooks/lib/"
cp "$AGENTS_DIR/hooks/lib/detect-cjk.js"       "$_i10_cfg/hooks/lib/"
cp "$AGENTS_DIR/hooks/lib/lang-config.js"       "$_i10_cfg/hooks/lib/"
cp "$AGENTS_DIR/hooks/lib/lint-plan-lang.js"    "$_i10_cfg/hooks/lib/"
cp "$AGENTS_DIR/hooks/lib/load-env.js"          "$_i10_cfg/hooks/lib/"

# Create a temp repo with a staged file containing CJK content
_i10_repo="$(make_git_repo i10)"
printf 'const msg = "日本語テスト";\n' > "$_i10_repo/test.js"
git -C "$_i10_repo" add test.js

# Run pre-commit: AGENTS_CONFIG_DIR points to our temp cfg (has .env + modules),
# NO CODE_LANG env var — the hook must pick it up from .env
_i10_out="$(run_precommit "$_i10_repo" "AGENTS_CONFIG_DIR=$_i10_cfg" "ENFORCE_WORKTREE=off")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"

if [ "$PC_RC" -ne 0 ] && echo "$_i10_out" | grep -qF "$LANG_BLOCK_MARKER"; then
    pass "CL-I10: CODE_LANG from .env file → hook reads it and blocks commit with LANG_BLOCK_MARKER"
else
    fail "CL-I10: expected CODE_LANG to be sourced from .env and trigger block, rc=$PC_RC output=$_i10_out"
fi

# CL-I11: blob fetch failure → fail-open (check() returns zero violations)
# When git show :file fails (blob object missing/corrupt), stagedBlob() returns null
# and the file is silently skipped, producing zero violations. This is tested at the
# unit level (run_check_node) because the pre-commit hook's scan-outbound section
# independently exits 1 on missing blobs before the CODE_LANG check even runs.
#
# L3 gap: Object deletion requires filesystem access to .git/objects. On systems
# where git gc has run, the blob may live in a packfile not as a loose object, so
# deletion may not cause git-show failure. This test relies on a fresh repo where
# loose objects are always created by git-add.
if require_sut "CL-I11" "$LINT_LIB"; then
    _i11_repo="$(make_git_repo i11)"
    printf 'const msg = "日本語テスト";\n' > "$_i11_repo/test.js"
    git -C "$_i11_repo" add test.js

    # Get the blob hash (colon prefix = index blob) and delete the loose object file
    _i11_hash="$(git -C "$_i11_repo" rev-parse ":test.js" 2>/dev/null)"
    if [ -n "$_i11_hash" ]; then
        _i11_obj="$_i11_repo/.git/objects/${_i11_hash:0:2}/${_i11_hash:2}"
        rm -f "$_i11_obj"
        # Verify deletion worked — git show should fail now
        if ! git -C "$_i11_repo" show ":test.js" >/dev/null 2>&1; then
            # Call check() directly: CODE_LANG=english, blob missing → stagedBlob()
            # returns null → file skipped → violations must be empty (fail-open)
            _i11_out="$(run_check_node "$_i11_repo" "english")"
            if echo "$_i11_out" | json_violations_empty; then
                pass "CL-I11: missing blob → stagedBlob() returns null → file skipped → violations empty (fail-open)"
            else
                fail "CL-I11: expected empty violations (fail-open) when blob missing, got: $_i11_out"
            fi
        else
            # SKIP: blob deletion did not make git-show fail (e.g. packfile)
            # Skipped-Because: blob may be in a packfile; L3 gap: true object-store fault
            # injection requires a controlled git env or FUSE.
            echo "SKIP: CL-I11: blob object not loose (may be packed); cannot simulate fetch failure on this git"
        fi
    else
        echo "SKIP: CL-I11: could not resolve blob hash for test.js (git rev-parse :test.js failed)"
    fi
fi
