# tests/feature-1180-commit-lang-check/group-i.sh
# Group I — L2 integration (invoke hooks/pre-commit directly): CL-I1..CL-I7.
# Sourced by the dispatcher after lib.sh; relies on its shared harness.

# ============================================================================
# Group I — L2 integration (invoke hooks/pre-commit directly)
# ============================================================================

echo ""
echo "=== Group I: pre-commit hook integration ==="
echo ""

# CL-I1: CODE_LANG unset + staged CJK → commit path SUCCEEDS (rc 0)
# ENFORCE_WORKTREE=off skips the worktree gate so the language check is reached.
_i1_repo="$(make_git_repo i1)"
printf 'const x = "日本語";\n' > "$_i1_repo/test.js"
git -C "$_i1_repo" add test.js
_i1_out="$(run_precommit "$_i1_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
if [ "$PC_RC" -eq 0 ]; then
    pass "CL-I1: CODE_LANG unset + staged CJK → pre-commit succeeds"
else
    fail "CL-I1: expected rc 0 with CODE_LANG unset, rc=$PC_RC: $_i1_out"
fi

# CL-I2: CODE_LANG=english + staged CJK → BLOCKED (rc!=0, marker, file:line)
_i2_repo="$(make_git_repo i2)"
printf 'const x = "日本語テスト";\n' > "$_i2_repo/test.js"
git -C "$_i2_repo" add test.js
_i2_out="$(run_precommit "$_i2_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
if [ "$PC_RC" -ne 0 ] && echo "$_i2_out" | grep -qF "$LANG_BLOCK_MARKER" && echo "$_i2_out" | grep -qE 'test\.js:[0-9]+'; then
    pass "CL-I2: CODE_LANG=english + staged CJK → blocked with marker + file:line (RED until /write-code)"
else
    fail "CL-I2: expected block+marker+file:line, rc=$PC_RC (RED until /write-code)"
fi

# CL-I3: CODE_LANG=english + lang-check: ignore + CJK → SUCCEEDS
_i3_repo="$(make_git_repo i3)"
printf '// lang-check: ignore\nconst x = "日本語テスト";\n' > "$_i3_repo/test.js"
git -C "$_i3_repo" add test.js
_i3_out="$(run_precommit "$_i3_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
if [ "$PC_RC" -eq 0 ]; then
    pass "CL-I3: lang-check: ignore + CJK → pre-commit succeeds"
else
    fail "CL-I3: expected rc 0 with bypass marker, rc=$PC_RC: $_i3_out"
fi

# CL-I4: CODE_LANG=english + clean english file → SUCCEEDS
_i4_repo="$(make_git_repo i4)"
printf 'function greet(name) { return "Hello, " + name; }\n' > "$_i4_repo/test.js"
git -C "$_i4_repo" add test.js
_i4_out="$(run_precommit "$_i4_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
if [ "$PC_RC" -eq 0 ]; then
    pass "CL-I4: CODE_LANG=english + english-only file → pre-commit succeeds"
else
    fail "CL-I4: expected rc 0 for english file, rc=$PC_RC: $_i4_out"
fi

# CL-I5b: ENFORCE_WORKTREE=off + CODE_LANG=english + CJK → BLOCKED (marker present)
_i5b_repo="$(make_git_repo i5b)"
printf 'const msg = "日本語テスト";\n' > "$_i5b_repo/test.js"
git -C "$_i5b_repo" add test.js
_i5b_out="$(run_precommit "$_i5b_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
if [ "$PC_RC" -ne 0 ] && echo "$_i5b_out" | grep -qF "$LANG_BLOCK_MARKER"; then
    pass "CL-I5b: ENFORCE_WORKTREE=off + CODE_LANG=english + CJK → blocked with marker (RED until /write-code)"
else
    fail "CL-I5b: expected block+marker with ENFORCE_WORKTREE=off, rc=$PC_RC (RED until /write-code)"
fi

# CL-I5a: ENFORCE_WORKTREE=on but worktree gate bypassed via the IMPLEMENTED
# ENFORCE_WORKTREE_EXCLUDE_REPOS mechanism (not the unimplemented .workflow-off
# marker — that bypass is itself pending TDD on this branch, see
# feature-workflow-off-bypass-pre-commit.sh tests B/C). Excluding the repo lets
# the hook proceed past the gate while ENFORCE_WORKTREE=on, so the UNCONDITIONAL
# language check is reached. Proves the language check runs regardless of
# ENFORCE_WORKTREE. The assertion requires the language marker specifically, and
# separately guards against the worktree-gate message so a gate confound (which
# would also be rc!=0) can never produce a false pass.
_i5a_repo="$(make_git_repo i5a)"
printf 'const msg = "日本語テスト";\n' > "$_i5a_repo/test.js"
git -C "$_i5a_repo" add test.js
_i5a_out="$(run_precommit "$_i5a_repo" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "ENFORCE_WORKTREE=on" \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=$_i5a_repo" \
    "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_i5a_gate=0
