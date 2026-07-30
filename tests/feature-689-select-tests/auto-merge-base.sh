# Part of tests/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh, bin/is-docs-only
# Tags: test-selection, merge-base, docs-only, scope:issue-specific, pwsh-not-required, TL2

# ============================================================================
# S — `--auto`: the selector resolving its own merge-base, and refusing to guess.
#
# #1638. The caller used to pass a base in, computed by whoever happened to be calling, and
# a wrong one produced a selection that looked ordinary: files listed, exit 0, nothing said.
# With `--auto` the selector asks the shared resolver instead, and the resolver answers with
# a STATE as well as a base. The states are not interchangeable:
#
#   RECORDED / RESOLVED  the base is trustworthy — select normally.
#   SUSPECT / FALLBACK   the base resolved but is not trustworthy. Selecting from it would
#                        produce a plausible-looking list derived from the wrong range, so
#                        the run ABORTS (exit 4) with stdout empty and the recovery command
#                        on stderr. An empty selection would be worse than an abort here:
#                        run-tests would report "0 tests, all green".
#   exit 3 (UNRESOLVED)  there is no base at all. Nothing can be selected and nothing is
#                        wrong with the selector, so this is exit 0 with an empty selection.
#
# The SUSPECT/FALLBACK abort and the UNRESOLVED empty-but-fine case are deliberately
# different exit codes, and S4/S6/S7 are what keep them from collapsing into each other.
#
# #1689 also lands here (S10-S12): the TL3 append now asks bin/is-docs-only rather than
# re-deriving the allowlist, and when that helper cannot answer, the append happens anyway.
# ============================================================================

IS_DOCS_ONLY="${AGENTS_DIR}/bin/is-docs-only"
FAKE=""

# One fake agents tree, reused by every S row. `bin/` and `hooks/` are copied whole because
# select-tests.sh resolves its siblings from its OWN location, so a fake tree is the only way
# to put a controllable merge-base resolver in front of it. `tests/` is built by hand rather
# than copied: the real one has hundreds of files and the count assertions below need a set
# small enough to state exactly.
make_fake_agents() {
    FAKE="$TMPDIR_BASE/fake-agents"
    mkdir -p "$FAKE"
    cp -r "$AGENTS_DIR/bin" "$FAKE/bin"
    cp -r "$AGENTS_DIR/hooks" "$FAKE/hooks"
    mkdir -p "$FAKE/tests"
    : > "$FAKE/tests/feature-689-select-tests.sh"
    : > "$FAKE/tests/TL3-fake-alpha.sh"
    : > "$FAKE/tests/TL3-fake-beta.sh"
    # The resolver is replaced by a stub driven from the environment, so a row states the
    # state it wants instead of building a repository that happens to produce it.
    cat > "$FAKE/bin/resolve-merge-base.sh" <<'STUB'
#!/usr/bin/env bash
[ -n "${MB_STUB_MARKER:-}" ] && : > "$MB_STUB_MARKER"
[ -n "${MB_STUB_OUT:-}" ] && [ -f "$MB_STUB_OUT" ] && cat "$MB_STUB_OUT"
exit "${MB_STUB_RC:-0}"
STUB
    chmod +x "$FAKE/bin/resolve-merge-base.sh" 2>/dev/null || true
}

# The stub's stdout for a given state. `base=base` names the fixture's base branch, so a row
# that proceeds really does diff a real range rather than a placeholder.
stub_kv() { # <state> ; prints a kv block
    cat <<EOF
base=base
state=$1
source=origin/main
safe_base=HEAD
diff_lines=42
diff_files=3
threshold_lines=20000
threshold_files=500
branch=work
warn=none
alt_base=-
detail=stubbed for tests
EOF
}

SA_OUT=""
SA_ERR=""
SA_RC=0

