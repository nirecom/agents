# tests/feature-1180-commit-lang-check/group-exclude-failopen.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X — C: fail-open when the repository root cannot be determined.
# Cases X10, X11 (unit), X27 (unit precondition-probe) and X17, X18, X28, X29
# (integration). Sourced by group-exclude.sh after group-exclude-lib.sh. The
# Windows PATH-shim limitation behind X17/X28/X29 is documented in the TL3 gap
# block of group-exclude.sh.
#
# The planned repoRoot() returns null on THREE distinct git-failure branches
# (r.error / r.status !== 0 / empty stdout). All three must produce the same
# fail-open outcome, and each branch is reached by a different fault. Do not
# conflate the cases:
#   X10, X11, X18 → the `r.status !== 0` branch (git RUNS, exits 128 from a
#                   non-repo cwd — real fault, no mock).
#   X17           → same 128-exit branch, but forced at the integration layer
#                   through a PATH shim (POSIX-only).
#   X27           → the `r.error` branch, as an isolated spawnSync PROBE: it
#                   pins the primitive's error shape, never the hook.
#   X28           → the `r.error` branch at the INTEGRATION layer — git absent
#                   from PATH entirely, driven through the real hooks/pre-commit
#                   (POSIX-only). This is what X27 cannot do.
#   X29           → the "git exits 0 with EMPTY stdout" branch, via a PATH shim
#                   that returns success-with-no-output for
#                   `rev-parse --show-toplevel` only (POSIX-only).
# Every branch of the planned repoRoot() therefore has integration coverage on
# POSIX; on Windows the r.error / empty-stdout branches rest on X27 plus the
# non-repo-cwd cases X10/X11/X18 (see the TL3 gap block in group-exclude.sh).

# A plain temp directory that is NOT a git repo. Real fault injection: no mock,
# no shim — `git rev-parse --show-toplevel` genuinely fails here.
_X_NONREPO="$TMPDIR_BASE/nonrepo-$RANDOM-$$"
mkdir -p "$_X_NONREPO"
_X_NONREPO_OK=yes
if (cd "$_X_NONREPO" && git rev-parse --show-toplevel >/dev/null 2>&1); then
    _X_NONREPO_OK=no
fi

# X10 (unit, all platforms): non-repo cwd + non-empty non-matching exclude list
# → check() must THROW. The throw is what hooks/pre-commit's catch turns into
# "lint-commit-lang skipped (...)" + exit 0 (fail-open). The gate runs before any
# staged-file scanning, so this fires even though nothing is staged here.
#
# The exclude value carries a unique marker token. The thrown message is allowed
# to name the KEY (CODE_LANG_EXCLUDE) and the reason ("repository root"), but it
# must NOT interpolate the VALUE: CODE_LANG_EXCLUDE is user/site configuration
# that ends up in commit-time terminal output and CI logs, so echoing it back is
# an avoidable disclosure. Asserting the token's ABSENCE pins that separately
# from the two presence assertions — one of the three can fail on its own.
_X10_TOKEN="CLE-LEAKCANARY-9f2c71"
_X10_VALUE="$_X_PARENT/__cle-no-such-dir-${_X10_TOKEN}__"
if [ "$_X_NONREPO_OK" != "yes" ]; then
    echo "SKIP: X10: Skipped-Because: the temp directory is itself inside a git repository on this host, so repo-root detection cannot be made to fail without a mock"
elif require_sut "X10" "$LINT_LIB"; then
    _x10_out="$(run_check_node_raw "$_X_NONREPO" \
        "CODE_LANG=english" \
        "CODE_LANG_EXCLUDE=$_X10_VALUE" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR")"
    _x10_rc="$(cat "$TMPDIR_BASE/.last_cn_rc" 2>/dev/null || echo 0)"
    _x10_v="rc:zero"
    [ "$_x10_rc" -ne 0 ] && _x10_v="rc:nonzero"
    _x10_key="absent"
    printf '%s' "$_x10_out" | grep -q 'CODE_LANG_EXCLUDE' && _x10_key="present"
    _x10_msg="absent"
    printf '%s' "$_x10_out" | grep -q 'repository root' && _x10_msg="present"
    # stdout+stderr are merged by run_check_node_raw, so this covers both.
    _x10_leak="absent"
    printf '%s' "$_x10_out" | grep -qF "$_X10_TOKEN" && _x10_leak="present"
    assert_eq "X10: non-repo cwd + non-empty CODE_LANG_EXCLUDE → check() throws (enables hook fail-open) without echoing the value" \
        "rc:nonzero key:present rootmsg:present valueleak:absent" \
        "$_x10_v key:$_x10_key rootmsg:$_x10_msg valueleak:$_x10_leak"
