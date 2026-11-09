# Part of tests/bin/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh
# Tags: test-selection, merge-base, zero-commit, degradation, path-edge-cases, injection, scope:issue-specific, pwsh-not-required, TL2

# S27 — the working-tree fallback unions two git commands, and every naive union (pipeline,
# unquoted `for`, xargs, sort) mangles a non-word path: space word-splits, a leading dash is
# read as an OPTION (argument injection), shell metachars execute unquoted, an embedded newline
# desyncs line parsing. All fail QUIETLY (exit 0, wrong list). Three cases assert positively; the
# newline case (git quotes it; Windows/MSYS can't hold a literal one) only asserts CONTROL survives + exit 0.

# The hostile source paths and the fake `bin/<name>.sh` test each must select. bin/ is the
# simplest stem rule — the row tests the path surviving the pipeline, not which stem rule applies.
ZC_HOSTILE_NAMES=(
    'zc space'
    '-zc-dash'
    "zc\$(id)&;'x"
)

test_S27_zero_commit_hostile_filenames() {
    local repo="$TMPDIR_BASE/s27"
    local n src want created=() wants=()
    make_zero_commit_repo "$repo" staged "bin/select-tests.sh" || return
    assert_zero_commit "S27_zero_commit_hostile_filenames" "$repo" || return

    # Each hostile file gets a test file whose name CONTAINS the stem, so a correct selector has
    # something to print. They live in this row's own target repo (the selector lists the target's
    # tests, #2473), so no shared tree is touched; a path under tests/ yields no stem of its own.
    for n in "${ZC_HOSTILE_NAMES[@]}"; do
        src="$repo/bin/${n}.sh"
        want="tests/bin/feature-1779-${n}.sh"
        if ! printf 'change\n' > "$src" 2>/dev/null || [ ! -e "$src" ]; then
            skip "S27_zero_commit_hostile_filenames[$n]: this filesystem will not hold the name"
            continue
        fi
        : > "$repo/${want}" 2>/dev/null || true
        if [ ! -e "$repo/${want}" ]; then
            skip "S27_zero_commit_hostile_filenames[$n]: the matching test file could not be created"
            rm -f -- "$src"
            continue
        fi
        created+=("$n")
        wants+=("$want")
    done

    # Half staged, half untracked: the union has two halves and a quoting defect in either one
    # would otherwise be masked by the other. Everything created so far is staged here; the
    # newline fixture below is created afterwards and stays untracked.
    git -C "$repo" add -A >/dev/null 2>&1 || true

    # The newline case. Created after the `add` on purpose — an untracked path is the one git
    # reports through `ls-files`, which is the half where a raw (unquoted) implementation would
    # desynchronise.
    local nlsrc="$repo/bin/zc"$'\n'"nl.sh" nl_ok=0
    if printf 'change\n' > "$nlsrc" 2>/dev/null && [ -e "$nlsrc" ]; then
        nl_ok=1
    fi

    if [ "${#created[@]}" -eq 0 ] && [ "$nl_ok" = "0" ]; then
        skip "S27_zero_commit_hostile_filenames: no hostile fixture could be created on this host"
        return
    fi

    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off

    local rc="$SA_RC" out="$SA_OUT" err="$SA_ERR"

    if [ "$rc" != "0" ]; then
        fail "S27_zero_commit_hostile_filenames: expected exit 0, got rc=$rc — a hostile path broke the pipeline outright
--- stderr ---
$err"
        return
    fi
    # The control. If this is missing the run selected nothing at all and every assertion below
    # would be reporting the #1779 bug rather than a quoting defect.
    if ! printf '%s\n' "$out" | grep -qF "tests/bin/feature-689-select-tests.sh"; then
        fail "S27_zero_commit_hostile_filenames: the ordinary staged change selected nothing, so nothing about the hostile names is proven
--- output ---
$out
--- stderr ---
$err"
        return
    fi

    local i missing=""
    for i in "${!created[@]}"; do
        if ! printf '%s\n' "$out" | grep -qF -- "${wants[$i]}"; then
            missing="$missing [${created[$i]}]"
        fi
    done
    if [ -n "$missing" ]; then
        fail "S27_zero_commit_hostile_filenames: hostile paths dropped or mangled by the fallback:$missing
--- output ---
$out
--- stderr ---
$err"
    else
        pass "S27_zero_commit_hostile_filenames: spaces, a leading dash and shell metacharacters all survive the working-tree fallback (${#created[@]} name(s))"
    fi

    if [ "$nl_ok" = "1" ]; then
        # git quotes the control character, so however the path arrives it matches no stem rule
        # and is not selected. What a desynchronised parse produces instead is an EXTRA stem — a
        # fragment like `nl` or a quoted half — and the visible symptom of that is a selection
        # larger than the set of files that actually changed. So the assertion is exactness: the
        # output is the control plus the hostile names, and nothing else.
        # The selector emits the path it found the test at, which is rooted at the target repo, so
        # every comparison here is a SUFFIX match rather than an equality.
        local line extra=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in *"tests/bin/feature-689-select-tests.sh") continue ;; esac
            local known=0 w
            for w in ${wants[@]+"${wants[@]}"}; do
                case "$line" in *"$w") known=1 ;; esac
            done
            [ "$known" = "1" ] || extra="$extra [$line]"
        done <<< "$out"
        if [ -z "$extra" ]; then
            pass "S27_zero_commit_hostile_filenames[newline]: a path git has to quote adds no spurious entry, so the change set was not desynchronised"
        else
            fail "S27_zero_commit_hostile_filenames[newline]: a newline-bearing path produced extra selections:$extra
--- output ---
$out"
        fi
    else
        skip "S27_zero_commit_hostile_filenames[newline]: this filesystem rejects control characters in filenames"
    fi
}

# S27b — S27 stages every word-hostile name, so only the newline case reaches `git ls-files --others`.
# Here the hostile source is the sole change and untracked; its test is committed in base, so only
# the untracked half can produce the selection.
ZC_UNTRACKED_NAME="zcu odd \$x;&'(y)"

test_S27b_zero_commit_untracked_hostile_filename() {
    local row="S27b_zero_commit_untracked_hostile_filename" repo="$TMPDIR_BASE/s27b"
    local src="bin/${ZC_UNTRACKED_NAME}.sh" want="tests/bin/feature-1779-${ZC_UNTRACKED_NAME}.sh"
    mkdir -p "$repo/tests/bin"
    if ! : > "$repo/$want" 2>/dev/null || [ ! -e "$repo/$want" ]; then
        skip "$row: this filesystem will not hold the name"
        return
    fi
    make_zero_commit_repo "$repo" untracked "+$src" || return
    assert_zero_commit "$row" "$repo" || return
    if [ ! -e "$repo/$src" ] || [ -n "$(git -C "$repo" diff --name-only HEAD)" ]; then
        fail "$row: fixture premise broken — the hostile source is absent or git diff HEAD is non-empty, so the untracked half alone is not exercised"
        return
    fi
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    if [ "$SA_RC" != "0" ]; then
        fail "$row: expected exit 0, got rc=$SA_RC — the untracked hostile path broke the pipeline
--- stderr ---
$SA_ERR"
    elif printf '%s\n' "$SA_OUT" | grep -qF -- "$want"; then
        pass "$row: an untracked path with spaces and shell metacharacters survives the ls-files half"
    else
        fail "$row: the untracked hostile path was dropped or mangled by the ls-files half
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    fi
}
