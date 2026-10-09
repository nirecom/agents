# tests/hooks/feature-1180-commit-lang-check/group-exclude-precommit.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/lib/path-coverage-match.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X hook-integration cases (X12..X14, X19, X20, X24, X26, X30); overview: group-exclude.sh.

# --- D: integration through hooks/pre-commit ---

# X12: excluded repo + CJK staged → allowed. rc=0 alone cannot tell a real skip
# from a fail-open, so the block marker and the fail-open notice are asserted absent.
_x12_repo="$(make_git_repo x12)"
printf 'const msg = "日本語テスト";\n' > "$_x12_repo/test.js"
git -C "$_x12_repo" add test.js
_x12_root="$(git -C "$_x12_repo" rev-parse --show-toplevel)"
_x12_out="$(run_precommit "$_x12_repo" \
    "ENFORCE_WORKTREE=off" \
    "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x12_root")"
_x12_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x12_v="rc:nonzero"; [ "$_x12_rc" -eq 0 ] && _x12_v="rc:zero"
_x12_block="absent"; printf '%s' "$_x12_out" | grep -qF "$LANG_BLOCK_MARKER" && _x12_block="present"
_x12_skip="absent"; printf '%s' "$_x12_out" | grep -q 'lint-commit-lang skipped' && _x12_skip="present"
assert_eq "X12: excluded repo + CJK staged → pre-commit allows (real skip, not fail-open)" \
    "rc:zero block:absent skipped:absent" \
    "$_x12_v block:$_x12_block skipped:$_x12_skip"

# X13: a non-matching CODE_LANG_EXCLUDE still blocks (guard against over-skipping).
_x13_repo="$(make_git_repo x13)"
printf 'const msg = "日本語テスト";\n' > "$_x13_repo/test.js"
git -C "$_x13_repo" add test.js
_x13_out="$(run_precommit "$_x13_repo" \
    "ENFORCE_WORKTREE=off" \
    "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
_x13_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x13_v="rc:zero"; [ "$_x13_rc" -ne 0 ] && _x13_v="rc:nonzero"
_x13_block="absent"; printf '%s' "$_x13_out" | grep -qF "$LANG_BLOCK_MARKER" && _x13_block="present"
assert_eq "X13: non-matching CODE_LANG_EXCLUDE + CJK staged → pre-commit still blocks" \
    "rc:nonzero block:present" \
    "$_x13_v block:$_x13_block"

# X14: CODE_LANG_EXCLUDE comes from the .env of a stubbed settings root (2 entries,
# 2nd matches); $EXCLUDE_FROM_DOTENV (lib.sh) keeps the isolation sentinel out.
_x14_cfg="$TMPDIR_BASE/cfg-x14"
mkdir -p "$_x14_cfg/hooks/lib"
# Empty blocklist: the allowed path reaches the outbound scanner (as lib.sh MAIN_ROOT_FIXTURE).
: > "$_x14_cfg/.private-info-blocklist"
_x14_repo="$(make_git_repo x14)"
printf 'const msg = "日本語テスト";\n' > "$_x14_repo/test.js"
git -C "$_x14_repo" add test.js
_x14_root="$(git -C "$_x14_repo" rev-parse --show-toplevel)"
printf 'CODE_LANG=english\nCODE_LANG_EXCLUDE=%s;%s\n' "$_X_MISS_A" "$_x14_root" > "$_x14_cfg/.env"
for _x14_mod in lint-commit-lang.js detect-cjk.js lang-config.js lint-plan-lang.js \
                load-env.js script-checkout-root.js path-normalize.js \
                path-coverage-match.js glob-match.js; do
    cp "$SCRIPT_CHECKOUT_ROOT/hooks/lib/$_x14_mod" "$_x14_cfg/hooks/lib/" 2>/dev/null || true
done
_x14_out="$(run_precommit "$_x14_repo" "AGENTS_MAIN_ROOT=$_x14_cfg" "ENFORCE_WORKTREE=off" \
    "$EXCLUDE_FROM_DOTENV")"