# Runs the fake tree's select-tests.sh inside a fixture repo with the stub configured.
run_auto() { # <repo> <state|-> <stub-rc> [VAR=VAL...]
    local repo="$1" state="$2" rc="$3"
    shift 3
    local kvfile o e
    kvfile="$TMPDIR_BASE/stub-kv.$$"
    if [ "$state" = "-" ]; then : > "$kvfile"; else stub_kv "$state" > "$kvfile"; fi
    o="$TMPDIR_BASE/auto-out.$$"
    e="$TMPDIR_BASE/auto-err.$$"
    SA_RC=0
    # run_with_timeout is a shell function, so the environment is exported inside the
    # subshell rather than handed to `env`, which would try to exec it as a binary.
    (
        cd "$repo" || exit 1
        export MB_STUB_OUT="$kvfile" MB_STUB_RC="$rc" AGENTS_CONFIG_DIR="$AGENTS_DIR"
        local_kv=""
        for local_kv in "$@"; do export "${local_kv?}"; done
        run_with_timeout 120 bash "$FAKE/bin/select-tests.sh" --auto
    ) >"$o" 2>"$e" || SA_RC=$?
    SA_OUT="$(cat "$o")"
    SA_ERR="$(cat "$e")"
    rm -f "$o" "$e" "$kvfile"
}

# S1: the positional form is untouched. --auto is an ADDITION; if it changed what the old
# form does, every existing caller silently changes behaviour with it.
test_S1_positional_form_unchanged() {
    local repo="$TMPDIR_BASE/s1"
    make_repo "$repo" "bin/select-tests.sh"
    local positional auto
    positional="$(cd "$repo" && run_with_timeout 120 bash "$FAKE/bin/select-tests.sh" base HEAD 2>/dev/null)"
    run_auto "$repo" RESOLVED 0
    auto="$SA_OUT"
    if [ -z "$positional" ]; then
        fail "S1_positional_form_unchanged: the positional form selected nothing, so the row compares two empty strings"
    elif [ "$positional" = "$auto" ]; then
        pass "S1_positional_form_unchanged: --auto with a trustworthy base selects exactly what the positional form does"
    else
        fail "S1_positional_form_unchanged: outputs differ
--- positional ---
$positional
--- auto ---
$auto"
    fi
}

# S2/S3: both trustworthy states proceed. They are separate rows because they arrive by
# different paths in the resolver and only one of them exists before a session records a base.
test_S2_resolved_proceeds() {
    local repo="$TMPDIR_BASE/s2"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" RESOLVED 0
    if [ "$SA_RC" = "0" ] && [ -n "$SA_OUT" ]; then
        pass "S2_resolved_proceeds: state=RESOLVED selects normally and exits 0"
    else
        fail "S2_resolved_proceeds: rc=$SA_RC out='$SA_OUT' err='$SA_ERR'"
    fi
}

test_S3_recorded_proceeds() {
    local repo="$TMPDIR_BASE/s3"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" RECORDED 0
    if [ "$SA_RC" = "0" ] && [ -n "$SA_OUT" ]; then
        pass "S3_recorded_proceeds: state=RECORDED selects normally and exits 0"
    else
        fail "S3_recorded_proceeds: rc=$SA_RC out='$SA_OUT' err='$SA_ERR'"
    fi
}

# S4: an untrustworthy base must not produce a selection AT ALL. Emitting the list anyway
# would hand run-tests a set derived from the wrong range, which is #1638 with extra steps.
test_S4_suspect_aborts() {
    local repo="$TMPDIR_BASE/s4"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" SUSPECT 0
    if [ "$SA_RC" = "4" ] && [ -z "$SA_OUT" ]; then
        pass "S4_suspect_aborts: state=SUSPECT exits 4 with an empty stdout"
    else
        fail "S4_suspect_aborts: expected rc=4 and empty stdout, got rc=$SA_RC out='$SA_OUT'"
    fi
}

# S5: and the abort has to be actionable. A bare non-zero exit tells the caller nothing about
# what to do next, and the next step here is a specific command.
test_S5_suspect_explains_recovery() {
    local repo="$TMPDIR_BASE/s5"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" SUSPECT 0
    local missing=""
    echo "$SA_ERR" | grep -qE "^##[[:space:]]*merge-base:[[:space:]]*SUSPECT" || missing="$missing [state-line]"
    echo "$SA_ERR" | grep -q "test selection aborted" || missing="$missing [abort-line]"
    echo "$SA_ERR" | grep -q "resolve-merge-base.sh --explain" || missing="$missing [explain-hint]"
    echo "$SA_ERR" | grep -q "record-merge-base-baseline" || missing="$missing [record-hint]"
    if [ -z "$missing" ]; then
        pass "S5_suspect_explains_recovery: stderr carries the state, the abort, and both recovery commands"
    else
        fail "S5_suspect_explains_recovery: missing$missing
--- stderr ---
$SA_ERR"
    fi
}

