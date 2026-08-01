# tests/feature-1180-commit-lang-check/group-exclude-precommit.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/lib/path-coverage-match.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X — D/E/F/H/I: hook integration, .env-vs-env precedence, policy-tier
# symmetry, injection inertness and the exclude-skip audit trace.
# Cases X12..X14, X19, X20, X24, X26, X30.
# Sourced by group-exclude.sh after group-exclude-lib.sh.

# ---------------------------------------------------------------------------
# D — integration through hooks/pre-commit
# ---------------------------------------------------------------------------

# X12: repo IS excluded + CJK staged → commit allowed. Both the language block
# marker AND the fail-open message must be absent: a genuine skip and an
# accidental fail-open both yield rc=0, so checking rc alone would be false-green.
_x12_repo="$(make_git_repo x12)"
printf 'const msg = "日本語テスト";\n' > "$_x12_repo/test.js"
git -C "$_x12_repo" add test.js
_x12_root="$(git -C "$_x12_repo" rev-parse --show-toplevel)"
_x12_out="$(run_precommit "$_x12_repo" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
    "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_x12_root")"
_x12_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x12_v="rc:nonzero"; [ "$_x12_rc" -eq 0 ] && _x12_v="rc:zero"
_x12_block="absent"; printf '%s' "$_x12_out" | grep -qF "$LANG_BLOCK_MARKER" && _x12_block="present"
_x12_skip="absent"; printf '%s' "$_x12_out" | grep -q 'lint-commit-lang skipped' && _x12_skip="present"
assert_eq "X12: excluded repo + CJK staged → pre-commit allows (real skip, not fail-open)" \
    "rc:zero block:absent skipped:absent" \
    "$_x12_v block:$_x12_block skipped:$_x12_skip"

# X13: CODE_LANG_EXCLUDE non-empty but does not cover this repo → still blocks.
# Regression guard against over-skipping; this is the pre-existing behavior and
# is expected to be GREEN even before the feature lands.
_x13_repo="$(make_git_repo x13)"
printf 'const msg = "日本語テスト";\n' > "$_x13_repo/test.js"
git -C "$_x13_repo" add test.js
_x13_out="$(run_precommit "$_x13_repo" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
    "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
_x13_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x13_v="rc:zero"; [ "$_x13_rc" -ne 0 ] && _x13_v="rc:nonzero"
_x13_block="absent"; printf '%s' "$_x13_out" | grep -qF "$LANG_BLOCK_MARKER" && _x13_block="present"
assert_eq "X13: non-matching CODE_LANG_EXCLUDE + CJK staged → pre-commit still blocks" \
    "rc:nonzero block:present" \
    "$_x13_v block:$_x13_block"

# X14: CODE_LANG_EXCLUDE delivered via a stubbed .env under an isolated
# AGENTS_CONFIG_DIR (same pattern as CL-I10). Two entries, only the second
# matches. $EXCLUDE_FROM_DOTENV opts this call out of lib.sh's process-env
# isolation sentinel — here the .env IS the source under test. The stub dir must
# carry every module the require graph needs — path-coverage-match.js /
# glob-match.js / path-normalize.js included — otherwise require() throws, the
# hook fails open, and rc=0 would be a false green. The "skipped ABSENT"
# assertion is exactly what detects that.
_x14_cfg="$TMPDIR_BASE/cfg-x14"
mkdir -p "$_x14_cfg/hooks/lib"
_x14_repo="$(make_git_repo x14)"
printf 'const msg = "日本語テスト";\n' > "$_x14_repo/test.js"
git -C "$_x14_repo" add test.js
_x14_root="$(git -C "$_x14_repo" rev-parse --show-toplevel)"
printf 'CODE_LANG=english\nCODE_LANG_EXCLUDE=%s;%s\n' "$_X_MISS_A" "$_x14_root" > "$_x14_cfg/.env"
for _x14_mod in lint-commit-lang.js detect-cjk.js lang-config.js lint-plan-lang.js \
                load-env.js agents-config-dir.js path-normalize.js \
                path-coverage-match.js glob-match.js; do
    cp "$AGENTS_DIR/hooks/lib/$_x14_mod" "$_x14_cfg/hooks/lib/" 2>/dev/null || true
