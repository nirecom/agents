# Part of tests/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh, bin/resolve-merge-base.sh
# Tags: test-selection, merge-base, zero-commit, degradation, trust-state, fault-injection, scope:issue-specific, pwsh-not-required, TL2

# S25-S26 — the two gaps S14-S24 leave about the working-tree fallback: which trust state it fires
# under, and what happens when one half fails. S25: RECORDED is the OTHER trustworthy state (a
# session-recorded baseline — where a #1779 user lands after recording a base to clear exit 4), so a
# fallback wired only into RESOLVED reproduces the bug for them (CPR-ORTH). S26: the degraded set
# unions TWO git commands; one half failing yields a PARTIAL set (worse than absent — it ships), so each half is failed alone and must give exit 1 + empty stdout like S19.

# S25: #1779's fixture, state=RECORDED, both halves present (modified tracked + brand-new file),
# so it fails if RECORDED reaches only part of the fallback; the degradation notice is asserted too.
test_S25_zero_commit_recorded_state_degrades() {
    local repo="$TMPDIR_BASE/s25"
    make_zero_commit_repo "$repo" staged "bin/select-tests.sh" "+bin/zero-commit.sh" || return
    assert_zero_commit "S25_zero_commit_recorded_state_degrades" "$repo" || return
    run_auto "$repo" RECORDED 0 BASE_IS_HEAD=true RUN_TL3=off
    local missing=""
    echo "$SA_OUT" | grep -q "tests/bin/feature-689-select-tests.sh" || missing="$missing [tracked stem]"
    echo "$SA_OUT" | grep -q "tests/bin/feature-1779-zero-commit.sh" || missing="$missing [untracked stem]"
    if [ "$SA_RC" != "0" ]; then
        fail "S25_zero_commit_recorded_state_degrades: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif [ -n "$missing" ]; then
        fail "S25_zero_commit_recorded_state_degrades: missing$missing — the fallback is wired to RESOLVED only, so a recorded baseline on a zero-commit branch still selects from the empty range
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    elif ! printf '%s\n' "$SA_ERR" | grep -qiE "$ZC_DEGRADE_RE"; then
        fail "S25_zero_commit_recorded_state_degrades: the range was switched without saying so on stderr
--- stderr ---
$SA_ERR"
    else
        pass "S25_zero_commit_recorded_state_degrades: state=RECORDED degrades to the working tree exactly as RESOLVED does"
    fi
}

# A `git` that fails ONE subcommand and forwards everything else to the real binary. Selecting by
# subcommand rather than by a regex over the whole command line is what keeps the injection off
# the committed-range call: `git diff --name-only <base>...HEAD` carries HEAD only inside the
# `...` token, while the tracked half of the fallback passes HEAD as an argument of its own.
#
#   ZC_GIT_FAIL_HALF=untracked   `git ls-files ...` fails
#   ZC_GIT_FAIL_HALF=tracked     any `git diff` with a bare HEAD argument fails
zc_make_git_shim() { # <dir> ; 0 on success
    local dir="$1" real
    real="$(command -v git)" || return 1
    mkdir -p "$dir"
    cat > "$dir/git" <<SHIM
#!/usr/bin/env bash
_half="\${ZC_GIT_FAIL_HALF:-}"
_hit=0
for _a in "\$@"; do
  case "\$_half:\$_a" in
    untracked:ls-files) _hit=1 ;;
    tracked:HEAD)       _hit=1 ;;
  esac
done
if [ "\$_half" = tracked ]; then
  case " \$* " in *" diff "*) : ;; *) _hit=0 ;; esac
fi
if [ "\$_hit" = 1 ]; then
  echo "fatal: injected git failure (half=\$_half)" >&2
  exit 128
fi
exec "$real" "\$@"
SHIM
    chmod +x "$dir/git" 2>/dev/null || true
    [ -x "$dir/git" ] || return 1
    return 0
}

# One S26 row. <half> names the half of the union that is made to fail; the other half is left
# working, which is the whole point — a selector that ignored the failure would still have real
# paths to print and would exit 0 with half the change set.
zc_fault_row() { # <row> <half> <desc>
    local row="$1" half="$2" desc="$3"
    local repo="$TMPDIR_BASE/$row" shim="$TMPDIR_BASE/$row-shim"
    make_zero_commit_repo "$repo" staged "bin/select-tests.sh" "+bin/zero-commit.sh" || return
    assert_zero_commit "$row" "$repo" || return
    if ! zc_make_git_shim "$shim"; then
        skip "$row: no usable git shim on this host, so the fault cannot be injected"
        return
    fi
    # Premise: the shim is transparent when it is not injecting. Without this the rows below
    # could pass because the shim broke git outright rather than because the selector failed
    # closed on one half.
    local probe
    probe="$(PATH="$shim:$PATH" git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    if [ "$probe" != "$(git -C "$repo" rev-parse HEAD)" ]; then
        fail "$row: fixture premise broken — the shim is not passing ordinary git calls through"
        return
    fi
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off \
        "PATH=$shim:$PATH" "ZC_GIT_FAIL_HALF=$half"
    if [ "$SA_RC" = "1" ] && [ -z "$SA_OUT" ]; then
        pass "$row: $desc"
    else
        fail "$row: expected exit 1 with an empty selection, got rc=$SA_RC
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    fi
}

# S26a: the untracked enumeration fails, the tracked one answers. A selector that swallowed the
# failure would print the tracked stem and exit 0 — a set that is silently missing every new
# file on a branch whose changes are mostly new files.
test_S26a_zero_commit_untracked_half_failure_is_exit_1() {
    zc_fault_row "S26a_zero_commit_untracked_half_failure_is_exit_1" untracked \
        "a failing ls-files half fails the run closed rather than selecting the tracked half alone"
}

# S26b: the mirror. The tracked enumeration fails and the untracked one answers, so the partial
# set is non-empty in the other direction. CPR-ORTH — the two halves get the same treatment.
test_S26b_zero_commit_tracked_half_failure_is_exit_1() {
    zc_fault_row "S26b_zero_commit_tracked_half_failure_is_exit_1" tracked \
        "a failing git diff HEAD half fails the run closed rather than selecting the untracked half alone"
}