fi

# X11 (unit, all platforms): same non-repo cwd, but CODE_LANG_EXCLUDE genuinely
# EMPTY. AGENTS_CONFIG_DIR is stubbed at an isolated directory with NO .env so
# the real repo's .env can never supply a value (load-env.js short-circuits on an
# explicit AGENTS_CONFIG_DIR), and `env -u` removes any inherited value — which
# also tells lib.sh's isolation helper that this case decides the variable itself.
# Expectation: no throw, no git invocation, plain empty result — byte-identical
# to the behavior that existed before this feature.
_x11_cfg="$TMPDIR_BASE/cfg-x11"
mkdir -p "$_x11_cfg"
if [ "$_X_NONREPO_OK" != "yes" ]; then
    echo "SKIP: X11: Skipped-Because: the temp directory is itself inside a git repository on this host (see X10)"
elif require_sut "X11" "$LINT_LIB"; then
    _x11_out="$(run_check_node_raw "$_X_NONREPO" \
        -u CODE_LANG_EXCLUDE \
        "CODE_LANG=english" \
        "AGENTS_CONFIG_DIR=$_x11_cfg")"
    _x11_rc="$(cat "$TMPDIR_BASE/.last_cn_rc" 2>/dev/null || echo 0)"
    _x11_v="rc:nonzero"
    [ "$_x11_rc" -eq 0 ] && _x11_v="rc:zero"
    _x11_res="$(printf '%s' "$_x11_out" | node -e '
        let d="";
        process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{
            try {
                const r=JSON.parse(d);
                console.log(r.violations && r.violations.length===0 ? "empty" : "nonempty");
            } catch(e) { console.log("error"); }
        })' 2>/dev/null)"
    assert_eq "X11: non-repo cwd + empty CODE_LANG_EXCLUDE → no throw, git never consulted" \
        "rc:zero violations:empty" \
        "$_x11_v violations:$_x11_res"
fi