_x14_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x14_v="rc:nonzero"; [ "$_x14_rc" -eq 0 ] && _x14_v="rc:zero"
_x14_block="absent"; printf '%s' "$_x14_out" | grep -qF "$LANG_BLOCK_MARKER" && _x14_block="present"
_x14_skip="absent"; printf '%s' "$_x14_out" | grep -q 'lint-commit-lang skipped' && _x14_skip="present"
assert_eq "X14: CODE_LANG_EXCLUDE from .env (2 entries, 2nd matches) → allowed via the real matcher" \
    "rc:zero block:absent skipped:absent" \
    "$_x14_v block:$_x14_block skipped:$_x14_skip"

# X26a/X26b: the default still blocks end to end, for "key absent" and "key empty";
# empty-is-unset rule: hooks/lib/load-env.js loadEnv().
_x26_mk_cfg() {
    local cfg="$1" excl_line="$2" mod
    mkdir -p "$cfg/hooks/lib"
    printf 'CODE_LANG=english\n%s' "$excl_line" > "$cfg/.env"
    for mod in lint-commit-lang.js detect-cjk.js lang-config.js lint-plan-lang.js \
               load-env.js script-checkout-root.js path-normalize.js \
               path-coverage-match.js glob-match.js; do
        cp "$SCRIPT_CHECKOUT_ROOT/hooks/lib/$mod" "$cfg/hooks/lib/" 2>/dev/null || true
    done
}