# S6: FALLBACK gets the SAME treatment as SUSPECT. `HEAD~1` is a guess, not a branch point;
# selecting from it is exactly as wrong, so a fix that only handled SUSPECT would leave the
# more common of the two states unguarded.
test_S6_fallback_aborts() {
    local repo="$TMPDIR_BASE/s6"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" FALLBACK 0
    if [ "$SA_RC" = "4" ] && [ -z "$SA_OUT" ]; then
        pass "S6_fallback_aborts: state=FALLBACK is treated exactly like SUSPECT — exit 4, empty stdout"
    else
        fail "S6_fallback_aborts: expected rc=4 and empty stdout, got rc=$SA_RC out='$SA_OUT'"
    fi
}

# S7: no base at all is NOT an error in the selector. Nothing can be selected, the caller is
# told why, and the exit code stays 0 so a repository with a single commit does not fail the
# run. This is the row that must NOT be folded into S4.
test_S7_unresolved_is_empty_not_abort() {
    local repo="$TMPDIR_BASE/s7"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" - 3
    if [ "$SA_RC" = "0" ] && [ -z "$SA_OUT" ] && echo "$SA_ERR" | grep -q "cannot resolve merge-base"; then
        pass "S7_unresolved_is_empty_not_abort: resolver exit 3 gives an empty selection, exit 0, and a reason on stderr"
    else
        fail "S7_unresolved_is_empty_not_abort: rc=$SA_RC out='$SA_OUT' err='$SA_ERR'"
    fi
}

# S8: exit 2 is the resolver's ARGUMENT error — the selector called it wrongly. That is a
# defect in the caller, not a property of the repository, so it must not be swallowed into
# the empty-selection path where it would go unnoticed forever.
test_S8_resolver_arg_error_aborts() {
    local repo="$TMPDIR_BASE/s8"
    make_repo "$repo" "bin/select-tests.sh"
    run_auto "$repo" - 2
    if [ "$SA_RC" = "4" ] && [ -z "$SA_OUT" ]; then
        pass "S8_resolver_arg_error_aborts: resolver exit 2 aborts with exit 4"
    else
        fail "S8_resolver_arg_error_aborts: expected rc=4, got rc=$SA_RC out='$SA_OUT'"
    fi
}

# S9: a missing resolver is a broken install, not an empty diff.
test_S9_resolver_absent_aborts() {
    local repo="$TMPDIR_BASE/s9"
    make_repo "$repo" "bin/select-tests.sh"
    mv "$FAKE/bin/resolve-merge-base.sh" "$FAKE/bin/resolve-merge-base.sh.hidden"
    run_auto "$repo" RESOLVED 0
    mv "$FAKE/bin/resolve-merge-base.sh.hidden" "$FAKE/bin/resolve-merge-base.sh"
    if [ "$SA_RC" = "4" ] && [ -z "$SA_OUT" ]; then
        pass "S9_resolver_absent_aborts: a missing resolver aborts with exit 4 rather than selecting nothing quietly"
    else
        fail "S9_resolver_absent_aborts: expected rc=4, got rc=$SA_RC out='$SA_OUT'"
    fi
}

# S10 (#1689): docs-only diff under --auto → the TL3 tier is skipped.
test_S10_auto_docs_only_skips_tl3() {
    local repo="$TMPDIR_BASE/s10"
    make_repo "$repo" "docs/history.md"
    run_auto "$repo" RESOLVED 0 RUN_TL3=on
    # The exit code is asserted too: without it the row is satisfied by a run that failed
    # outright and therefore printed no TL3 lines for entirely the wrong reason.
    if [ "$SA_RC" != "0" ]; then
        fail "S10_auto_docs_only_skips_tl3: the run did not succeed (rc=$SA_RC), so 'no TL3' proves nothing
--- stderr ---
$SA_ERR"
    elif echo "$SA_OUT" | grep -q "TL3-fake-"; then
        fail "S10_auto_docs_only_skips_tl3: TL3 appended for a docs-only diff
--- output ---
$SA_OUT"
    else
        pass "S10_auto_docs_only_skips_tl3: RUN_TL3=on skips the TL3 tier on a docs-only diff"
    fi
}