echo "$_i5a_out" | grep -q "commits from main worktree are blocked" && _i5a_gate=1 || true
if [ "$PC_RC" -ne 0 ] && [ "$_i5a_gate" -eq 0 ] && echo "$_i5a_out" | grep -qF "$LANG_BLOCK_MARKER"; then
    pass "CL-I5a: ENFORCE_WORKTREE=on (repo excluded) + CJK → language check fires, not gate (RED until /write-code)"
else
    fail "CL-I5a: expected language block (gate bypassed), rc=$PC_RC gate=$_i5a_gate (RED until /write-code)"
fi

# CL-I6 (SECURITY): blocked output shows CJK file:line + marker, NOT the fake
# token on a separate non-violating line.
_i6_repo="$(make_git_repo i6)"
printf 'const SUPER_SECRET = "FAKE_TOKEN_DO_NOT_USE_0000";\nconst msg = "日本語テスト";\n' > "$_i6_repo/secret_test.js"
git -C "$_i6_repo" add secret_test.js
_i6_out="$(run_precommit "$_i6_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_i6_marker=0; _i6_fileline=0; _i6_secret=0
echo "$_i6_out" | grep -qF "$LANG_BLOCK_MARKER" && _i6_marker=1 || true
echo "$_i6_out" | grep -qE 'secret_test\.js:[0-9]+' && _i6_fileline=1 || true
echo "$_i6_out" | grep -q 'FAKE_TOKEN_DO_NOT_USE_0000' && _i6_secret=1 || true
if [ "$PC_RC" -ne 0 ] && [ "$_i6_marker" -eq 1 ] && [ "$_i6_fileline" -eq 1 ] && [ "$_i6_secret" -eq 0 ]; then
    pass "CL-I6: blocked; marker + CJK file:line shown; fake token NOT leaked (RED until /write-code)"
else
    fail "CL-I6: SECURITY: rc=$PC_RC marker=$_i6_marker fileline=$_i6_fileline secret=$_i6_secret (RED until /write-code)"
fi

# CL-I7 (renamed dest): prior commit establishes the blob (hooks disabled), then
# rename + stage → language check scans the rename destination (--diff-filter=ACMR).
_i7_repo="$(make_git_repo i7)"
printf 'const x = "日本語テスト";\n' > "$_i7_repo/original.js"
git -C "$_i7_repo" add original.js
git -C "$_i7_repo" commit -q -m "establish blob (hooks disabled)"
git -C "$_i7_repo" mv original.js renamed.js
git -C "$_i7_repo" add renamed.js
_i7_out="$(run_precommit "$_i7_repo" "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" "CODE_LANG=english")"
PC_RC="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
if [ "$PC_RC" -ne 0 ] && echo "$_i7_out" | grep -qF "$LANG_BLOCK_MARKER"; then
    pass "CL-I7: renamed dest with CJK + CODE_LANG=english → blocked (rename blob scanned) (RED until /write-code)"
else
    fail "CL-I7: expected rename dest scanned+blocked, rc=$PC_RC (RED until /write-code)"
fi

# CL-I8b: multi-file staging — check() iterates all staged files.
# Stages 2 CJK files and 1 clean file; asserts both CJK files produce violations
# and the clean file does not add a third violation.
if require_sut "CL-I8b" "$LINT_LIB"; then
    _i8b_repo="$(make_git_repo i8b)"
    printf 'const a = "日本語テスト";\n' > "$_i8b_repo/file1.js"
    printf 'const b = "漢字テスト";\n'   > "$_i8b_repo/file2.js"
    printf 'const c = 42;\n'             > "$_i8b_repo/file3.js"
    git -C "$_i8b_repo" add file1.js file2.js file3.js
    _i8b_out="$(run_check_node "$_i8b_repo" "english")"
    _i8b_count="$(echo "$_i8b_out" | node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try { const r=JSON.parse(d); console.log(r.violations?r.violations.length:0); }
            catch(e) { console.log(0); }
        })' 2>/dev/null)"
    if [ "$_i8b_count" -eq 2 ]; then
        pass "CL-I8b: multi-file — 2 CJK files + 1 clean file → exactly 2 violations"
    else
        fail "CL-I8b: expected 2 violations for 2 CJK files + 1 clean file, got=$_i8b_count; output=$_i8b_out"
    fi
fi