# _x26_probe <label> <cfg-dir> — stage CJK, run the real hook, print the verdict.
_x26_probe() {
    local label="$1" cfg="$2" repo out rc v block skip
    repo="$(make_git_repo "${label//:/-}")"
    printf 'const msg = "日本語テスト";\n' > "$repo/test.js"
    git -C "$repo" add test.js
    out="$(run_precommit "$repo" -u CODE_LANG_EXCLUDE \
        "AGENTS_MAIN_ROOT=$cfg" "ENFORCE_WORKTREE=off")"
    rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    v="rc:zero"; [ "$rc" -ne 0 ] && v="rc:nonzero"
    block="absent"; printf '%s' "$out" | grep -qF "$LANG_BLOCK_MARKER" && block="present"
    skip="absent"; printf '%s' "$out" | grep -q 'lint-commit-lang skipped' && skip="present"
    printf '%s block:%s skipped:%s' "$v" "$block" "$skip"
}

_x26a_cfg="$TMPDIR_BASE/cfg-x26a"
_x26_mk_cfg "$_x26a_cfg" ""
assert_eq "X26a: CODE_LANG_EXCLUDE key absent entirely + CJK staged → pre-commit still blocks (default unchanged, not fail-open)" \
    "rc:nonzero block:present skipped:absent" \
    "$(_x26_probe x26a "$_x26a_cfg")"

_x26b_cfg="$TMPDIR_BASE/cfg-x26b"
_x26_mk_cfg "$_x26b_cfg" "CODE_LANG_EXCLUDE=
"
assert_eq "X26b: CODE_LANG_EXCLUDE present but empty + CJK staged → pre-commit still blocks (empty ≠ match-all)" \
    "rc:nonzero block:present skipped:absent" \
    "$(_x26_probe x26b "$_x26b_cfg")"

# --- E: process-env vs .env precedence (X19) ---
# Both directions of "a non-empty process.env value wins over .env":
# hooks/lib/load-env.js loadEnv() and loadDefaultEnvGlobal().
_x19_cfg_a="$TMPDIR_BASE/cfg-x19a"
_x19_cfg_b="$TMPDIR_BASE/cfg-x19b"
mkdir -p "$_x19_cfg_a" "$_x19_cfg_b"

# X19a: .env matches the repo root, process env does not → still blocks.
if require_sut "X19a" "$LINT_LIB"; then
    _x19a_repo="$(make_git_repo x19a)"
    printf 'const msg = "日本語テスト";\n' > "$_x19a_repo/test.js"
    git -C "$_x19a_repo" add test.js
    _x19a_root="$(git -C "$_x19a_repo" rev-parse --show-toplevel)"
    printf 'CODE_LANG_EXCLUDE=%s\n' "$_x19a_root" > "$_x19_cfg_a/.env"
    _x19a_out="$(run_check_node_raw "$_x19a_repo" \
        "CODE_LANG=english" \
        "CODE_LANG_EXCLUDE=$_X_MISS_A" \
        "AGENTS_MAIN_ROOT=$_x19_cfg_a")"
    _x19a_got="$(printf '%s' "$_x19a_out" | _x_classify)"
    assert_eq "X19a: process-env CODE_LANG_EXCLUDE (non-matching) overrides a matching .env value → still blocks" \
        "nonempty" "$_x19a_got"
fi

# X19b: mirror — .env does not match, process env does → skips.
if require_sut "X19b" "$LINT_LIB"; then
    _x19b_repo="$(make_git_repo x19b)"
    printf 'const msg = "日本語テスト";\n' > "$_x19b_repo/test.js"
    git -C "$_x19b_repo" add test.js
    _x19b_root="$(git -C "$_x19b_repo" rev-parse --show-toplevel)"
    printf 'CODE_LANG_EXCLUDE=%s\n' "$_X_MISS_B" > "$_x19_cfg_b/.env"
    _x19b_out="$(run_check_node_raw "$_x19b_repo" \
        "CODE_LANG=english" \
        "CODE_LANG_EXCLUDE=$_x19b_root" \
        "AGENTS_MAIN_ROOT=$_x19_cfg_b")"
    _x19b_got="$(printf '%s' "$_x19b_out" | _x_classify)"
    assert_eq "X19b: process-env CODE_LANG_EXCLUDE (matching) overrides a non-matching .env value → skips" \
        "empty" "$_x19b_got"
fi

# --- F: exclude gate symmetry across CODE_LANG policy tiers (X20) ---
# The gate runs before the policy switch (hooks/lib/lint-commit-lang.js check());
# each matching case has a non-matching control.

# X20a/X20b: strict policy `japanese`, fixture = a long English-only run (as CL-U5).
if require_sut "X20a" "$LINT_LIB"; then
    _x20j_repo="$(make_git_repo x20j)"
    printf '// This function returns the current value of the counter\nconst x = 1;\n' > "$_x20j_repo/test.js"
    git -C "$_x20j_repo" add test.js
    _x20j_root="$(git -C "$_x20j_repo" rev-parse --show-toplevel)"
    _x20a_got="$(run_check_node "$_x20j_repo" "japanese" "$_x20j_root" | _x_classify)"
    assert_eq "X20a: CODE_LANG=japanese + matching CODE_LANG_EXCLUDE → violations empty (gate is policy-agnostic)" \
        "empty" "$_x20a_got"
    _x20b_got="$(run_check_node "$_x20j_repo" "japanese" "$_X_MISS_A" | _x_classify)"
    assert_eq "X20b (control): CODE_LANG=japanese + non-matching CODE_LANG_EXCLUDE → violations non-empty" \
        "nonempty" "$_x20b_got"
fi

# X20c/X20d: hint tier (`french`, as CL-U6) — the gate must empty `hints` too,
# so both arrays are asserted.
if require_sut "X20c" "$LINT_LIB"; then
    _x20h_repo="$(make_git_repo x20h)"
    printf 'const msg = "日本語のメッセージ";\n' > "$_x20h_repo/test.js"
    git -C "$_x20h_repo" add test.js
    _x20h_root="$(git -C "$_x20h_repo" rev-parse --show-toplevel)"
    _x20c_got="$(run_check_node "$_x20h_repo" "french" "$_x20h_root" | _x_classify_vh)"
    assert_eq "X20c: hint-tier CODE_LANG + matching CODE_LANG_EXCLUDE → violations AND hints both empty" \
        "v:empty h:empty" "$_x20c_got"
    _x20d_got="$(run_check_node "$_x20h_repo" "french" "$_X_MISS_A" | _x_classify_vh)"
    assert_eq "X20d (control): hint-tier CODE_LANG + non-matching CODE_LANG_EXCLUDE → hints non-empty" \
        "v:empty h:nonempty" "$_x20d_got"
fi

# --- H: CODE_LANG_EXCLUDE is inert data, never a shell command (X24) ---
# Non-execution is proven by two marker files the injected commands would create;
# the CODE_LANG block under test: hooks/pre-commit.
_x24_sandbox="$TMPDIR_BASE/inject-x24"
mkdir -p "$_x24_sandbox"
_x24_m1="$_x24_sandbox/pwned-subst"
_x24_m2="$_x24_sandbox/pwned-backtick"
rm -f "$_x24_m1" "$_x24_m2"
# Single-quoted printf format: bash must not expand the payload here.
_x24_val="$(printf '%s; $(touch %s); `touch %s`;%s' \
    "$_X_MISS_A" "$_x24_m1" "$_x24_m2" "$_X_MISS_B")"
_x24_repo="$(make_git_repo x24)"
printf 'const msg = "日本語テスト";\n' > "$_x24_repo/test.js"
git -C "$_x24_repo" add test.js
_x24_out="$(run_precommit "$_x24_repo" \
    "ENFORCE_WORKTREE=off" \
    "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x24_val")"
_x24_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x24_v="rc:zero"; [ "$_x24_rc" -ne 0 ] && _x24_v="rc:nonzero"
_x24_block="absent"; printf '%s' "$_x24_out" | grep -qF "$LANG_BLOCK_MARKER" && _x24_block="present"
_x24_m1s="absent"; [ -e "$_x24_m1" ] && _x24_m1s="present"
_x24_m2s="absent"; [ -e "$_x24_m2" ] && _x24_m2s="present"
# Any file at all in the sandbox means something wrote where nothing should.
_x24_stray="$(find "$_x24_sandbox" -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "X24: shell metacharacters in CODE_LANG_EXCLUDE are inert data — no command executed, CJK still blocked" \
    "rc:nonzero block:present subst:absent backtick:absent stray:0" \
    "$_x24_v block:$_x24_block subst:$_x24_m1s backtick:$_x24_m2s stray:$_x24_stray"
rm -f "$_x24_m1" "$_x24_m2"

# --- I: exclude-skip audit trace through hooks/pre-commit (X30) ---
# The trace is asserted present on a real skip and absent otherwise; its contract:
# hooks/lib/lint-commit-lang.js header. The colon tells it from the fail-open notice.
_X_AUDIT_TRACE="lint-commit-lang: skipped (CODE_LANG_EXCLUDE match)"

# _x30_probe <label> <content> <match|miss> — stage <content>, run the real hook,
# print rc / language-block / fail-open / audit-trace state.
_x30_probe() {
    local label="$1" content="$2" mode="$3" repo root excl out rc v block skip audit
    repo="$(make_git_repo "$label")"
    printf '%s' "$content" > "$repo/test.js"
    git -C "$repo" add test.js
    root="$(git -C "$repo" rev-parse --show-toplevel)"
    excl="$_X_MISS_A"
    [ "$mode" = "match" ] && excl="$root"
    out="$(run_precommit "$repo" \
        "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$excl")"
    rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    v="rc:zero"; [ "$rc" -ne 0 ] && v="rc:nonzero"
    block="absent"; printf '%s' "$out" | grep -qF "$LANG_BLOCK_MARKER" && block="present"
    skip="absent"; printf '%s' "$out" | grep -q 'lint-commit-lang skipped' && skip="present"
    audit="absent"; printf '%s' "$out" | grep -qF "$_X_AUDIT_TRACE" && audit="present"
    printf '%s block:%s skipped:%s audit:%s' "$v" "$block" "$skip" "$audit"
}

assert_eq "X30a: matching CODE_LANG_EXCLUDE + CJK staged → commit allowed AND the skip is announced on stderr" \
    "rc:zero block:absent skipped:absent audit:present" \
    "$(_x30_probe x30a 'const msg = "日本語テスト";
' match)"

assert_eq "X30b: non-matching CODE_LANG_EXCLUDE + CJK staged → still blocks, no audit trace (trace is not printed when nothing was skipped)" \
    "rc:nonzero block:present skipped:absent audit:absent" \
    "$(_x30_probe x30b 'const msg = "日本語テスト";
' miss)"

assert_eq "X30c: non-matching CODE_LANG_EXCLUDE + policy-clean content → commit allowed with no audit trace (trace tracks the skip, not rc=0)" \
    "rc:zero block:absent skipped:absent audit:absent" \
    "$(_x30_probe x30c 'const msg = "hello";
' miss)"