# S11 (#1689): an EMPTY diff appends nothing either. This is the state a broken merge-base
# produces, and appending the whole expensive tier to it was how a resolution failure got to
# look like a busy, healthy run.
test_S11_auto_empty_diff_skips_tl3() {
    local repo="$TMPDIR_BASE/s11"
    make_repo "$repo"
    run_auto "$repo" RESOLVED 0 RUN_TL3=on
    if [ "$SA_RC" = "0" ] && [ -z "$SA_OUT" ]; then
        pass "S11_auto_empty_diff_skips_tl3: an empty diff selects nothing at all, including TL3"
    else
        fail "S11_auto_empty_diff_skips_tl3: rc=$SA_RC out='$SA_OUT'"
    fi
}

# S12 (#1689): when bin/is-docs-only cannot answer, the TL3 tier is added ANYWAY. The two
# errors are not symmetric — a needless TL3 run costs minutes, a skipped one ships a
# regression — so the unknown case resolves toward running.
test_S12_docs_only_helper_absent_appends() {
    local repo="$TMPDIR_BASE/s12"
    make_repo "$repo" "docs/history.md"
    if [ ! -f "$FAKE/bin/is-docs-only" ]; then
        fail "S12_docs_only_helper_absent_appends: bin/is-docs-only does not exist yet (implementation pending)"
        return
    fi
    mv "$FAKE/bin/is-docs-only" "$FAKE/bin/is-docs-only.hidden"
    run_auto "$repo" RESOLVED 0 RUN_TL3=on
    mv "$FAKE/bin/is-docs-only.hidden" "$FAKE/bin/is-docs-only"
    if echo "$SA_OUT" | grep -q "TL3-fake-"; then
        pass "S12_docs_only_helper_absent_appends: an unanswerable docs-only check falls back to running TL3"
    else
        fail "S12_docs_only_helper_absent_appends: TL3 was skipped when the classifier was unavailable
--- output ---
$SA_OUT"
    fi
}

# S13 (#1638): a recorded baseline whose HEAD moved after the session started is still a
# FACT — the base is where the branch started, and that does not change because someone
# committed since. The resolver says so with warn=post-session-head, and the selector's
# policy for a warn is a NOTE, not an abort: aborting here would refuse to select tests for
# every session that is still committing, which is all of them.
test_S13_post_session_head_notes_and_proceeds() {
    local repo="$TMPDIR_BASE/s13"
    make_repo "$repo" "bin/select-tests.sh"
    local kvfile o e
    kvfile="$TMPDIR_BASE/stub-kv-s13"
    stub_kv RECORDED | sed 's/^warn=none$/warn=post-session-head/; s/^alt_base=-$/alt_base=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' > "$kvfile"
    o="$TMPDIR_BASE/s13-out"; e="$TMPDIR_BASE/s13-err"
    SA_RC=0
    (
        cd "$repo" || exit 1
        export MB_STUB_OUT="$kvfile" MB_STUB_RC=0 AGENTS_CONFIG_DIR="$AGENTS_DIR"
        run_with_timeout 120 bash "$FAKE/bin/select-tests.sh" --auto
    ) >"$o" 2>"$e" || SA_RC=$?
    SA_OUT="$(cat "$o")"
    SA_ERR="$(cat "$e")"
    rm -f "$o" "$e" "$kvfile"

    if [ "$SA_RC" != "0" ]; then
        fail "S13_post_session_head_notes_and_proceeds: warn=post-session-head aborted the run (rc=$SA_RC)
--- stderr ---
$SA_ERR"
    elif [ -z "$SA_OUT" ]; then
        fail "S13_post_session_head_notes_and_proceeds: exit 0 but nothing was selected, so the row cannot tell 'proceeded' from 'gave up quietly'
--- stderr ---
$SA_ERR"
    elif ! printf '%s\n' "$SA_ERR" | grep -q "post-session-head"; then
        fail "S13_post_session_head_notes_and_proceeds: the warning was not surfaced on stderr
--- stderr ---
$SA_ERR"
    else
        pass "S13_post_session_head_notes_and_proceeds: warn=post-session-head is a stderr note; the selection still happens and exits 0"
    fi
}