# X27 (unit precondition-probe, all platforms): the `r.error` branch of the
# planned repoRoot() — child_process.spawnSync() failing to LAUNCH git at all
# (ENOENT / EACCES), as opposed to git launching and exiting 128 (X10/X11/X17/X18).
#
# This deliberately does NOT call repoRoot(): the SUT does not exist yet
# (test-first), and X17's header records why a real spawn-failure PATH shim for
# `git` is infeasible on Windows. What it DOES pin is the primitive contract the
# planned `returns null if r.error` branch is written against — that spawnSync
# reports a launch failure as a truthy `error` object with an ENOENT-shaped
# `code`, rather than by throwing or by returning status!==0. If Node ever
# changed that shape, repoRoot()'s r.error branch would silently stop firing and
# nothing else in this group would notice.
#
# Keep it a probe: no git repo, no hook, no fixture.
_x27_out="$(run_with_timeout 15 node -e '
    const { spawnSync } = require("child_process");
    const r = spawnSync("this-binary-definitely-does-not-exist-xyz123",
        ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
    const has = r.error ? "present" : "absent";
    const code = (r.error && r.error.code) ? r.error.code : "none";
    const threw = "no";
    process.stdout.write("error:" + has + " code:" + code + " threw:" + threw);
' 2>/dev/null)"
assert_eq "X27: spawnSync() launch failure surfaces as a truthy ENOENT-shaped r.error (precondition for repoRoot()'s r.error branch)" \
    "error:present code:ENOENT threw:no" \
    "$_x27_out"

# X28 (POSIX-only): the SAME `r.error` branch as X27, but exercised through the
# REAL hooks/pre-commit path instead of a standalone spawnSync probe. X27 proves
# the primitive's error shape; only X28 can show that the hook FAILS OPEN when
# git cannot be launched at all.
#
# Fault: git is absent from PATH entirely — a strictly more radical manipulation
# than X17's shim (which keeps a working `git` for every other subcommand). PATH
# is rebuilt as a symlink farm holding the interpreters and coreutils that
# hooks/pre-commit needs, and deliberately NO `git`. Stripping PATH outright is
# not an option: `env` resolves `bash` through the NEW PATH, and the hook itself
# shells out to node/printenv/tr.
#
# ENFORCE_WORKTREE=off for the same reason as X17: the worktree gate runs its own
# git calls, and letting those fail would confound the assertion.
#
# Pre-feature this is RED by construction: today's stagedFiles() already tolerates
# a spawn failure by returning [], so the hook exits 0 with NO skipped notice.
# "skipped:present" is exactly the discriminator between that silent no-op and the
# planned explicit fail-open — rc alone would be false-green.
if [ "$_X_PLATFORM" = "win32" ]; then
    echo "SKIP: X28: Skipped-Because: on Windows git-bash the interpreters the hook needs (bash, node) live alongside git.exe and PATH search is extension-driven, so a PATH with no resolvable git cannot be built without also breaking the hook — same class of gap as X17, see the TL3 gap block in group-exclude.sh (platform=$_X_PLATFORM)"
else
    _X28_TOKEN="CLE-LEAKCANARY-28e4a0"
    _x28_bin="$TMPDIR_BASE/nogit-x28"
    mkdir -p "$_x28_bin"
    for _x28_c in bash sh env node printenv dirname basename cat tr grep sed awk \
                  ls mkdir rm find head tail sort wc uname timeout perl file; do
        _x28_p="$(command -v "$_x28_c" 2>/dev/null || true)"
        [ -n "$_x28_p" ] && ln -sf "$_x28_p" "$_x28_bin/$_x28_c"
    done
    # Precondition: the farm must genuinely resolve no `git`. If it does, the
    # fault was never injected and a passing assertion would be meaningless.
    _x28_has_git=no
    PATH="$_x28_bin" command -v git >/dev/null 2>&1 && _x28_has_git=yes
    if [ "$_x28_has_git" = "yes" ]; then
        echo "SKIP: X28: Skipped-Because: a git binary is still resolvable from the isolated PATH farm, so the spawn-failure fault cannot be injected on this host"
    else
        _x28_repo="$(make_git_repo x28)"
        printf 'const msg = "日本語テスト";\n' > "$_x28_repo/test.js"
        git -C "$_x28_repo" add test.js
        _x28_out="$(run_precommit "$_x28_repo" \
            "PATH=$_x28_bin" \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
            "CODE_LANG=english" \
            "CODE_LANG_EXCLUDE=$_X_PARENT/__cle-no-such-dir-${_X28_TOKEN}__")"
        _x28_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
        _x28_v="rc:nonzero"; [ "$_x28_rc" -eq 0 ] && _x28_v="rc:zero"
        _x28_skip="absent"; printf '%s' "$_x28_out" | grep -q 'lint-commit-lang skipped' && _x28_skip="present"
        _x28_block="absent"; printf '%s' "$_x28_out" | grep -qF "$LANG_BLOCK_MARKER" && _x28_block="present"
        # stdout+stderr are merged by run_precommit, so this covers both.
        _x28_leak="absent"; printf '%s' "$_x28_out" | grep -qF "$_X28_TOKEN" && _x28_leak="present"
        assert_eq "X28: git absent from PATH (spawn failure) → pre-commit fails open, does not block, does not echo the exclude value" \
            "rc:zero skipped:present block:absent valueleak:absent" \
            "$_x28_v skipped:$_x28_skip block:$_x28_block valueleak:$_x28_leak"
    fi
fi

# X17 (POSIX-only): real PATH-shim fault injection at the integration layer.
# A `git` shim fails ONLY `rev-parse --show-toplevel` and exec-delegates every
# other subcommand to the real binary, so staging/diffing still work.
# ENFORCE_WORKTREE=off is required: hooks/pre-commit itself calls
# `git rev-parse --show-toplevel` in the worktree gate, which the shim would
# otherwise break, confounding the assertion.
if [ "$_X_PLATFORM" = "win32" ]; then
    echo "SKIP: X17: Skipped-Because: Node's spawnSync(\"git\", ...) on Windows cannot execute an extensionless shell script found via PATH, so a git shim is unreachable from lint-commit-lang.js — see the TL3 gap block in group-exclude.sh (platform=$_X_PLATFORM)"
