# tests/hooks/feature-1180-commit-lang-check/group-exclude-failopen.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific, node-precommit
# Group X — C: repo-root detection failure. Unit X10/X11 (git exits 128), X27 (spawn-error probe);
# integration X17/X29 (PATH shims, POSIX) fail open; X18/X28 (non-repo cwd, git absent) block with a
# named reason since #2507, because the Node body reads the staged snapshot before any check.
# Sourced by group-exclude.sh after group-exclude-lib.sh; Windows gaps: its TL3 gap block.
# lang-check: ignore — the CJK fixture lines below are staged on purpose.

# A plain temp directory that is NOT a git repo: `git rev-parse --show-toplevel` genuinely fails.
_X_NONREPO="$TMPDIR_BASE/nonrepo-$RANDOM-$$"
mkdir -p "$_X_NONREPO"
_X_NONREPO_OK=yes
if (cd "$_X_NONREPO" && git rev-parse --show-toplevel >/dev/null 2>&1); then
    _X_NONREPO_OK=no
fi

# X10 (unit, all platforms): non-repo cwd + non-empty non-matching exclude list
# → check() must THROW; the pre-commit code-lang check turns the throw into
# "lint-commit-lang skipped (...)" + pass (fail-open). The gate runs before any
# staged-file scanning, so this fires even though nothing is staged here.
# The exclude value carries a unique marker token: the message may name the KEY
# (CODE_LANG_EXCLUDE) and the reason ("repository root") but must NOT echo the
# VALUE, which is site configuration that would reach terminal output and CI logs.
_X10_TOKEN="CLE-LEAKCANARY-9f2c71"
_X10_VALUE="$_X_PARENT/__cle-no-such-dir-${_X10_TOKEN}__"
if [ "$_X_NONREPO_OK" != "yes" ]; then
    echo "SKIP: X10: Skipped-Because: the temp directory is itself inside a git repository on this host, so repo-root detection cannot be made to fail without a mock"
elif require_sut "X10" "$LINT_LIB"; then
    _x10_out="$(run_check_node_raw "$_X_NONREPO" \
        "CODE_LANG=english" \
        "CODE_LANG_EXCLUDE=$_X10_VALUE" \
)"
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
# EMPTY. AGENTS_MAIN_ROOT is stubbed at an isolated directory with NO .env so
# the real repo's .env can never supply a value (load-env.js short-circuits on an
# explicit AGENTS_MAIN_ROOT), and `env -u` removes any inherited value — which
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
        "AGENTS_MAIN_ROOT=$_x11_cfg")"
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

# X27 (unit precondition-probe, all platforms): the `r.error` branch of repoRoot() —
# spawnSync() failing to LAUNCH git (ENOENT / EACCES), as opposed to git exiting 128
# (X10/X11/X17). It does not call repoRoot(); it pins the primitive contract that
# branch is written against: a launch failure is a truthy `error` with an
# ENOENT-shaped `code`, not a throw and not status!==0. If Node changed that shape,
# the r.error branch would silently stop firing and nothing else here would notice.
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