done
_x14_out="$(run_precommit "$_x14_repo" "AGENTS_CONFIG_DIR=$_x14_cfg" "ENFORCE_WORKTREE=off" \
    "$EXCLUDE_FROM_DOTENV")"
_x14_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
_x14_v="rc:nonzero"; [ "$_x14_rc" -eq 0 ] && _x14_v="rc:zero"
_x14_block="absent"; printf '%s' "$_x14_out" | grep -qF "$LANG_BLOCK_MARKER" && _x14_block="present"
_x14_skip="absent"; printf '%s' "$_x14_out" | grep -q 'lint-commit-lang skipped' && _x14_skip="present"
assert_eq "X14: CODE_LANG_EXCLUDE from .env (2 entries, 2nd matches) → allowed via the real matcher" \
    "rc:zero block:absent skipped:absent" \
    "$_x14_v block:$_x14_block skipped:$_x14_skip"

# X26a/X26b: DEFAULT (backward-compatibility) guard through the real
# hooks/pre-commit path. X13 covers a non-matching value; X11 covers an empty
# value but at the unit layer with NOTHING staged, so neither proves that the
# untouched default still catches a real language violation end to end.
#
# Two states are covered because hooks/lib/load-env.js treats an empty
# process.env value as UNSET: "key absent from .env" and "key present but empty"
# reach loadCodeLangExclude() by different routes and must both behave as
# "no exclusions". `env -u CODE_LANG_EXCLUDE` strips any inherited value and
# tells lib.sh's isolation helper this case decides the variable itself, so the
# stubbed .env is genuinely the only possible source.
#
# The stub AGENTS_CONFIG_DIR carries the same module set as X14 — a missing
# module makes require() throw, the hook fails open with rc=0, and the case
# would be false-green on rc alone. "skipped ABSENT" is the assertion that
# detects it; "block PRESENT" pins that the block is a language block rather
# than the worktree gate or the private-info scanner.
_x26_mk_cfg() {
    local cfg="$1" excl_line="$2" mod
    mkdir -p "$cfg/hooks/lib"
    printf 'CODE_LANG=english\n%s' "$excl_line" > "$cfg/.env"
    for mod in lint-commit-lang.js detect-cjk.js lang-config.js lint-plan-lang.js \
               load-env.js agents-config-dir.js path-normalize.js \
               path-coverage-match.js glob-match.js; do
        cp "$AGENTS_DIR/hooks/lib/$mod" "$cfg/hooks/lib/" 2>/dev/null || true
    done
}