else
    _x17_real_git="$(command -v git 2>/dev/null || echo /usr/bin/git)"
    _x17_shim="$TMPDIR_BASE/shim-x17"
    mkdir -p "$_x17_shim"
    printf '#!/bin/sh\ncase " $* " in *" --show-toplevel "*) echo "git shim: forced rev-parse failure" >&2; exit 128 ;; esac\nexec %s "$@"\n' \
        "$_x17_real_git" > "$_x17_shim/git"
    chmod +x "$_x17_shim/git"
    _x17_repo="$(make_git_repo x17)"
    printf 'const msg = "日本語テスト";\n' > "$_x17_repo/test.js"
    git -C "$_x17_repo" add test.js
    _x17_out="$(run_precommit "$_x17_repo" \
        "PATH=$_x17_shim:$PATH" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
    _x17_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x17_v="rc:nonzero"; [ "$_x17_rc" -eq 0 ] && _x17_v="rc:zero"
    _x17_skip="absent"; printf '%s' "$_x17_out" | grep -q 'lint-commit-lang skipped' && _x17_skip="present"
    _x17_block="absent"; printf '%s' "$_x17_out" | grep -qF "$LANG_BLOCK_MARKER" && _x17_block="present"
    assert_eq "X17: repo-root detection fails (PATH shim) → pre-commit fails open, does not block" \
        "rc:zero skipped:present block:absent" \
        "$_x17_v skipped:$_x17_skip block:$_x17_block"
fi

# X29 (POSIX-only): the third repoRoot() branch — git SUCCEEDS (exit 0) but
# prints NOTHING for `rev-parse --show-toplevel`. Neither r.error nor a non-zero
# status fires here, so an implementation that only guarded those two would treat
# "" as the repo root and silently compare every exclude entry against the empty
# string. It is reachable only by shimming git's stdout, hence the same PATH-shim
# technique as X17 (and the same Windows limitation).
#
# The shim intercepts ONLY --show-toplevel and exec-delegates every other
# subcommand to the real binary, so staging and diffing still work — without that
# delegation the case would degenerate into X28's git-absent scenario and stop
# testing the empty-stdout branch at all.
#
# Pre-feature this is RED: nothing consumes --show-toplevel today, so the CJK
# fixture is scanned normally and the commit is blocked.
if [ "$_X_PLATFORM" = "win32" ]; then
    echo "SKIP: X29: Skipped-Because: Node's spawnSync(\"git\", ...) on Windows cannot execute an extensionless shell script found via PATH, so the empty-stdout git shim is unreachable from lint-commit-lang.js — same constraint as X17, see the TL3 gap block in group-exclude.sh (platform=$_X_PLATFORM)"
else
    _x29_real_git="$(command -v git 2>/dev/null || echo /usr/bin/git)"
    _x29_shim="$TMPDIR_BASE/shim-x29"
    mkdir -p "$_x29_shim"
    # exit 0 with byte-empty stdout for --show-toplevel; transparent otherwise.
    printf '#!/bin/sh\ncase " $* " in *" --show-toplevel "*) exit 0 ;; esac\nexec %s "$@"\n' \
        "$_x29_real_git" > "$_x29_shim/git"
    chmod +x "$_x29_shim/git"
    _x29_repo="$(make_git_repo x29)"
    printf 'const msg = "日本語テスト";\n' > "$_x29_repo/test.js"
    git -C "$_x29_repo" add test.js
    _x29_out="$(run_precommit "$_x29_repo" \
        "PATH=$_x29_shim:$PATH" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
    _x29_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x29_v="rc:nonzero"; [ "$_x29_rc" -eq 0 ] && _x29_v="rc:zero"
    _x29_skip="absent"; printf '%s' "$_x29_out" | grep -q 'lint-commit-lang skipped' && _x29_skip="present"
    _x29_block="absent"; printf '%s' "$_x29_out" | grep -qF "$LANG_BLOCK_MARKER" && _x29_block="present"
    assert_eq "X29: git exits 0 with empty stdout for --show-toplevel → pre-commit fails open, does not block" \
        "rc:zero skipped:present block:absent" \
        "$_x29_v skipped:$_x29_skip block:$_x29_block"
fi

# X18 (integration, all platforms): run hooks/pre-commit from a non-repo cwd.
# Verified empirically that execution reaches the CODE_LANG block there (the
# earlier `set -euo pipefail` sections all run their failing git calls inside
# `if` conditions or command substitutions, so none of them abort the hook).
if [ "$_X_NONREPO_OK" != "yes" ]; then
    echo "SKIP: X18: Skipped-Because: the temp directory is itself inside a git repository on this host (see X10)"
else
    _x18_out="$(run_precommit "$_X_NONREPO" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
    _x18_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x18_v="rc:nonzero"; [ "$_x18_rc" -eq 0 ] && _x18_v="rc:zero"
    _x18_skip="absent"; printf '%s' "$_x18_out" | grep -q 'lint-commit-lang skipped' && _x18_skip="present"
    assert_eq "X18: pre-commit from a non-repo cwd + non-empty CODE_LANG_EXCLUDE → fails open (rc 0 + skipped notice)" \
        "rc:zero skipped:present" \
        "$_x18_v skipped:$_x18_skip"
fi