# X28 (POSIX-only): git absent from PATH entirely, driven through the real hooks/pre-commit.
# PATH is a symlink farm with the interpreters and coreutils the hook needs and NO `git`.
# ENFORCE_WORKTREE=off as in X17. #2507: the Node body reads the staged snapshot through git
# before any check, so a spawn failure blocks with the failing step named ("spawnSync git
# ENOENT"), never a silent pass; the exclude value must still not be echoed.
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
            "ENFORCE_WORKTREE=off" \
            "CODE_LANG=english" \
            "CODE_LANG_EXCLUDE=$_X_PARENT/__cle-no-such-dir-${_X28_TOKEN}__")"
        _x28_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
        _x28_v="rc:zero"; [ "$_x28_rc" -ne 0 ] && _x28_v="rc:nonzero"
        _x28_why="absent"; printf '%s' "$_x28_out" | grep -q 'ENOENT.*Commit blocked\.' && _x28_why="present"
        _x28_block="absent"; printf '%s' "$_x28_out" | grep -qF "$LANG_BLOCK_MARKER" && _x28_block="present"
        # stdout+stderr are merged by run_precommit, so this covers both.
        _x28_leak="absent"; printf '%s' "$_x28_out" | grep -qF "$_X28_TOKEN" && _x28_leak="present"
        assert_eq "X28: git absent from PATH (spawn failure) → pre-commit blocks naming the spawn failure, no language verdict, no exclude value echoed" \
            "rc:nonzero reason:present lang-block:absent valueleak:absent" \
            "$_x28_v reason:$_x28_why lang-block:$_x28_block valueleak:$_x28_leak"
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
        "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
    _x17_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x17_v="rc:nonzero"; [ "$_x17_rc" -eq 0 ] && _x17_v="rc:zero"
    _x17_skip="absent"; printf '%s' "$_x17_out" | grep -q 'lint-commit-lang skipped' && _x17_skip="present"
    _x17_block="absent"; printf '%s' "$_x17_out" | grep -qF "$LANG_BLOCK_MARKER" && _x17_block="present"
    assert_eq "X17: repo-root detection fails (PATH shim) → pre-commit fails open, does not block" \
        "rc:zero skipped:present block:absent" \
        "$_x17_v skipped:$_x17_skip block:$_x17_block"
fi

# X29 (POSIX-only): the third repoRoot() branch — git exits 0 but prints NOTHING for
# `rev-parse --show-toplevel`. Neither r.error nor a non-zero status fires, so an
# implementation guarding only those two would compare every exclude entry against "".
# The shim intercepts ONLY --show-toplevel and delegates every other subcommand to the
# real binary, so staging and diffing still work (else this degenerates into X28).
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
        "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
    _x29_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x29_v="rc:nonzero"; [ "$_x29_rc" -eq 0 ] && _x29_v="rc:zero"
    _x29_skip="absent"; printf '%s' "$_x29_out" | grep -q 'lint-commit-lang skipped' && _x29_skip="present"
    _x29_block="absent"; printf '%s' "$_x29_out" | grep -qF "$LANG_BLOCK_MARKER" && _x29_block="present"
    assert_eq "X29: git exits 0 with empty stdout for --show-toplevel → pre-commit fails open, does not block" \
        "rc:zero skipped:present block:absent" \
        "$_x29_v skipped:$_x29_skip block:$_x29_block"
fi

# X18 (integration, all platforms): hooks/pre-commit from a non-repo cwd. #2507: the staged
# snapshot fails first, so the hook blocks naming the failing git step instead of reaching
# the CODE_LANG check; the lint's own fail-open in a non-repo cwd stays pinned by X10/X11.
if [ "$_X_NONREPO_OK" != "yes" ]; then
    echo "SKIP: X18: Skipped-Because: the temp directory is itself inside a git repository on this host (see X10)"
else
    _x18_out="$(run_precommit "$_X_NONREPO" \
        "ENFORCE_WORKTREE=off" \
        "CODE_LANG=english" "CODE_LANG_EXCLUDE=$_X_MISS_A")"
    _x18_rc="$(cat "$TMPDIR_BASE/.last_pc_rc" 2>/dev/null || echo 0)"
    _x18_v="rc:zero"; [ "$_x18_rc" -ne 0 ] && _x18_v="rc:nonzero"
    _x18_why="absent"; printf '%s' "$_x18_out" | grep -q '^pre-commit: .*git diff --cached' && _x18_why="present"
    _x18_end="absent"; printf '%s' "$_x18_out" | grep -q 'Commit blocked\.' && _x18_end="present"
    _x18_block="absent"; printf '%s' "$_x18_out" | grep -qF "$LANG_BLOCK_MARKER" && _x18_block="present"
    assert_eq "X18: pre-commit from a non-repo cwd → blocks naming the failing git step, no language verdict" \
        "rc:nonzero reason:present blocked:present lang-block:absent" \
        "$_x18_v reason:$_x18_why blocked:$_x18_end lang-block:$_x18_block"
fi