# _x26_probe <label> <cfg-dir> — stage CJK, run the real hook, assert blocked.
_x26_probe() {
    local label="$1" cfg="$2" repo out rc v block skip
    repo="$(make_git_repo "${label//:/-}")"
    printf 'const msg = "日本語テスト";\n' > "$repo/test.js"
    git -C "$repo" add test.js
    out="$(run_precommit "$repo" -u CODE_LANG_EXCLUDE \
        "AGENTS_CONFIG_DIR=$cfg" "ENFORCE_WORKTREE=off")"
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

# ---------------------------------------------------------------------------
# E — process-env vs .env precedence (X19)
# ---------------------------------------------------------------------------
# X1..X18 never put a CONFLICTING value in both sources at once, so none of them
# can tell "the env var won" from "the .env won". X19 pins the dotenv-style
# precedence contract of hooks/lib/load-env.js (a non-empty process.env value is
# never overwritten by .env) in BOTH directions — one direction alone would be
# satisfied by whichever source happens to be consulted.
#
# AGENTS_CONFIG_DIR is stubbed at an isolated dir holding ONLY a .env: the check()
# driver requires the real hooks/lib/lint-commit-lang.js by absolute path, so
# (unlike the X14 pre-commit stub) no module copies are needed there. CODE_LANG is
# supplied as a real env var because the short-circuit on an explicit
# AGENTS_CONFIG_DIR means the real repo's .env is never read.
_x19_cfg_a="$TMPDIR_BASE/cfg-x19a"
_x19_cfg_b="$TMPDIR_BASE/cfg-x19b"
mkdir -p "$_x19_cfg_a" "$_x19_cfg_b"

# X19a: .env says "excluded" (matches the repo root), process env says "not
# excluded" (sentinel miss). The env var must win → the check still blocks.
if require_sut "X19a" "$LINT_LIB"; then
    _x19a_repo="$(make_git_repo x19a)"
    printf 'const msg = "日本語テスト";\n' > "$_x19a_repo/test.js"
    git -C "$_x19a_repo" add test.js
    _x19a_root="$(git -C "$_x19a_repo" rev-parse --show-toplevel)"
    printf 'CODE_LANG_EXCLUDE=%s\n' "$_x19a_root" > "$_x19_cfg_a/.env"
    _x19a_out="$(run_check_node_raw "$_x19a_repo" \
        "CODE_LANG=english" \
        "CODE_LANG_EXCLUDE=$_X_MISS_A" \
        "AGENTS_CONFIG_DIR=$_x19_cfg_a")"
    _x19a_got="$(printf '%s' "$_x19a_out" | _x_classify)"
    assert_eq "X19a: process-env CODE_LANG_EXCLUDE (non-matching) overrides a matching .env value → still blocks" \
        "nonempty" "$_x19a_got"
fi

# X19b: mirror — .env says "not excluded", process env says "excluded".
# Same precedence rule, opposite outcome: the env var must win → skip.
if require_sut "X19b" "$LINT_LIB"; then
    _x19b_repo="$(make_git_repo x19b)"
    printf 'const msg = "日本語テスト";\n' > "$_x19b_repo/test.js"
    git -C "$_x19b_repo" add test.js
    _x19b_root="$(git -C "$_x19b_repo" rev-parse --show-toplevel)"
    printf 'CODE_LANG_EXCLUDE=%s\n' "$_X_MISS_B" > "$_x19_cfg_b/.env"
    _x19b_out="$(run_check_node_raw "$_x19b_repo" \
        "CODE_LANG=english" \
        "CODE_LANG_EXCLUDE=$_x19b_root" \
        "AGENTS_CONFIG_DIR=$_x19_cfg_b")"
    _x19b_got="$(printf '%s' "$_x19b_out" | _x_classify)"
    assert_eq "X19b: process-env CODE_LANG_EXCLUDE (matching) overrides a non-matching .env value → skips" \
        "empty" "$_x19b_got"
fi

# ---------------------------------------------------------------------------
# F — exclude gate symmetry across CODE_LANG policy tiers (X20)
# ---------------------------------------------------------------------------
# Every other matching case runs CODE_LANG=english. The planned gate sits at the
# TOP of check(), before the policy switch, and returns { violations: [], hints: [] },
# so it must behave identically for the other strict policy (japanese) and for the
# hint tier (any other non-empty token — classifyPolicy() in hooks/lib/lang-config.js).
# Each matching case is paired with a non-matching control so that "empty" cannot
# be a false green from a fixture that never violated in the first place.

# X20a/X20b: strict policy `japanese`. Fixture = a long English-only run, the same
# content CL-U5 uses to produce a japanese-policy violation.
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

# X20c/X20d: hint tier (`french`, per CL-U6) — CJK content normally lands in
# `hints`, not `violations`. The gate returns both arrays empty, so the matching
# case must suppress the HINTS as well; asserting only on violations would pass
# even if the gate were never reached.
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

# ---------------------------------------------------------------------------
# H — CODE_LANG_EXCLUDE is inert data, never a shell command (X24)
# ---------------------------------------------------------------------------
# CODE_LANG_EXCLUDE arrives from .env / the environment and is user-controlled.
# hooks/pre-commit is a bash script, so any future `eval`, unquoted expansion, or
# string-interpolated subshell in the CODE_LANG block would turn the value into
# executable code. This case feeds a value carrying `$(...)`, backticks and `;`
# separators and proves NON-EXECUTION directly: two marker files that the injected
# commands would create must still be absent afterwards. Asserting only "it did not
# crash" would be false-green — a successful injection does not crash.
#
# The markers live inside TMPDIR_BASE (removed by lib.sh's EXIT trap regardless of
# pass/fail), never in the shared system /tmp, so a genuine escape leaves no
# artifact outside the test sandbox.
#
# None of the four entries can cover the repo root, so the normal non-matching
# outcome must still hold: CJK stays blocked. That pairing is the "inert DATA"
# half of the claim — the value is parsed as paths, not run.
# NOTE: unlike the other new cases this one is GREEN before the feature lands
# (CODE_LANG_EXCLUDE is simply ignored today); it is a standing regression guard,
# in the same spirit as X13.
_x24_sandbox="$TMPDIR_BASE/inject-x24"
mkdir -p "$_x24_sandbox"
_x24_m1="$_x24_sandbox/pwned-subst"
_x24_m2="$_x24_sandbox/pwned-backtick"
rm -f "$_x24_m1" "$_x24_m2"
# Single-quoted printf format: bash must NOT expand the payload here — only the
# hook under test is allowed the opportunity, and it must decline.
_x24_val="$(printf '%s; $(touch %s); `touch %s`;%s' \
    "$_X_MISS_A" "$_x24_m1" "$_x24_m2" "$_X_MISS_B")"
_x24_repo="$(make_git_repo x24)"
printf 'const msg = "日本語テスト";\n' > "$_x24_repo/test.js"
git -C "$_x24_repo" add test.js
_x24_out="$(run_precommit "$_x24_repo" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
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

# ---------------------------------------------------------------------------
# I — exclude-skip audit trace through hooks/pre-commit (X30)
# ---------------------------------------------------------------------------
# A repo-level exclusion suppresses a real language violation, so the bypass has
# to be VISIBLE in commit output — otherwise a stale CODE_LANG_EXCLUDE entry
# silently disables the policy and nothing in the commit transcript says so.
# check() reports the skip via `excluded: true` and hooks/pre-commit turns that
# into one fixed line on stderr. The trace carries the reason token ONLY: no
# entry value and no path, so a CODE_LANG_EXCLUDE holding a private path cannot
# leak into commit output.
#
# X12 already pins the allow-outcome of the same scenario, but rc=0 is reached
# identically by a genuine skip, an accidental fail-open, and a fixture that
# never violated — none of which the trace should claim. So the line is asserted
# PRESENT on a real match (X30a) and ABSENT in both non-skip states: a
# non-matching value that still blocks (X30b) and a non-matching value over
# clean content that passes anyway (X30c). X30c is the case that separates
# "printed on an exclude skip" from "printed on every successful hook run" —
# X30b alone would be satisfied by a line that is merely tied to rc=0.
#
# grep -F: the literal carries parentheses, which are regex metacharacters.
# The trace's "lint-commit-lang: skipped (…)" does not collide with the
# fail-open "lint-commit-lang skipped (…)" the other cases grep for — the colon
# distinguishes them, so `skipped:absent` below still means "did not fail open".
_X_AUDIT_TRACE="lint-commit-lang: skipped (CODE_LANG_EXCLUDE match)"

# _x30_probe <label> <content> <exclude-mode> — stage <content>, run the real
# hook, and report rc / language-block / fail-open / audit-trace state.
# <exclude-mode>: "match" → CODE_LANG_EXCLUDE = this repo's root; "miss" → a
# sentinel path that cannot cover any repo root.
_x30_probe() {
    local label="$1" content="$2" mode="$3" repo root excl out rc v block skip audit
    repo="$(make_git_repo "$label")"
    printf '%s' "$content" > "$repo/test.js"
    git -C "$repo" add test.js
    root="$(git -C "$repo" rev-parse --show-toplevel)"
    excl="$_X_MISS_A"
    [ "$mode" = "match" ] && excl="$root"
    out="$(run_precommit "$repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
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
